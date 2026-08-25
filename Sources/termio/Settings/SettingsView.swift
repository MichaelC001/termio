import SwiftUI

/// The preferences window, opened from the app menu (⌘,). The groups mirror the
/// settings model: appearance, terminal behaviour, the agent presets, usage, and
/// mobile pairing. Controls bind straight
/// to `AppSettings`, which persists on change, so there is no separate save step.
///
/// The layout follows macOS System Settings: a left sidebar of groups and a detail
/// pane that carries the group's title + subtitle in the toolbar with a grouped
/// `Form` below. Window chrome (resizable, unified toolbar, saved size) is set up
/// in `AppDelegate.openSettings`.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var usage: UsageMonitor
    /// The Workspaces tab's subject. Actions elsewhere are injected as closures so
    /// a pane can't reach past its own concern, but that tab *is* a live view of
    /// the workspace list — a closure would have to hand over a copy that stops
    /// tracking the moment one is added.
    @ObservedObject var store: TermioStore
    /// Opens an SSH terminal to a `~/.ssh/config` alias in the main window — the
    /// Devices tab's Connect action, injected by the app delegate because
    /// connecting is a main-window launch, not something this window does.
    let onSSHConnect: (String) -> Void
    /// Runs `ssh-copy-id` for an alias with the given public key, in the main
    /// window — injected for the same reason as `onSSHConnect`, since it is also a
    /// terminal launch rather than something this window can do.
    let onSetUpKey: (String, String) -> Void
    @State private var selection: SettingsTab
    /// The detail column's push stack, which a tab drills into (Agents pushes one
    /// agent's pane). Owned here so switching tabs can empty it: a pushed pane
    /// whose `navigationDestination` left with its tab would otherwise sit on the
    /// stack unresolvable.
    @State private var path = NavigationPath()

    init(
        settings: AppSettings,
        usage: UsageMonitor,
        store: TermioStore,
        initialTab: SettingsTab = .general,
        onSSHConnect: @escaping (String) -> Void,
        onSetUpKey: @escaping (String, String) -> Void
    ) {
        self.settings = settings
        self.usage = usage
        self.store = store
        self.onSSHConnect = onSSHConnect
        self.onSetUpKey = onSetUpKey
        _selection = State(initialValue: initialTab)
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: $selection) { tab in
                Label {
                    Text(tab.title)
                } icon: {
                    HugeIconView(icon: tab.icon, size: 15, color: .primary)
                }
                .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 184, ideal: 204, max: 240)
        } detail: {
            NavigationStack(path: $path) {
                detail
                    .navigationTitle(selection.title)
                    .navigationSubtitle(selection.subtitle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .toolbar {
                        // Without a toolbar item the NavigationStack collapses the
                        // title + subtitle into one inline "Title – Subtitle" line
                        // beside the traffic lights. An empty principal item forces
                        // the full-height two-line chrome on every pane (macOS 26).
                        ToolbarItem(placement: .principal) { Text("") }
                    }
                    .toolbarBackground(.regularMaterial, for: .windowToolbar)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .labeledContentStyle(.settingsCentered)
        // Remember where the user is, so the next ⌘, reopens the same tab
        // (see `AppDelegate.showSettings`). Written on every switch — cheap,
        // and it must also capture the initial deep-linked tab a user stays on.
        .onChange(of: selection, initial: true) { _, tab in
            UserDefaults.standard.set(tab.rawValue, forKey: SettingsTab.lastOpenKey)
            path = NavigationPath()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .general: GeneralSettingsTab(settings: settings)
        case .appearance: AppearanceSettingsTab(settings: settings)
        case .terminal: TerminalSettingsTab(settings: settings)
        case .workspaces: WorkspaceSettingsTab(store: store)
        case .devices:
            DevicesSettingsTab(
                settings: settings, onConnect: onSSHConnect, onSetUpKey: onSetUpKey
            )
        case .keyboard: KeybindingsSettingsTab()
        case .agents: AgentSettingsTab(settings: settings)
        case .usage: UsageSettingsTab(settings: settings, usage: usage)
        case .mobile: MobileSettingsTab()
        case .community: CommunitySettingsTab()
        }
    }
}
