import Combine
import Foundation
import Security

/// One usage window for an agent's coding plan — a session, weekly, or monthly
/// quota lane with how full it is and when it next resets. Modelled on CodexBar's
/// per-provider limit tiles, but scoped to the agents termio actually launches.
struct UsageWindow: Identifiable, Hashable, Sendable {
    /// The quota period this window covers (e.g. "5h", "Weekly", "Monthly").
    let label: String
    /// How full the window is, 0–100. CodexBar's percent; the bar fills to this.
    let usedPercent: Int
    /// When the window rolls over and frees up again, when the source reports it.
    let resetsAt: Date?

    var id: String { label }
}

/// A snapshot of one agent's coding-plan usage, or the reason none is shown.
/// `windows` empty with no error means "fetched, nothing to show"; an error is
/// kept only to drive a quiet hint, never an alarm — a missing reading must
/// never interrupt a session.
struct AgentUsage: Hashable, Sendable {
    var windows: [UsageWindow]
    /// The tightest window (highest utilization), used for the one-line summaries
    /// in the sidebar footer and the tray.
    var tightest: UsageWindow? {
        windows.max { $0.usedPercent < $1.usedPercent }
    }
}

/// Reads the usage limits of the coding agents termio runs and keeps them fresh.
///
/// The data comes for free: termio already launches `claude` and `codex`, and
/// those CLIs leave OAuth credentials on disk. We reuse exactly those — no login
/// flow, no stored passwords — and call each provider's usage endpoint, the same
/// approach as steipete's CodexBar. Only the two agents with a clean local-cred
/// endpoint are supported; the rest simply show nothing.
///
/// Every failure is swallowed into "no reading" rather than surfaced as an error:
/// the endpoints are private and may change, and a usage strip is an ambient
/// convenience that must never get in the way of the terminal.
@MainActor
final class UsageMonitor: ObservableObject {
    @Published private(set) var usage: [AgentPreset: AgentUsage] = [:]

    /// Today / this-week / this-month token totals per agent, scanned from each
    /// agent's own local session logs. This is the "what have I actually burned"
    /// view — independent of how the plan bills — the same thing ccusage computes.
    @Published private(set) var tokenUsage: [AgentPreset: AgentTokenUsage] = [:]

    /// The agents with a usable local-credential usage endpoint. Kept here so the
    /// UI can ask "is this agent monitorable?" without duplicating the list.
    static let supportedAgents: [AgentPreset] = [.claudeCode, .codex]

    private let settings: AppSettings
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?

    /// Slow on purpose: these are session/weekly/monthly windows that move over
    /// minutes to days, and the endpoints are private — polling hard would be
    /// rude and wasteful. A manual `refresh()` covers "I want it now".
    private let interval: TimeInterval = 300

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// Begins periodic refreshes and fetches once immediately. Safe to call once
    /// at launch; repeated calls just restart the cadence.
    func start() {
        refresh()
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Fetches every supported, enabled agent's usage off the main actor and
    /// publishes the results. An agent that errors is dropped from the map (its
    /// row disappears) rather than left showing a stale number.
    func refresh() {
        let agents = Self.supportedAgents.filter(settings.isAgentEnabled)
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            var fetched: [AgentPreset: AgentUsage] = [:]
            for agent in agents {
                if let usage = await Self.fetch(agent) {
                    fetched[agent] = usage
                }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.usage = fetched }
        }

        // The local-log scan is plain synchronous file I/O over potentially
        // thousands of session files, so it runs detached (off the main actor)
        // and publishes back when done. Kept separate from the network fetch so a
        // slow scan never delays the plan-limit lanes, and vice versa.
        let claudeEnabled = settings.isAgentEnabled(.claudeCode)
        let codexEnabled = settings.isAgentEnabled(.codex)
        scanTask?.cancel()
        scanTask = Task.detached(priority: .utility) { [weak self] in
            let windows = DateWindows()
            var scanned: [AgentPreset: AgentTokenUsage] = [:]
            if claudeEnabled, let claude = Self.scanClaude(windows) {
                scanned[.claudeCode] = claude
            }
            if codexEnabled, let codex = Self.scanCodex(windows) {
                scanned[.codex] = codex
            }
            guard !Task.isCancelled else { return }
            let result = scanned
            await MainActor.run { self?.tokenUsage = result }
        }
    }

