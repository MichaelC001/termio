import AppKit
import SwiftUI

/// The coding-plan usage limits for the agents termio runs, reusing the OAuth
/// credentials the `claude`, `codex`, `kimi`, and `grok` CLIs already leave on
/// disk — the same approach as steipete's CodexBar, scoped to the agents with a
/// clean local-cred endpoint. A reference view, not an ambient one: it pulls
/// fresh on open, so a glance here tells you whether to start that long run.
///
/// Each fact sits under what owns its data. Plan limits belong to a login, so
/// they sit under Accounts, one row per login. Token totals come from session
/// logs that record no account, so they sit under This Mac, one total per
/// agent. The config folders behind the accounts are mechanism and stay out of
/// sight: Reveal in Finder and Use a Signed-In Folder… are the only ways in.
struct UsageSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var usage: UsageMonitor
    /// Opens a terminal running a CLI login (title, command line) in the main
    /// window.
    let onSignIn: (String, String) -> Void
    /// The agent whose statistics are shown. Held loosely (optional) so a disabled
    /// agent falling out of the list resolves back to the first available one
    /// rather than stranding on an empty pane.
    @State private var selected: AgentPreset?

    /// The supported agents the user has left enabled — one segment each.
    private var agents: [AgentPreset] {
        UsageMonitor.supportedAgents.filter(settings.isAgentEnabled)
    }

    /// The resolved selection: the held one if still enabled, else the first agent.
    private var current: AgentPreset {
        if let selected, agents.contains(selected) { return selected }
        return agents.first ?? .claudeCode
    }

    var body: some View {
        Group {
            if agents.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    if agents.count > 1 {
                        Picker(localized("Agent"), selection: Binding(get: { current }, set: { selected = $0 })) {
                            ForEach(agents) { agent in
                                Text(agent.displayName).tag(agent)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .padding(.top, 14)
                    }
                    UsageAgentDetail(agent: current, usage: usage, settings: settings, onSignIn: onSignIn)
                }
            }
        }
        .onAppear(perform: usage.refresh)
    }

    private var emptyState: some View {
        Form {
            Section {
                Text(localized("Enable Claude Code, Codex, Kimi, or Grok in the Agents tab to see their usage here."))
                    .font(.settingsDetail)
                    .foregroundStyle(.secondary)
            } header: {
                SectionHeaderLabel(title: localized("Usage"))
            }
        }
        .formStyle(.grouped)
    }
}

/// A sign-in under way from this tab: the folder it signs in to, whether that
/// folder is a new account, and where the sheet is in the flow.
private struct UsageSignIn: Identifiable {
    enum Phase: Equatable {
        /// Only for a new account: the one question, "sign in now?".
        case ask
        /// The terminal is open; the sheet polls the folder for a login. After a
        /// duplicate, the old login is still in the folder until the new one
        /// replaces it, so the poll waits past that email.
        case waiting(ignoring: String?)
        /// The login landed, but it is an account that is already listed.
        case duplicate(String)
    }

    let account: UsageAccount
    let isNew: Bool
    var phase: Phase

    var id: String { account.id }
}

/// One agent's usage: its accounts with their plan limits, then this Mac's token
/// totals. Everything is behind a per-agent Allow: until the user grants it, none
/// of the agent's data — logs or sign-in — is read, and the pane says only that.
private struct UsageAgentDetail: View {
    let agent: AgentPreset
    @ObservedObject var usage: UsageMonitor
    @ObservedObject var settings: AppSettings
    let onSignIn: (String, String) -> Void
    @State private var signIn: UsageSignIn?

    private var accounts: [UsageAccount] { usage.accounts(for: agent) }

    var body: some View {
        if settings.isUsageAuthorized(agent) {
            statistics
        } else {
            authorizationOffer
        }
    }

