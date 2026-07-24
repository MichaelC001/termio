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
}

/// Reads the usage limits of the coding agents termio runs, on demand.
///
/// The data comes for free: termio already launches `claude` and `codex`, and
/// those CLIs leave OAuth credentials on disk. We reuse exactly those — no login
/// flow, no stored passwords — and call each provider's usage endpoint, the same
/// approach as steipete's CodexBar. Only the two agents with a clean local-cred
/// endpoint are supported; the rest simply show nothing.
///
/// Reading another app's data is opt-in per agent (`usageAuthorizedAgents`), and
/// nothing runs in the background: refreshes happen only when the Usage tab asks.
/// Claude's Keychain credential is doubly gated — a Deny on the macOS prompt is
/// remembered (`claudeKeychainDeclined`) and never retried automatically, so the
/// system prompt can only ever appear as the direct result of a click in the tab.
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
    private var refreshTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    /// Whether a local-log scan is currently running, so overlapping `refresh()`
    /// calls let it finish instead of cancelling and restarting it forever.
    private var isScanning = false

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// When the heavy local-log scan last published, so routine refreshes can skip
    /// re-reading gigabytes of logs that have barely changed.
    private var lastTokenScan: Date?
    /// How stale token totals may get before an automatic refresh re-scans. The
    /// plan-limit lanes refresh on the faster `interval`; the log scan is far
    /// heavier (it reads every session file), so it runs much less often.
    private let tokenScanMaxAge: TimeInterval = 1800

    /// Refreshes both surfaces, re-scanning the logs only if the totals have gone
    /// stale. The cheap path for the Usage tab appearing.
    func refresh() {
        refreshPlanLimits()
        scanTokens(force: false)
    }

    /// Refreshes both and forces a fresh log scan regardless of age — the Refresh
    /// button's "I want it now".
    func forceRefresh() {
        refreshPlanLimits()
        scanTokens(force: true)
    }

    /// Fetches every supported, enabled, *authorized* agent's plan limits off the
    /// main actor and publishes them. An agent that errors is dropped from the map
    /// (its row disappears) rather than left showing a stale number.
    private func refreshPlanLimits() {
        let agents = Self.supportedAgents.filter {
            settings.isAgentEnabled($0) && settings.isUsageAuthorized($0)
        }
        let allowKeychain = !settings.claudeKeychainDeclined
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            var fetched: [AgentPreset: AgentUsage] = [:]
            var keychainDeclined = false
            for agent in agents {
                let outcome = await Self.fetch(agent, allowKeychain: allowKeychain)
                if let usage = outcome.usage { fetched[agent] = usage }
                if outcome.keychainDeclined { keychainDeclined = true }
            }
            guard !Task.isCancelled else { return }
            let declined = keychainDeclined
            await MainActor.run {
                guard let self else { return }
                self.usage = fetched
                // The user said No to the macOS Keychain prompt: remember it so
                // nothing asks again until they explicitly retry from the tab.
                if declined { self.settings.claudeKeychainDeclined = true }
            }
        }
    }

    /// Scans the local session logs for token totals, off the main actor.
    ///
    /// Skipped entirely when a scan is already running (the multi-second walk must
    /// run to completion — restarting it on every `refresh()` would mean it never
    /// finishes) or, unless `force`d, when the last scan is still fresh. The
    /// published `tokenUsage` is never cleared between scans, so the Usage tab
    /// shows the last totals instantly while a fresh scan runs underneath.
    private func scanTokens(force: Bool) {
        guard !isScanning else { return }
        if !force, let last = lastTokenScan, Date().timeIntervalSince(last) < tokenScanMaxAge {
            return
        }
        let claudeEnabled = settings.isAgentEnabled(.claudeCode)
            && settings.isUsageAuthorized(.claudeCode)
        let codexEnabled = settings.isAgentEnabled(.codex)
            && settings.isUsageAuthorized(.codex)
        isScanning = true
        scanTask = Task.detached(priority: .utility) { [weak self] in
            let windows = DateWindows()
            var scanned: [AgentPreset: AgentTokenUsage] = [:]
            if claudeEnabled {
                let claude = Self.scanClaude(windows)
                if !claude.isEmpty { scanned[.claudeCode] = claude }
            }
            if codexEnabled {
                let codex = Self.scanCodex(windows)
                if !codex.isEmpty { scanned[.codex] = codex }
            }
            let result = scanned
            await self?.finishTokenScan(result)
        }
    }

    @MainActor
    private func finishTokenScan(_ result: [AgentPreset: AgentTokenUsage]) {
        tokenUsage = result
        lastTokenScan = Date()
        isScanning = false
    }

    // MARK: - Fetching

    /// One plan-limit fetch's result: the reading (if any) plus whether the user
    /// refused the Keychain prompt along the way, so the caller can remember the
    /// refusal instead of silently retrying it forever.
    private struct FetchOutcome {
        var usage: AgentUsage?
        var keychainDeclined = false
    }

    private nonisolated static func fetch(
        _ agent: AgentPreset, allowKeychain: Bool
    ) async -> FetchOutcome {
        if agent == .claudeCode { return await fetchClaude(allowKeychain: allowKeychain) }
        if agent == .codex { return FetchOutcome(usage: await fetchCodex()) }
        return FetchOutcome()
    }

    /// Claude Code: OAuth bearer from `~/.claude/.credentials.json` (a plain file,
    /// no prompt) or, only when `allowKeychain`, the `Claude Code-credentials`
    /// Keychain item the CLI writes on macOS. `five_hour` → session lane,
    /// `seven_day` → weekly lane. Requires the `user:profile` scope, which Claude
    /// Code's tokens carry.
    private nonisolated static func fetchClaude(allowKeychain: Bool) async -> FetchOutcome {
        let credential = claudeAccessToken(allowKeychain: allowKeychain)
        guard case .token(let token) = credential else {
            return FetchOutcome(keychainDeclined: credential == .keychainDeclined)
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        guard let payload: ClaudeUsageResponse = await getJSON(request) else {
            return FetchOutcome()
        }

        var windows: [UsageWindow] = []
        if let lane = payload.five_hour, let window = lane.window(label: "5h") {
            windows.append(window)
        }
        if let lane = payload.seven_day, let window = lane.window(label: "Weekly") {
            windows.append(window)
        }
        return FetchOutcome(usage: windows.isEmpty ? nil : AgentUsage(windows: windows))
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

    /// How a Claude credential lookup ended: a usable token, nothing readable, or
    /// the user actively refusing the Keychain prompt (which the caller must
    /// remember, not retry).
    private enum ClaudeCredential: Equatable {
        case token(String)
        case unavailable
        case keychainDeclined
    }

    private nonisolated static func claudeAccessToken(allowKeychain: Bool) -> ClaudeCredential {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: file),
           let token = parseClaudeToken(data) {
            return .token(token)
        }
        guard allowKeychain else { return .unavailable }
        switch keychainPassword(service: "Claude Code-credentials") {
        case .success(let data):
            guard let token = parseClaudeToken(data) else { return .unavailable }
            return .token(token)
        case .declined:
            return .keychainDeclined
        case .unavailable:
            return .unavailable
        }
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

    private enum KeychainRead {
        case success(Data)
        /// The user refused the system's access prompt (Deny, or cancelling the
        /// unlock dialog) — distinct from "nothing there" so it can be remembered.
        case declined
        case unavailable
    }

    /// Reads a generic-password Keychain item by service name. This is what the
    /// Claude CLI uses on macOS; the read may raise the system's Keychain access
    /// prompt ("Always Allow" makes it silent), so callers must only reach here as
    /// the direct result of a user action.
    private nonisolated static func keychainPassword(service: String) -> KeychainRead {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &item) {
        case errSecSuccess:
            guard let data = item as? Data else { return .unavailable }
            return .success(data)
        case errSecAuthFailed, errSecUserCanceled:
            return .declined
        default:
            return .unavailable
        }
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
    /// form too. Used off the hot path (a handful of plan-limit reset times).
    static func parseISO8601(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    /// A fast path for the rigid UTC log timestamps (`2026-06-27T11:22:05.555Z`),
    /// called once per turn across ~150k lines. `ISO8601DateFormatter` is ~100×
    /// slower and allocates per call, so the scan extracts the fixed fields by
    /// byte position and builds the instant against a cached UTC calendar; only a
    /// shape that doesn't match falls back to the formatter.
    static func fastLogTimestamp(_ string: String) -> Date? {
        let utf8 = string.utf8
        guard utf8.count >= 19 else { return parseISO8601(string) }
        let bytes = Array(utf8)
        func number(_ start: Int, _ length: Int) -> Int? {
            var value = 0
            for index in start..<(start + length) {
                let digit = Int(bytes[index]) - 48
                guard (0...9).contains(digit) else { return nil }
                value = value * 10 + digit
            }
            return value
        }
        guard bytes[4] == 0x2D, bytes[7] == 0x2D, bytes[10] == 0x54,  // '-','-','T'
              let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
              let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2)
        else { return parseISO8601(string) }
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute; components.second = second
        return utcCalendar.date(from: components)
    }

    /// A Gregorian calendar pinned to UTC, reused across the whole scan so the
    /// fast timestamp parser doesn't reallocate one per line.
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

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
    /// Per-local-day totals feeding the activity chart, covering the scan window
    /// (the last ~month). Keys are `startOfDay` instants in the scan's calendar.
    var daily: [Date: TokenWindowStats] = [:]
    var hasCost = false

    /// True when there is nothing to show at all — no in-month totals and no
    /// historical days — so the agent's pane can fall back to its hint.
    var isEmpty: Bool { month.isEmpty && daily.values.allSatisfy(\.isEmpty) }
}

/// The local-calendar boundaries the scan buckets into. Today is since local
/// midnight; week and month follow the user's calendar (locale-aware first
/// weekday, real month length). Today ⊂ this week ⊂ this month always holds, so a
/// line is simply added to each window whose start it is at or after.
struct DateWindows: Sendable {
    let todayStart: Date
    let weekStart: Date
    let monthStart: Date
    /// Where the scan stops looking back: the older of the month start and the
    /// activity chart's 30-day horizon, so the month totals stay whole and the
    /// chart's oldest day is never half-scanned. Anything older is skipped.
    let scanStart: Date
    let calendar: Calendar

    init(now: Date = Date(), calendar: Calendar = .current) {
        self.calendar = calendar
        todayStart = calendar.startOfDay(for: now)
        weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? todayStart
        monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? todayStart
        let chartStart = calendar.date(byAdding: .day, value: -29, to: todayStart)
            ?? todayStart.addingTimeInterval(-29 * 86_400)
        scanStart = min(monthStart, chartStart)
    }
}

/// Per-token prices for the models termio can price, in dollars. Cache-write is
/// the 5-minute ephemeral rate (1.25× input); cache-read is 0.1× input — the
/// economics the prompt-caching docs specify. Source: the claude-api skill's
/// current pricing table (Fable 5 $10/$50, Opus 4.8 $5/$25, Sonnet 4.6 $3/$15,
/// Haiku 4.5 $1/$5 per million). Kept in one place so a price change is a
/// one-line edit.
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
    /// name, so a new dated snapshot still prices correctly. An unknown model
    /// falls back to Opus — not the top of the range (Fable is costlier), so a
    /// genuinely unrecognised premium model can under-count; the named tiers
    /// below keep every model termio actually sees priced exactly. (CodexBar's
    /// answer to this is a live models.dev catalog; termio stays a flat table.)
    static func forClaudeModel(_ model: String) -> ModelPrice {
        let lowered = model.lowercased()
        if lowered.contains("fable") { return .perMillion(input: 10, output: 50) }
        if lowered.contains("haiku") { return .perMillion(input: 1, output: 5) }
        if lowered.contains("sonnet") { return .perMillion(input: 3, output: 15) }
        return .perMillion(input: 5, output: 25)
    }
}