    // MARK: - Fetching

    private nonisolated static func fetch(_ agent: AgentPreset) async -> AgentUsage? {
        switch agent {
        case .claudeCode: return await fetchClaude()
        case .codex: return await fetchCodex()
        default: return nil
        }
    }

    /// Claude Code: OAuth bearer from `~/.claude/.credentials.json` (no prompt) or,
    /// failing that, the `Claude Code-credentials` Keychain item the CLI writes on
    /// macOS. `five_hour` → session lane, `seven_day` → weekly lane. Requires the
    /// `user:profile` scope, which Claude Code's tokens carry.
    private nonisolated static func fetchClaude() async -> AgentUsage? {
        guard let token = claudeAccessToken() else { return nil }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        guard let payload: ClaudeUsageResponse = await getJSON(request) else { return nil }

        var windows: [UsageWindow] = []
        if let lane = payload.five_hour, let window = lane.window(label: "5h") {
            windows.append(window)
        }
        if let lane = payload.seven_day, let window = lane.window(label: "Weekly") {
            windows.append(window)
        }
        return windows.isEmpty ? nil : AgentUsage(windows: windows)
    }

    /// Codex: OAuth bearer from `$CODEX_HOME/auth.json` (or `~/.codex/auth.json`).
    /// `rate_limit.primary_window` / `secondary_window` are the active lanes; the
    /// lane's `limit_window_seconds` names the period so a free-plan monthly window
    /// isn't mislabelled "session".
    private nonisolated static func fetchCodex() async -> AgentUsage? {
        guard let token = codexAccessToken() else { return nil }
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let payload: CodexUsageResponse = await getJSON(request),
              let limit = payload.rate_limit else { return nil }

        let windows = [limit.primary_window, limit.secondary_window]
            .compactMap { $0?.window() }
        return windows.isEmpty ? nil : AgentUsage(windows: windows)
    }

    // MARK: - Credentials