    /// The pre-grant pane: what would be read, and a single Allow button. The
    /// Keychain prompt (Claude only) can then appear as the direct consequence of
    /// this click — never from merely opening the tab.
    private var authorizationOffer: some View {
        Form {
            Section {
                Text(agent == .claudeCode
                    ? localized("Termio can show \(agent.displayName)'s token usage and plan limits by reading its local session logs and its sign-in from your login Keychain. Nothing is read until you allow it; macOS will ask once about the Keychain.")
                    : agent == .kimi
                    ? localized("Termio can show \(agent.displayName)'s token usage and plan limits by reading its local session logs and its `credentials/kimi-code.json` sign-in. Nothing is read until you allow it.")
                    : localized("Termio can show \(agent.displayName)'s token usage and plan limits by reading its local session logs and its `auth.json` sign-in. Nothing is read until you allow it."))
                    .font(.settingsDetail)
                    .foregroundStyle(.secondary)
                Button(localized("Allow Usage Access")) {
                    settings.setUsageAuthorized(agent, enabled: true)
                    if agent == .claudeCode { settings.claudeKeychainDeclined = false }
                    usage.forceRefresh()
                }
            } header: {
                SectionHeaderLabel(title: localized("Usage"))
            }
        }
        .formStyle(.grouped)
    }