extension UsageMonitor {
    private nonisolated static func bucket(
        _ usage: inout AgentTokenUsage, at timestamp: Date, day: Date, in windows: DateWindows,
        _ delta: TokenWindowStats
    ) {
        if timestamp >= windows.monthStart { usage.month.add(delta) }
        if timestamp >= windows.weekStart { usage.week.add(delta) }
        if timestamp >= windows.todayStart { usage.today.add(delta) }
        usage.daily[day, default: TokenWindowStats()].add(delta)
    }

    /// Resolves a timestamp to its local `startOfDay`, caching the current day's
    /// bounds — log lines arrive in near-chronological runs, so almost every call
    /// is a two-comparison hit instead of a calendar computation.
    private struct DayResolver {
        private var start = Date.distantFuture
        private var end = Date.distantPast
        mutating func day(for timestamp: Date, calendar: Calendar) -> Date {
            if timestamp >= start, timestamp < end { return start }
            start = calendar.startOfDay(for: timestamp)
            end = calendar.date(byAdding: .day, value: 1, to: start)
                ?? start.addingTimeInterval(86_400)
            return start
        }
    }

    /// Scans Claude Code's per-session JSONL logs (`~/.claude/projects/**/*.jsonl`)
    /// and totals tokens + estimated cost into the windows and per-day buckets.
    /// Each line is one API turn carrying `message.usage` and `message.model`.
    /// Files untouched since before the scan window can't hold an in-window line
    /// (logs are append-only), so they're skipped by modification date — the one
    /// cheap prefilter available. Duplicate turns (re-emitted on resume) are
    /// de-duplicated by request id.
    nonisolated static func scanClaude(_ windows: DateWindows) -> AgentTokenUsage {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        var usage = AgentTokenUsage(hasCost: true)
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys) else { return usage }