    private nonisolated static func claudeAccessToken() -> String? {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: file),
           let token = parseClaudeToken(data) {
            return token
        }
        guard let data = keychainPassword(service: "Claude Code-credentials") else { return nil }
        return parseClaudeToken(data)
    }

    private nonisolated static func parseClaudeToken(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let oauth = (root["claudeAiOauth"] as? [String: Any]) ?? root
        return oauth["accessToken"] as? String
    }

    private nonisolated static func codexAccessToken() -> String? {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let file = home.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any] else { return nil }
        return tokens["access_token"] as? String
    }

    /// Reads a generic-password Keychain item by service name. This is what the
    /// Claude CLI uses on macOS; the first read may raise the system's Keychain
    /// access prompt, after which "Always Allow" makes it silent.
    private nonisolated static func keychainPassword(service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    // MARK: - Networking

    /// GETs `request` and decodes the body as `T`, returning `nil` on any failure
    /// (network, non-2xx, decode) — every caller treats that as "no reading".
    private nonisolated static func getJSON<T: Decodable>(_ request: URLRequest) async -> T? {
        var request = request
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Wire formats

/// Just the fields termio reads from Claude's `/api/oauth/usage`. The response
/// carries many more lanes (model-specific weekly, extra usage); the session and
/// weekly windows are all the footer needs.
private struct ClaudeUsageResponse: Decodable {
    let five_hour: ClaudeLane?
    let seven_day: ClaudeLane?
}

private struct ClaudeLane: Decodable {
    let utilization: Double?
    let resets_at: String?

    /// A window for this lane, or `nil` when the lane has no utilization to show.
    func window(label: String) -> UsageWindow? {
        guard let utilization else { return nil }
        return UsageWindow(
            label: label,
            usedPercent: Int(utilization.rounded()),
            resetsAt: resets_at.flatMap(UsageWindow.parseISO8601)
        )
    }
}

private struct CodexUsageResponse: Decodable {
    let rate_limit: CodexRateLimit?
}

private struct CodexRateLimit: Decodable {
    let primary_window: CodexWindow?
    let secondary_window: CodexWindow?
}

private struct CodexWindow: Decodable {
    let used_percent: Double?
    let limit_window_seconds: Double?
    let reset_after_seconds: Double?
    let reset_at: Double?

    func window() -> UsageWindow? {
        guard let used_percent else { return nil }
        return UsageWindow(
            label: Self.label(forSeconds: limit_window_seconds),
            usedPercent: Int(used_percent.rounded()),
            resetsAt: resetDate()
        )
    }

    /// Prefers the absolute `reset_at` (unix seconds); falls back to "now plus the
    /// remaining seconds" when only a relative value is given.
    private func resetDate() -> Date? {
        if let reset_at { return Date(timeIntervalSince1970: reset_at) }
        if let reset_after_seconds { return Date().addingTimeInterval(reset_after_seconds) }
        return nil
    }

    /// Names the window from its length so a 30-day free-plan window reads
    /// "Monthly", not "Session". Thresholds are generous to absorb skew.
    private static func label(forSeconds seconds: Double?) -> String {
        guard let seconds else { return "Usage" }
        switch seconds {
        case ..<(6 * 3600): return "5h"
        case ..<(8 * 86_400): return "Weekly"
        default: return "Monthly"
        }
    }
}

extension UsageWindow {
    /// Parses the fractional-second ISO 8601 timestamps the usage endpoints emit
    /// (e.g. `2026-06-27T18:30:00.206589+00:00`), tolerating the missing-fraction
    /// form too.
    static func parseISO8601(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    /// A short "resets in" phrase for the reset time (e.g. "2h", "3d", "now"), or
    /// an empty string when the window has no known reset.
    var resetSummary: String {
        guard let resetsAt else { return "" }
        let seconds = resetsAt.timeIntervalSinceNow
        if seconds <= 0 { return "now" }
        if seconds < 3600 { return "\(Int((seconds / 60).rounded()))m" }
        if seconds < 86_400 { return "\(Int((seconds / 3600).rounded()))h" }
        return "\(Int((seconds / 86_400).rounded()))d"
    }
}

// MARK: - Local token usage (today / this week / this month)

/// The token totals for one time window, broken out by kind so the dollar
/// estimate can weight each correctly (cache reads are ~10× cheaper than fresh
/// input). `total` is the literal throughput — every token the agent processed.
struct TokenWindowStats: Sendable, Hashable {
    var input = 0
    var output = 0
    var cacheWrite = 0
    var cacheRead = 0
    /// Accumulated dollar estimate, priced per token as each line is scanned.
    /// Zero for agents whose provider pricing termio doesn't carry (Codex).
    var costUSD = 0.0

    var total: Int { input + output + cacheWrite + cacheRead }
    var isEmpty: Bool { total == 0 }

    mutating func add(_ other: TokenWindowStats) {
        input += other.input
        output += other.output
        cacheWrite += other.cacheWrite
        cacheRead += other.cacheRead
        costUSD += other.costUSD
    }
}

/// One agent's token usage across the three windows the user asked for. `hasCost`
/// is false for agents shown as token counts only (no priced model table).
struct AgentTokenUsage: Sendable, Hashable {
    var today = TokenWindowStats()
    var week = TokenWindowStats()
    var month = TokenWindowStats()
    var hasCost = false
}

/// The local-calendar boundaries the scan buckets into. Today is since local
/// midnight; week and month follow the user's calendar (locale-aware first
/// weekday, real month length). Today ⊂ this week ⊂ this month always holds, so a
/// line is simply added to each window whose start it is at or after.
struct DateWindows: Sendable {
    let todayStart: Date
    let weekStart: Date
    let monthStart: Date

    init(now: Date = Date(), calendar: Calendar = .current) {
        todayStart = calendar.startOfDay(for: now)
        weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? todayStart
        monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? todayStart
    }
}

/// Per-token prices for the models termio can price, in dollars. Cache-write is
/// the 5-minute ephemeral rate (1.25× input); cache-read is 0.1× input — the
/// economics the prompt-caching docs specify. Source: the claude-api skill's
/// current pricing table (Opus 4.8 $5/$25, Sonnet 4.6 $3/$15, Haiku 4.5 $1/$5
/// per million). Kept in one place so a price change is a one-line edit.
private struct ModelPrice {
    let input: Double
    let output: Double
    let cacheWrite: Double
    let cacheRead: Double

    static func perMillion(input: Double, output: Double) -> ModelPrice {
        ModelPrice(
            input: input / 1_000_000,
            output: output / 1_000_000,
            cacheWrite: input * 1.25 / 1_000_000,
            cacheRead: input * 0.1 / 1_000_000
        )
    }

    /// Matches a Claude model id (e.g. `claude-opus-4-8`) to its tier by family
    /// name, so a new dated snapshot still prices correctly. Falls back to Opus —
    /// the costliest, so an unknown model never silently under-counts spend.
    static func forClaudeModel(_ model: String) -> ModelPrice {
        let lowered = model.lowercased()
        if lowered.contains("haiku") { return .perMillion(input: 1, output: 5) }
        if lowered.contains("sonnet") { return .perMillion(input: 3, output: 15) }
        return .perMillion(input: 5, output: 25)
    }
}

extension UsageMonitor {
    private nonisolated static func bucket(
        _ usage: inout AgentTokenUsage, at timestamp: Date, in windows: DateWindows,
        _ delta: TokenWindowStats
    ) {
        if timestamp >= windows.monthStart { usage.month.add(delta) }
        if timestamp >= windows.weekStart { usage.week.add(delta) }
        if timestamp >= windows.todayStart { usage.today.add(delta) }
    }

    /// Scans Claude Code's per-session JSONL logs (`~/.claude/projects/**/*.jsonl`)
    /// and totals tokens + estimated cost into the three windows. Each line is one
    /// API turn carrying `message.usage` and `message.model`. Files untouched since
    /// before the month started can't hold an in-window line (logs are append-only),
    /// so they're skipped by modification date — the one cheap prefilter available.
    /// Duplicate turns (re-emitted on resume) are de-duplicated by request id.
    nonisolated static func scanClaude(_ windows: DateWindows) -> AgentTokenUsage? {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys) else { return nil }

        var usage = AgentTokenUsage(hasCost: true)
        var seen = Set<String>()
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate, modified < windows.monthStart {
                continue
            }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard line.contains("\"usage\"") else { continue }
                guard let object = try? JSONSerialization.jsonObject(
                    with: Data(line.utf8)) as? [String: Any],
                    let timestampString = object["timestamp"] as? String,
                    let timestamp = UsageWindow.parseISO8601(timestampString),
                    timestamp >= windows.monthStart,
                    let message = object["message"] as? [String: Any],
                    let usageObject = message["usage"] as? [String: Any] else { continue }

                let key = (object["requestId"] as? String) ?? (message["id"] as? String) ?? ""
                if !key.isEmpty {
                    if seen.contains(key) { continue }
                    seen.insert(key)
                }

                let price = ModelPrice.forClaudeModel(message["model"] as? String ?? "")
                let input = usageObject["input_tokens"] as? Int ?? 0
                let output = usageObject["output_tokens"] as? Int ?? 0
                let cacheWrite = usageObject["cache_creation_input_tokens"] as? Int ?? 0
                let cacheRead = usageObject["cache_read_input_tokens"] as? Int ?? 0
                let cost = Double(input) * price.input + Double(output) * price.output
                    + Double(cacheWrite) * price.cacheWrite + Double(cacheRead) * price.cacheRead
                bucket(&usage, at: timestamp, in: windows, TokenWindowStats(
                    input: input, output: output, cacheWrite: cacheWrite,
                    cacheRead: cacheRead, costUSD: cost))
            }
        }
        return usage.month.isEmpty ? nil : usage
    }

    /// Scans Codex's rollout logs (`~/.codex/sessions/YYYY/MM/DD/*.jsonl`) for
    /// `token_count` events and totals tokens into the three windows. The date is
    /// in the directory path, so whole days before the month start are skipped
    /// without opening a file. Codex's `last_token_usage` is the per-turn delta
    /// (its `total_token_usage` is cumulative — summing that would double-count).
    /// No dollar estimate: termio doesn't carry OpenAI model pricing.
    nonisolated static func scanCodex(_ windows: DateWindows) -> AgentTokenUsage? {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let sessions = home.appendingPathComponent("sessions")
        let calendar = Calendar.current
        let monthDay = calendar.startOfDay(for: windows.monthStart)

        var usage = AgentTokenUsage(hasCost: false)
        let dayDirectories = Self.codexDayDirectories(under: sessions, onOrAfter: monthDay)
        for directory in dayDirectories {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil) else { continue }
            for url in files where url.pathExtension == "jsonl" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                for line in text.split(separator: "\n") {
                    guard line.contains("token_count") else { continue }
                    guard let object = try? JSONSerialization.jsonObject(
                        with: Data(line.utf8)) as? [String: Any],
                        let timestampString = object["timestamp"] as? String,
                        let timestamp = UsageWindow.parseISO8601(timestampString),
                        timestamp >= windows.monthStart,
                        let payload = object["payload"] as? [String: Any],
                        payload["type"] as? String == "token_count",
                        let info = payload["info"] as? [String: Any],
                        let last = info["last_token_usage"] as? [String: Any] else { continue }

                    let inputTotal = last["input_tokens"] as? Int ?? 0
                    let cached = last["cached_input_tokens"] as? Int ?? 0
                    let output = last["output_tokens"] as? Int ?? 0
                    bucket(&usage, at: timestamp, in: windows, TokenWindowStats(
                        input: max(0, inputTotal - cached), output: output,
                        cacheWrite: 0, cacheRead: cached, costUSD: 0))
                }
            }
        }
        return usage.month.isEmpty ? nil : usage
    }

    /// Codex day-directories at or after `start`, read from the `YYYY/MM/DD` path
    /// layout so old sessions are never opened. A malformed path component just
    /// skips that branch rather than failing the scan.
    private nonisolated static func codexDayDirectories(under root: URL, onOrAfter start: Date) -> [URL] {
        let manager = FileManager.default
        let calendar = Calendar.current
        var result: [URL] = []
        let years = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for year in years {
            guard let yearValue = Int(year.lastPathComponent) else { continue }
            let months = (try? manager.contentsOfDirectory(at: year, includingPropertiesForKeys: nil)) ?? []
            for month in months {
                guard let monthValue = Int(month.lastPathComponent) else { continue }
                let days = (try? manager.contentsOfDirectory(at: month, includingPropertiesForKeys: nil)) ?? []
                for day in days {
                    guard let dayValue = Int(day.lastPathComponent),
                          let date = calendar.date(from: DateComponents(
                            year: yearValue, month: monthValue, day: dayValue)),
                          date >= calendar.startOfDay(for: start) else { continue }
                    result.append(day)
                }
            }
        }
        return result
    }
}

extension TokenWindowStats {
    /// Compact token count for the UI: `1.2M`, `980K`, `420`.
    var tokenSummary: String {
        let value = total
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.0fK", Double(value) / 1_000) }
        return "\(value)"
    }

    /// Dollar estimate as `$3.40`, or empty when this window carries no priced cost.
    var costSummary: String {
        costUSD > 0 ? String(format: "$%.2f", costUSD) : ""
    }
}