    private var statistics: some View {
        Form {
            Section {
                ForEach(accounts) { account in
                    UsageAccountRow(
                        title: usage.emails[account] ?? account.displayPath,
                        plan: usage.usage[account]?.plan,
                        state: state(of: account),
                        isActive: accounts.count > 1 && isActive(account),
                        onAction: { act(on: account) },
                        onUse: canSwitch && !isActive(account) ? { use(account) } : nil,
                        onReveal: { NSWorkspace.shared.activateFileViewerSelecting([account.home]) },
                        onRemove: account.isDefault ? nil : { remove(account) })
                }
                if UsageMonitor.canAddAccounts(for: agent) {
                    Button(localized("Add Account…"), action: beginAdding)
                        .buttonStyle(.plain)
                }
            } header: {
                SectionHeaderLabel(title: localized("Accounts"))
            }

            Section {
                if let tokens = usage.tokenUsage[agent] {
                    UsageTotalsRow(tokens: tokens)
                    UsageActivityChart(daily: tokens.daily, hasCost: tokens.hasCost)
                } else {
                    Text(localized("No sessions on this Mac yet."))
                        .foregroundStyle(.secondary)
                }
            } header: {
                SectionHeaderLabel(title: localized("This Mac"))
            } footer: {
                Text(localized("Every \(agent.displayName) session on this Mac, from all accounts.\(usage.tokenUsage[agent]?.hasCost == true ? localized(" Cost is estimated at API rates.") : "")"))
                    .font(.settingsDetail)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button(localized("Stop Reading \(agent.displayName) Data")) {
                        settings.setUsageAuthorized(agent, enabled: false)
                        usage.forceRefresh()
                    }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .animation(.easeOut(duration: 0.2), value: accounts)
        .sheet(item: $signIn) { flow in
            UsageSignInSheet(
                agent: agent,
                flow: flow,
                usage: usage,
                existingEmails: Set(accounts.filter { $0 != flow.account }.compactMap { usage.emails[$0] }),
                onSignIn: { run(flow.account) },
                onUseFolder: {
                    signIn = nil
                    DispatchQueue.main.async(execute: addExistingFolder)
                },
                onSignedIn: { finish(flow) },
                onPhase: { signIn?.phase = $0 },
                onCancel: { signIn = nil })
        }
    }

    /// Only agents termio can sign in can run on more than one account.
    private var canSwitch: Bool { UsageMonitor.canAddAccounts(for: agent) }

    /// Whether new sessions start on `account`.
    private func isActive(_ account: UsageAccount) -> Bool {
        let active = settings.activeAccountFolder(for: agent)
        return account.isDefault ? active == nil : active == account.home.path
    }

    /// New sessions start on `account` from now on; running ones keep theirs.
    private func use(_ account: UsageAccount) {
        settings.setActiveAccountFolder(account.isDefault ? nil : account.home.path, for: agent)
    }

    private func state(of account: UsageAccount) -> UsageAccountRow.State {
        if let reading = usage.usage[account], !reading.windows.isEmpty {
            return .limits(reading.windows)
        }
        if agent == .claudeCode, settings.claudeKeychainDeclined { return .keychainDeclined }
        if usage.signedIn[account] == false {
            return UsageMonitor.canAddAccounts(for: agent) ? .signedOut : .unreadable
        }
        return .unreadable
    }

    /// The row's one button: retry the Keychain, or sign this account back in.
    private func act(on account: UsageAccount) {
        if agent == .claudeCode, settings.claudeKeychainDeclined {
            settings.claudeKeychainDeclined = false
            usage.refresh()
            return
        }
        run(account)
        signIn = UsageSignIn(account: account, isNew: false, phase: .waiting(ignoring: nil))
    }

    private func beginAdding() {
        guard let account = usage.nextAccount(for: agent) else { return }
        signIn = UsageSignIn(account: account, isNew: true, phase: .ask)
    }

    /// Opens the terminal that runs the CLI's own login for `account`.
    private func run(_ account: UsageAccount) {
        guard let command = usage.signInCommand(for: account) else { return }
        onSignIn(localized("\(agent.displayName) Sign-In"), command)
    }

    private func finish(_ flow: UsageSignIn) {
        if flow.isNew {
            settings.addUsageAccountFolder(flow.account.home.path, for: agent)
        }
        signIn = nil
        usage.forceRefresh()
    }

    /// The escape hatch for people who already keep accounts in folders of their
    /// own: pick one that is signed in, and it is listed as is.
    private func addExistingFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = localized("Add Account")
        panel.message = localized("Choose the folder \(agent.displayName) signed in to.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard UsageMonitor.isAccountFolder(url, for: agent) else {
            let alert = NSAlert()
            alert.messageText = localized("Choose a folder named like “\(defaultFolderName)-work”")
            alert.informativeText = localized("Termio keeps each account in a folder beside \(defaultFolderName) so its sessions can report their status.")
            alert.runModal()
            return
        }
        settings.addUsageAccountFolder(url.standardizedFileURL.path, for: agent)
        usage.forceRefresh()
    }

    /// The default folder's name, `.claude`, for the folder-naming hint.
    private var defaultFolderName: String {
        accounts.first { $0.isDefault }?.home.lastPathComponent ?? ""
    }

    private func remove(_ account: UsageAccount) {
        settings.removeUsageAccountFolder(account.home.path, for: agent)
        usage.forceRefresh()
    }
}

/// The add / sign-in sheet. A new account gets one question first; after that
/// the sheet only waits, polling the folder until the CLI's login lands, and
/// closes on its own — there is nothing for the user to confirm.
private struct UsageSignInSheet: View {
    let agent: AgentPreset
    let flow: UsageSignIn
    let usage: UsageMonitor
    let existingEmails: Set<String>
    let onSignIn: () -> Void
    let onUseFolder: () -> Void
    let onSignedIn: () -> Void
    let onPhase: (UsageSignIn.Phase) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch flow.phase {
            case .ask:
                VStack(alignment: .leading, spacing: 6) {
                    Text(localized("Add a \(agent.displayName) Account")).bold()
                    Text(localized("Termio opens a terminal where \(agent.displayName) signs you in. Your other accounts stay signed in."))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button(localized("Use a Signed-In Folder…"), action: onUseFolder)
                        .buttonStyle(.link)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(localized("Cancel"), action: onCancel)
                        .keyboardShortcut(.cancelAction)
                    Button(localized("Sign In…")) {
                        onSignIn()
                        onPhase(.waiting(ignoring: nil))
                    }
                    .keyboardShortcut(.defaultAction)
                }
            case .waiting:
                HStack(alignment: .top, spacing: 10) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(localized("Finish signing in in the terminal")).bold()
                        Text(localized("This closes by itself once \(agent.displayName) is signed in."))
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Spacer()
                    Button(localized("Cancel"), action: onCancel)
                        .keyboardShortcut(.cancelAction)
                }
            case .duplicate(let email):
                VStack(alignment: .leading, spacing: 6) {
                    Text(localized("\(email) is already added")).bold()
                    Text(localized("Sign in with a different account in the terminal, or cancel."))
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button(localized("Cancel"), action: onCancel)
                        .keyboardShortcut(.cancelAction)
                    Button(localized("Try Again")) {
                        onSignIn()
                        onPhase(.waiting(ignoring: email))
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 400, alignment: .leading)
        .task(id: flow.phase) { await watch() }
    }

