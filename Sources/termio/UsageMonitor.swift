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

    /// The agents with a usable local-credential usage endpoint. Kept here so the
    /// UI can ask "is this agent monitorable?" without duplicating the list.
    static let supportedAgents: [AgentPreset] = [.claudeCode, .codex]

    private let settings: AppSettings
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?

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
