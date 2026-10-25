import Combine
import Foundation

/// Reads the usage of the coding agents termio runs, on demand.
///
/// The data comes for free: termio already launches `claude`, `codex`, `kimi`,
/// and `grok`, and those CLIs leave OAuth credentials and session logs on disk.
/// We reuse exactly those — no login flow, no stored passwords — the same
/// approach as steipete's CodexBar. Each agent's reading lives behind a
/// `UsageProvider`; this type only knows the list, so only agents with a clean
/// local-cred endpoint appear and the rest simply show nothing.
///
/// An agent can have several accounts — one per config folder, see
/// `UsageAccount` — and every map below is keyed by account, so a second login
/// is read exactly like the first.
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
    @Published private(set) var usage: [UsageAccount: AgentUsage] = [:]

    /// Token totals per agent, summed over every account's folder: the "what has
    /// this Mac burned" view, the same thing ccusage computes. Kept per agent, not
    /// per account, because the session logs record no account — a folder two
    /// logins have shared holds both, and any split by account would be a guess.
    @Published private(set) var tokenUsage: [AgentPreset: AgentTokenUsage] = [:]

    /// The signed-in email per account, where the CLI records one in a file.
    @Published private(set) var emails: [UsageAccount: String] = [:]

    /// Whether each account's folder still holds a login, so a row can tell
    /// "signed out" apart from "the limits endpoint didn't answer".
    @Published private(set) var signedIn: [UsageAccount: Bool] = [:]

    /// Every agent termio can read usage for. Supporting one more is a new
    /// provider file plus a line here.
    private static let providers: [any UsageProvider.Type] = [
        ClaudeUsageProvider.self, CodexUsageProvider.self, KimiUsageProvider.self,
        GrokUsageProvider.self,
    ]

    /// The agents with a usable local-credential usage source. Kept here so the
    /// UI can ask "is this agent monitorable?" without duplicating the list.
    static let supportedAgents: [AgentPreset] = providers.map { $0.agent }

    private static func providerType(for agent: AgentPreset) -> (any UsageProvider.Type)? {
        providers.first { $0.agent == agent }
    }

    private static func provider(for account: UsageAccount) -> (any UsageProvider)? {
        providerType(for: account.agent)?.init(home: account.home)
    }

    /// Whether termio can sign the agent in to another account: only agents
    /// whose CLI has a login subcommand.
    static func canAddAccounts(for agent: AgentPreset) -> Bool {
        providerType(for: agent)?.loginArguments != nil
    }

    private let settings: AppSettings
    private var refreshTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    /// Whether a local-log scan is currently running, so overlapping `refresh()`
    /// calls let it finish instead of cancelling and restarting it forever.
    private var isScanning = false
    /// When the heavy local-log scan last published, so routine refreshes can skip
    /// re-reading gigabytes of logs that have barely changed.
    private var lastTokenScan: Date?
    /// How stale token totals may get before an automatic refresh re-scans. The
    /// plan-limit lanes refresh on the faster `interval`; the log scan is far
    /// heavier (it reads every session file), so it runs much less often.
    private let tokenScanMaxAge: TimeInterval = 1800

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// The agent's accounts: the CLI's default folder first, then the folders
    /// the user added, in the order they were added.
    func accounts(for agent: AgentPreset) -> [UsageAccount] {
        guard let provider = Self.providers.first(where: { $0.agent == agent }) else { return [] }
        let defaultHome = provider.defaultHome.standardizedFileURL
        // Folders are told apart by spelling, not by where they lead: Claude
        // keys a login by the exported string, so two spellings of one folder
        // can hold two logins. The log scan is what dedupes by target.
        var seen: Set<URL> = [defaultHome]
        let added = settings.usageAccountFolders(for: agent)
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .filter { seen.insert($0).inserted }
            .map { UsageAccount(agent: agent, home: $0, isDefault: false) }
        return [UsageAccount(agent: agent, home: defaultHome, isDefault: true)] + added
    }

    /// The folder a new account signs in to: the default folder's name plus the
    /// first free `-2`, `-3`, … that neither exists on disk nor is listed, so a
    /// sign-in never lands in a folder that already holds someone's login.
    func nextAccount(for agent: AgentPreset) -> UsageAccount? {
        guard let type = Self.providerType(for: agent) else { return nil }
        let base = type.manifestHome.standardizedFileURL
        let taken = Set(accounts(for: agent).map(\.home))
        for suffix in 2... {
            let home = base.deletingLastPathComponent()
                .appendingPathComponent("\(base.lastPathComponent)-\(suffix)")
            if !taken.contains(home), !FileManager.default.fileExists(atPath: home.path) {
                return UsageAccount(agent: agent, home: home, isDefault: false)
            }
        }
        return nil
    }

    /// The shell line that runs the CLI's own login for `account`'s folder,
    /// creating the folder first (Codex refuses a `CODEX_HOME` that doesn't
    /// exist). The default folder needs no variable; every other one is passed
    /// exactly as `keychainService` hashes it.
    func signInCommand(for account: UsageAccount) -> String? {
        guard let type = Self.providerType(for: account.agent),
              let login = type.loginArguments,
              let command = settings.commandPath(for: account.agent, on: .thisMac)
                .flatMap({ $0.isEmpty ? nil : $0 }) ?? account.agent.command
        else { return nil }
        // The default folder signs in exactly as its sessions launch: with
        // whatever the environment already exports, untouched.
        if account.isDefault { return "\(command) \(login)" }
        do {
            try FileManager.default.createDirectory(
                at: account.home, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            Log.app.error("usage: could not create \(account.home.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return TermioStore.exporting(type.homeEnvironment, account.home.path, before: "\(command) \(login)")
    }

    /// Whether `folder` is one termio can integrate as an account: beside the
    /// agent's default folder and named after it (`~/.claude-work`). termiod
    /// installs status hooks only into folders of that shape, so any other
    /// would run sessions that report no status.
    static func isAccountFolder(_ folder: URL, for agent: AgentPreset) -> Bool {
        guard let base = providerType(for: agent)?.manifestHome.standardizedFileURL else { return false }
        let folder = folder.standardizedFileURL
        // termiod refuses a symlink here (it could lead anywhere), so the app
        // refuses it too rather than add an account that gets no hooks.
        let isSymlink = (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
        guard !isSymlink,
              folder.deletingLastPathComponent() == base.deletingLastPathComponent(),
              folder.lastPathComponent.hasPrefix(base.lastPathComponent + "-") else { return false }
        let suffix = folder.lastPathComponent.dropFirst(base.lastPathComponent.count + 1)
        return !suffix.isEmpty && suffix.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }

    /// Whether `account`'s folder holds a login yet, and whose. Reads files and
    /// Keychain attributes only, so the add sheet can poll it without a prompt.
    func signInState(of account: UsageAccount) -> (signedIn: Bool, email: String?) {
        guard let provider = Self.provider(for: account) else { return (false, nil) }
        return (provider.hasCredential(), provider.accountEmail())
    }

    /// Refreshes both surfaces, re-scanning the logs only if the totals have gone
    /// stale. The cheap path for the Usage tab appearing.
    func refresh() {
        refreshPlanLimits()
        scanTokens(force: false)
    }

    /// Refreshes both and forces a fresh log scan regardless of age — the Refresh
    /// button's "I want it now", and the follow-up to adding or removing an
    /// account.
    func forceRefresh() {
        refreshPlanLimits()
        scanTokens(force: true)
    }

    /// One provider per account of every agent the user has both enabled and
    /// allowed termio to read. Nothing else is ever touched.
    private var authorizedProviders: [(account: UsageAccount, provider: any UsageProvider)] {
        Self.providers
            .filter { settings.isAgentEnabled($0.agent) && settings.isUsageAuthorized($0.agent) }
            .flatMap { type in
                accounts(for: type.agent).map { (account: $0, provider: type.init(home: $0.home)) }
            }
    }

    /// Fetches every authorized account's plan limits off the main actor and
    /// publishes them. An account that errors is dropped from the map (its lanes
    /// disappear) rather than left showing a stale number.
    private func refreshPlanLimits() {
        let providers = authorizedProviders
        let allowKeychain = !settings.claudeKeychainDeclined
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            var fetched: [UsageAccount: AgentUsage] = [:]
            var emails: [UsageAccount: String] = [:]
            var signedIn: [UsageAccount: Bool] = [:]
            var keychainDeclined = false
            for (account, provider) in providers {
                if let email = provider.accountEmail() { emails[account] = email }
                signedIn[account] = provider.hasCredential()
                let reading = await provider.planLimits(
                    allowKeychain: allowKeychain && !keychainDeclined)
                if let usage = reading.usage { fetched[account] = usage }
                if reading.keychainDeclined { keychainDeclined = true }
            }
            guard !Task.isCancelled else { return }
            let declined = keychainDeclined
            let resolvedEmails = emails
            let resolvedSignedIn = signedIn
            await MainActor.run {
                guard let self else { return }
                self.usage = fetched
                self.emails = resolvedEmails
                self.signedIn = resolvedSignedIn
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
        let providers = authorizedProviders
        isScanning = true
        scanTask = Task.detached(priority: .utility) { [weak self] in
            let windows = DateWindows()
            var scanned: [AgentPreset: AgentTokenUsage] = [:]
            // Two accounts whose folders lead to one directory share its logs;
            // scanning both would double every total.
            var scannedHomes = Set<String>()
            for (_, provider) in providers {
                guard scannedHomes.insert(
                    "\(provider.agent.rawValue):\(provider.home.resolvingSymlinksInPath().path)"
                ).inserted else { continue }
                let usage = provider.tokenUsage(in: windows)
                guard !usage.isEmpty else { continue }
                scanned[provider.agent, default: AgentTokenUsage()].add(usage)
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
}