        // Match on raw UTF-8 bytes, never Swift `String`: a `Substring.contains`
        // over 1.5 GB of logs does Unicode-grapheme work on every byte and is ~20×
        // slower than byte scanning. The cheap byte probe gates the (rare) JSON
        // parse, so only genuine turn lines are decoded.
        let usageProbe = Data("\"usage\"".utf8)
        // Hashes, not the id strings themselves — a month of heavy use is hundreds
        // of thousands of ids, and a Set of full strings would hold tens of MB.
        var seen = Set<Int>()
        var resolver = DayResolver()
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate, modified < windows.scanStart {
                continue
            }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            for line in data.split(separator: 0x0A) {
                guard line.range(of: usageProbe) != nil,
                    let object = try? JSONSerialization.jsonObject(
                        with: Data(line)) as? [String: Any],
                    let timestampString = object["timestamp"] as? String,
                    let timestamp = UsageWindow.fastLogTimestamp(timestampString),
                    timestamp >= windows.scanStart,
                    let message = object["message"] as? [String: Any],
                    let usageObject = message["usage"] as? [String: Any] else { continue }

                let key = (object["requestId"] as? String) ?? (message["id"] as? String) ?? ""
                if !key.isEmpty, !seen.insert(key.hashValue).inserted { continue }

                let price = ModelPrice.forClaudeModel(message["model"] as? String ?? "")
                let input = usageObject["input_tokens"] as? Int ?? 0
                let output = usageObject["output_tokens"] as? Int ?? 0
                let cacheWrite = usageObject["cache_creation_input_tokens"] as? Int ?? 0
                let cacheRead = usageObject["cache_read_input_tokens"] as? Int ?? 0
                let cost = Double(input) * price.input + Double(output) * price.output
                    + Double(cacheWrite) * price.cacheWrite + Double(cacheRead) * price.cacheRead
                let day = resolver.day(for: timestamp, calendar: windows.calendar)
                bucket(&usage, at: timestamp, day: day, in: windows, TokenWindowStats(
                    input: input, output: output, cacheWrite: cacheWrite,
                    cacheRead: cacheRead, costUSD: cost))
            }
        }
        return usage
    }

    /// Scans Codex's rollout logs (`~/.codex/sessions/YYYY/MM/DD/*.jsonl`) for
    /// `token_count` events and totals tokens into the windows and per-day
    /// buckets. The date is in the directory path, so whole days before the scan
    /// window are skipped without opening a file. Codex's `last_token_usage` is
    /// the per-turn delta (its `total_token_usage` is cumulative — summing that
    /// would double-count). No dollar estimate: termio doesn't carry OpenAI
    /// model pricing.
    nonisolated static func scanCodex(_ windows: DateWindows) -> AgentTokenUsage {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let sessions = home.appendingPathComponent("sessions")

        let tokenProbe = Data("token_count".utf8)
        var usage = AgentTokenUsage(hasCost: false)
        var resolver = DayResolver()
        let dayDirectories = Self.codexDayDirectories(under: sessions, onOrAfter: windows.scanStart)
        for directory in dayDirectories {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil) else { continue }
            for url in files where url.pathExtension == "jsonl" {
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
                for line in data.split(separator: 0x0A) {
                    guard line.range(of: tokenProbe) != nil,
                        let object = try? JSONSerialization.jsonObject(
                            with: Data(line)) as? [String: Any],
                        let timestampString = object["timestamp"] as? String,
                        let timestamp = UsageWindow.fastLogTimestamp(timestampString),
                        timestamp >= windows.scanStart,
                        let payload = object["payload"] as? [String: Any],
                        payload["type"] as? String == "token_count",
                        let info = payload["info"] as? [String: Any],
                        let last = info["last_token_usage"] as? [String: Any] else { continue }

                    let inputTotal = last["input_tokens"] as? Int ?? 0
                    let cached = last["cached_input_tokens"] as? Int ?? 0
                    let output = last["output_tokens"] as? Int ?? 0
                    let day = resolver.day(for: timestamp, calendar: windows.calendar)
                    bucket(&usage, at: timestamp, day: day, in: windows, TokenWindowStats(
                        input: max(0, inputTotal - cached), output: output,
                        cacheWrite: 0, cacheRead: cached, costUSD: 0))
                }
            }
        }
        return usage
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
