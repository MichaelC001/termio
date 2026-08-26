import SwiftUI

/// The preferences window, opened from the app menu (⌘,). The groups mirror the
/// settings model: how the app behaves, then the machines it reaches and what
/// runs on them. Controls bind straight to `AppSettings`, which persists on
/// change, so there is no separate save step.
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
        /// A machine's `settingsKey` to open straight onto, for the deep links
        /// that mean a *pane* rather than a tab — "Pair a phone…" lands on this
        /// Mac's Serving section (RFC §D9), which is two clicks in otherwise.
        initialDevice: String? = nil,
        onSSHConnect: @escaping (String) -> Void,
        onSetUpKey: @escaping (String, String) -> Void
    ) {
        self.settings = settings
        self.usage = usage
        self.store = store
        self.onSSHConnect = onSSHConnect
        self.onSetUpKey = onSetUpKey
        _selection = State(initialValue: initialTab)
        _path = State(initialValue: initialDevice.map {
            NavigationPath([DeviceRoute(key: $0)])
        } ?? NavigationPath())
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(Array(SettingsTab.groups.enumerated()), id: \.offset) { index, group in
                    ForEach(Array(group.enumerated()), id: \.element) { position, tab in
                        row(for: tab)
                            // The gap System Settings leaves between groups, kept
                            // inside the row: a sidebar list floors every row at
                            // 32pt, so a blank row can only ever be that tall, and
                            // `Section` — which does leave the right gap — squares
                            // off the top corners of its first row's pill.
                            .padding(.top, index > 0 && position == 0 ? 13 : 0)
                            .listRowInsets(EdgeInsets(top: 1, leading: 10, bottom: 1, trailing: 10))
                            .tag(tab)
                            // Strips the source list's own selection fill, which
                            // would otherwise draw the full row height behind the
                            // pill. Mounted in a row: that is where the walk-up
                            // reaches the table (see `OutlineViewFixups`).
                            .background(OutlineViewFixups())
                    }
                }
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
        .onChange(of: selection, initial: true) { previous, tab in
            UserDefaults.standard.set(tab.rawValue, forKey: SettingsTab.lastOpenKey)
            // Only a real switch empties the stack. The `initial: true` fire is
            // what writes the deep-linked tab to `lastOpenKey`, and clearing on
            // it too would pop the pane `initialDevice` just pushed — the window
            // would open on the Devices roster instead of the machine asked for.
            if previous != tab { path = NavigationPath() }
        }
    }

    /// One sidebar row, painting its own selection pill because the source list's
    /// fill covers the whole row — including the group gap the first row of a
    /// group carries.
    private func row(for tab: SettingsTab) -> some View {
        let isSelected = selection == tab
        return Label {
            Text(tab.title)
        } icon: {
            HugeIconView(icon: tab.icon, size: 15, color: isSelected ? .white : .primary)
        }
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
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
                settings: settings, store: store,
                onConnect: onSSHConnect, onSetUpKey: onSetUpKey
            )
        case .keyboard: KeybindingsSettingsTab()
        case .agents:
            AgentSettingsTab(settings: settings, store: store)
        case .usage: UsageSettingsTab(settings: settings, usage: usage)
        case .community: CommunitySettingsTab()
        }
    }
}