    /// Polls the folder while the terminal runs the login. Files and Keychain
    /// attributes only — no secret is read, so this can never raise a prompt.
    /// The task ends with the sheet or the phase.
    private func watch() async {
        guard case .waiting(let ignored) = flow.phase else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            let state = usage.signInState(of: flow.account)
            guard state.signedIn, ignored == nil || state.email != ignored else { continue }
            if let email = state.email, existingEmails.contains(email) {
                onPhase(.duplicate(email))
            } else {
                onSignedIn()
            }
            return
        }
    }
}

/// One account: who is signed in and on which plan, with its quota lanes
/// beneath — or, when the lanes can't be shown, the one reason and the one
/// action that fixes it. The ⋯ menu appears on hover; right-click offers the
/// same items.
private struct UsageAccountRow: View {
    enum State {
        case limits([UsageWindow])
        case keychainDeclined
        case signedOut
        case unreadable
    }

    let title: String
    let plan: String?
    let state: State
    /// Marks the account new sessions start on; only drawn when there is a
    /// choice to mark.
    let isActive: Bool
    let onAction: () -> Void
    let onUse: (() -> Void)?
    let onReveal: () -> Void
    let onRemove: (() -> Void)?
    @SwiftUI.State private var hovering = false

    private var isSignedOut: Bool {
        if case .signedOut = state { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .help(localized("New sessions use this account."))
                        .accessibilityLabel(localized("New sessions use this account."))
                }
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isSignedOut ? .secondary : .primary)
                Spacer(minLength: 8)
                if isSignedOut {
                    Text(localized("Signed out")).foregroundStyle(.tertiary)
                } else if let plan {
                    Text(plan).foregroundStyle(.secondary)
                }
                Menu { menuItems } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .opacity(hovering ? 1 : 0)
                .accessibilityLabel(localized("More"))
            }
            detail
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { menuItems }
    }

    @ViewBuilder
    private var menuItems: some View {
        if let onUse {
            Button(localized("Use for New Sessions"), action: onUse)
            Divider()
        }
        Button(localized("Reveal in Finder"), action: onReveal)
        if let onRemove {
            Divider()
            Button(localized("Remove Account"), action: onRemove)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch state {
        case .limits(let windows):
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                ForEach(windows) { window in
                    UsageWindowRow(window: window)
                }
            }
        case .keychainDeclined:
            reason(localized("Limits need Keychain access."), action: localized("Allow…"))
        case .signedOut:
            reason(localized("Sign in again to see this account's limits."), action: localized("Sign In…"))
        case .unreadable:
            Text(localized("Couldn't read plan limits."))
                .foregroundStyle(.secondary)
        }
    }

    private func reason(_ text: String, action: String) -> some View {
        HStack {
            Text(text).foregroundStyle(.secondary)
            Spacer()
            Button(action, action: onAction)
        }
    }
}

/// One quota lane as a grid row: its period, a bar, the percent, and when it
/// resets. Columns line up across lanes and across accounts, so two logins
/// compare at a glance. The bar is ink, never hue: from 90% the lane turns full
/// strength and its reset time steps up, so the eye goes to "when can I use it
/// again".
private struct UsageWindowRow: View {
    let window: UsageWindow

    private var isHot: Bool { window.usedPercent >= 90 }

    private var resetText: String {
        switch window.resetSummary {
        case "": return ""
        case "now": return localized("Resetting")
        default: return localized("Resets in \(window.resetSummary)")
        }
    }

    var body: some View {
        GridRow {
            Text(window.label)
                .foregroundStyle(isHot ? .primary : .secondary)
                .frame(width: 58, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule()
                        .fill(Color.primary.opacity(isHot ? 1 : 0.6))
                        .frame(width: max(0, min(1, Double(window.usedPercent) / 100)) * geometry.size.width)
                }
            }
            .frame(height: 6)
            Text("\(window.usedPercent)%")
                .monospacedDigit()
                .fontWeight(isHot ? .semibold : .regular)
                .frame(width: 40, alignment: .trailing)
            Text(resetText)
                .monospacedDigit()
                .foregroundStyle(isHot ? .primary : .tertiary)
                .fontWeight(isHot ? .medium : .regular)
                .frame(width: 96, alignment: .trailing)
        }
    }
}

/// Today, the last 7 days, and the last 30, as three columns: the token count
/// large, the API-rate cost (where termio can price it) beneath. Rolling windows
/// rather than calendar ones, so Monday morning doesn't read as an empty week.
private struct UsageTotalsRow: View {
    let tokens: AgentTokenUsage

    private func lastDays(_ count: Int) -> TokenWindowStats {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var total = TokenWindowStats()
        for offset in 0..<count {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            if let stats = tokens.daily[day] { total.add(stats) }
        }
        return total
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            column(localized("Today"), tokens.today)
            column(localized("Last 7 days"), lastDays(7))
            column(localized("Last 30 days"), lastDays(30))
        }
        .padding(.vertical, 4)
    }

    private func column(_ label: String, _ stats: TokenWindowStats) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).foregroundStyle(.secondary)
            Text(stats.tokenSummary)
                .font(.system(size: 20, weight: .semibold))
                .monospacedDigit()
            Text(tokens.hasCost ? stats.costSummary : localized("tokens"))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One bar of the activity chart plus the day phrase the caption shows while it
/// is hovered.
private struct UsageChartBar: Identifiable, Equatable {
    let id: Int
    let label: String
    let stats: TokenWindowStats
}

/// The last 30 days, one bar per day, scaled to the busiest day. Hovering a bar
/// puts that day and its numbers in the caption — no tooltip chrome, the same
/// quiet register as the rest of the pane.
private struct UsageActivityChart: View {
    let daily: [Date: TokenWindowStats]
    let hasCost: Bool
    @State private var hoveredID: Int?

    var body: some View {
        let bars = self.bars
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(caption(bars))
                Spacer()
                Text(value(bars))
            }
            .monospacedDigit()
            .foregroundStyle(.secondary)
            barsView(bars)
        }
        .padding(.vertical, 4)
    }

    /// Oldest first, one per day, with empty days kept so the time axis stays
    /// honest.
    private var bars: [UsageChartBar] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<30).compactMap { index in
            guard let day = calendar.date(byAdding: .day, value: index - 29, to: today)
            else { return nil }
            return UsageChartBar(
                id: index,
                label: index == 29
                    ? localized("Today")
                    : day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()),
                stats: daily[day] ?? TokenWindowStats())
        }
    }

    private func caption(_ bars: [UsageChartBar]) -> String {
        if let hoveredID, let bar = bars.first(where: { $0.id == hoveredID }) { return bar.label }
        return localized("Last 30 days")
    }

    private func value(_ bars: [UsageChartBar]) -> String {
        guard let hoveredID, let bar = bars.first(where: { $0.id == hoveredID }) else { return "" }
        var text = localized("\(bar.stats.tokenSummary) tokens")
        if hasCost, !bar.stats.costSummary.isEmpty { text += " · \(bar.stats.costSummary)" }
        return text
    }

    private func barsView(_ bars: [UsageChartBar]) -> some View {
        let peak = max(bars.map(\.stats.total).max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(bars) { bar in
                let fraction = Double(bar.stats.total) / Double(peak)
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary.opacity(opacity(for: bar)))
                        .frame(height: bar.stats.total == 0 ? 2 : max(3, fraction * 64))
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside {
                        hoveredID = bar.id
                    } else if hoveredID == bar.id {
                        hoveredID = nil
                    }
                }
            }
        }
        .frame(height: 64)
    }

    private func opacity(for bar: UsageChartBar) -> Double {
        guard let hoveredID else { return 0.45 }
        return hoveredID == bar.id ? 1 : 0.22
    }
}
