import SwiftUI
import TermioShared
import UIKit

/// The root screen, iMessage-inbox style: a large title with a sort button
/// riding it, the sessions grouped under small gray project headers (each with
/// its own ＋ to start a session), and a floating settings button bottom-right.
/// Lives at the root of RootContainerViewController's navigation stack and owns
/// the companion roster connection; pairing itself lives in Settings ▸
/// Connectivity.
final class SessionListViewController: UIViewController {
    /// Open a session row; `companionURL` is non-nil when the row is live.
    var onOpenSession: ((MockSession, URL?) -> Void)?
    /// `MockSession.key` of the session filling the screen — its row gets
    /// the current-chat pill.
    var currentSessionKey: String?

    /// Live roster from the Mac when a companion URL is configured. Empty when
    /// unpaired/connecting — the zero state fills the screen instead of fake
    /// rows. The bundled mock only appears under `-demo` (screenshots / tests).
    private var projects: [MockProject] = []
    /// `projects` in the chosen order — what the table shows.
    private var visible: [MockProject] = []
    /// The agents the Mac has enabled in Settings ▸ Agents, pushed on the roster.
    /// The new-session menus mirror this so the phone never offers an agent the
    /// desktop has turned off. Falls back to a built-in list when the roster
    /// carries none (an older Mac, or before the first push lands).
    private var enabledAgents: [RosterAgent] = []
    private var client: CompanionClient?
    private var companionURL: URL?
    /// The project+agent of an in-flight `start`, so the `.started` reply
    /// knows what to open.
    private var pendingStart: (project: MockProject, agent: String)?
    /// Mirrors the Mac sidebar's sort pull-down. The roster arrives in the
    /// Mac's recent-activity order, so "Recent Activity" means "as pushed";
    /// "Name" re-sorts locally A→Z.
    private var sortByName = UserDefaults.standard.string(forKey: "sessions.sortOrder") == "name"
    /// Projects the user has collapsed, keyed by `collapseKey` (path — stable
    /// across reconnects, since the Mac's `rosterID` churns on rebuild). A
    /// collapsed project keeps its header but shows no session rows. Persisted
    /// so the list reopens the way it was left. Every project folds, including
    /// a lone one.
    private var collapsed: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: "sessions.collapsedProjects") ?? []
    )

    private let filterButton = UIButton(type: .system)
    private let tableView = UITableView(frame: .zero, style: .grouped)
    /// The Telegram/iMessage-style zero state shown when there are no real
    /// sessions to list — never fake rows. Its copy tracks `CompanionLink.state`.
    private let emptyState = SessionListEmptyState()
    /// Set once a `.connecting` state has lingered past the grace window, so the
    /// zero state escalates from "Connecting…" to "Can't reach your Mac".
    private var reconnectStalled = false
    private var connectingGraceTimer: Timer?
    private var pairingObserver: NSObjectProtocol?
    private var linkStateObserver: NSObjectProtocol?

    override func viewDidLoad() {
        super.viewDidLoad()
        // A full page now, not a drawer: plain system background, like the
        // Messages inbox.
        view.backgroundColor = .systemBackground
        let topBar = configureTopBar()
        configureTable(below: topBar)
        configureEmptyState(below: topBar)
        // Added last so the floating glass footer layers over the list.
        configureBottomBar()
        refilter()
        connectRosterIfConfigured()
        // The zero-state copy ("No Mac connected" → "Connecting…" → the empty
        // roster) follows the live link state, not just roster pushes.
        linkStateObserver = NotificationCenter.default.addObserver(
            forName: CompanionLink.stateDidChange, object: nil, queue: .main
        ) { [weak self] _ in self?.updateEmptyState() }
        // The Connectivity settings page edits the pairing; this socket's
        // owner follows it.
        pairingObserver = NotificationCenter.default.addObserver(
            forName: CompanionLink.pairingDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if let url = CompanionLink.savedURL {
                client?.stop()
                client = nil
                connectRoster(to: url)
            } else {
                disconnectRoster()
            }
        }
    }

    deinit {
        if let pairingObserver {
            NotificationCenter.default.removeObserver(pairingObserver)
        }
        if let linkStateObserver {
            NotificationCenter.default.removeObserver(linkStateObserver)
        }
        connectingGraceTimer?.invalidate()
    }

    func refresh() {
        tableView.reloadData()
    }

    // MARK: - Top bar (large title + filter + compose)

    private func configureTopBar() -> UIView {
        let pageTitle = UILabel()
        pageTitle.text = "Sessions"
        pageTitle.font = .systemFont(ofSize: 34, weight: .bold)
        pageTitle.textColor = .label

        // The Mac sidebar's sort pull-down, translated to iMessage chrome:
        // a glass circle riding the large title, menu as primary action.
        filterButton.applyGlassSymbol("line.3.horizontal.decrease")
        filterButton.tintColor = .label
        filterButton.accessibilityLabel = "Sort"
        filterButton.showsMenuAsPrimaryAction = true
        filterButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.sortMenuItems() ?? [])
            },
        ])

        // Messages-inbox chrome: the bold title on the left, the round
        // sort button riding the same line on the right.
        let spacer = UIView()
        let bar = UIStackView(arrangedSubviews: [pageTitle, spacer, filterButton])
        bar.axis = .horizontal
        bar.alignment = .center
        bar.spacing = 8
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            // Telegram's nav-bar glass buttons are 40pt circles.
            filterButton.widthAnchor.constraint(equalToConstant: 40),
            filterButton.heightAnchor.constraint(equalToConstant: 40),
        ])
        return bar
    }

    /// The same two orders as the Mac's sort menu, checkmarked like it too.
    private func sortMenuItems() -> [UIMenuElement] {
        [
            UIAction(title: "Recent Activity", state: sortByName ? .off : .on) { [weak self] _ in
                self?.setSortByName(false)
            },
            UIAction(title: "Name", state: sortByName ? .on : .off) { [weak self] _ in
                self?.setSortByName(true)
            },
        ]
    }

    private func setSortByName(_ byName: Bool) {
        sortByName = byName
        UserDefaults.standard.set(byName ? "name" : "recentActivity", forKey: "sessions.sortOrder")
        refilter()
    }

    /// The "new session" actions for a project, one per agent the Mac has left
    /// enabled — driving each project header's ＋ button. Falls back to a
    /// built-in list until the roster's agent list arrives (or when paired to
    /// an older Mac).
    private func newSessionActions(in project: MockProject) -> [UIAction] {
        let agents = enabledAgents.isEmpty
            ? [RosterAgent(id: "claude", name: "Claude Code"),
               RosterAgent(id: "codex", name: "Codex"),
               RosterAgent(id: "terminal", name: "Terminal")]
            : enabledAgents
        return agents.map { agent in
            UIAction(title: agent.name, image: AgentKind(wire: agent.id).menuIcon()) { [weak self] _ in
                self?.startSession(agent: agent.id, in: project)
            }
        }
    }

    // MARK: - Bottom bar (the floating settings button)

    /// Telegram's iOS 26 tab bar: nothing spans the width. A **detached
    /// circular glass button** floats bottom-right (settings) and the list
    /// scrolls under it, so the footer reads as chrome, not a divider. The
    /// Mac pairing and its live status live in Settings ▸ Connectivity.
    private func configureBottomBar() {
        let gear = UIButton(type: .system)
        gear.setImage(
            UIImage(systemName: "gearshape", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)),
            for: .normal
        )
        gear.tintColor = .label
        gear.accessibilityLabel = "Settings"
        gear.addAction(UIAction { [weak self] _ in
            self?.presentSettings()
        }, for: .touchUpInside)
        let puck = Self.makeGlassView(interactive: true)
        gear.translatesAutoresizingMaskIntoConstraints = false
        puck.contentView.addSubview(gear)
        puck.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(puck)

        let puckSize: CGFloat = 44
        puck.layer.cornerRadius = puckSize / 2
        puck.clipsToBounds = true

        NSLayoutConstraint.activate([
            puck.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            puck.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            puck.widthAnchor.constraint(equalToConstant: puckSize),
            puck.heightAnchor.constraint(equalToConstant: puckSize),
            gear.centerXAnchor.constraint(equalTo: puck.contentView.centerXAnchor),
            gear.centerYAnchor.constraint(equalTo: puck.contentView.centerYAnchor),
            gear.widthAnchor.constraint(equalTo: puck.widthAnchor),
            gear.heightAnchor.constraint(equalTo: puck.heightAnchor),
        ])
    }

    /// A Liquid Glass surface. On iOS 26 it's a real interactive `UIGlassEffect`
    /// (the Telegram tab-bar look); older systems fall back to a chrome-material
    /// blur, which reads as translucent glass too.
    private static func makeGlassView(interactive: Bool) -> UIVisualEffectView {
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect(style: .regular)
            glass.isInteractive = interactive
            return UIVisualEffectView(effect: glass)
        }
        return UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    }

    /// Forget-Mac teardown: no roster, so the unpaired zero state takes over.
    private func disconnectRoster() {
        client?.stop()
        client = nil
        companionURL = nil
        CompanionLink.state = .unpaired
        projects = []
        refilter()
    }

    private func presentSettings() {
        // The sheet inherits the window's app-wide Appearance override, same
        // as every other screen.
        present(UINavigationController(rootViewController: SettingsViewController()), animated: true)
    }

    // MARK: - Table

    private func configureTable(below topBar: UIView) {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.sectionHeaderTopPadding = 0
        // Groups are split by whitespace, not a line (the macOS sidebar way): a
        // fixed footer gap under each group. Zeroing the *estimates* keeps the
        // table from adding its own phantom footer height on top of ours.
        tableView.estimatedSectionHeaderHeight = 0
        tableView.estimatedSectionFooterHeight = 0
        tableView.keyboardDismissMode = .onDrag
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "session")
        tableView.register(
            ProjectHeaderView.self,
            forHeaderFooterViewReuseIdentifier: ProjectHeaderView.reuseID
        )
        tableView.translatesAutoresizingMaskIntoConstraints = false
        // The floating glass footer sits over the list, so the list runs to the
        // bottom edge and reserves room with an inset — the last rows clear the
        // pill instead of butting a divider.
        tableView.contentInset.bottom = 56
        tableView.verticalScrollIndicatorInsets.bottom = 56
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 16),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// Applies the chosen order: as pushed (the Mac's recent-activity order)
    /// or A→Z by project name.
    private func refilter() {
        visible = sortByName
            ? projects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            : projects
        tableView.reloadData()
        updateEmptyState()
    }

    // MARK: - Collapse

    /// The stable per-project collapse key. Path is stable across roster pushes;
    /// name is the fallback for the (path-less) bundled mock.
    private func collapseKey(_ project: MockProject) -> String {
        project.path.isEmpty ? project.name : project.path
    }

    /// Whether a section is collapsed. Every project folds, including a lone one.
    private func isCollapsed(_ section: Int) -> Bool {
        collapsed.contains(collapseKey(visible[section]))
    }

    /// Toggle a project's disclosure: flip and persist the state, spin the
    /// header's chevron, and slide the rows in/out. Uses row insert/delete
    /// (not a section reload) so the tapped header stays put and its chevron
    /// animates smoothly.
    private func toggleCollapse(section: Int, header: ProjectHeaderView) {
        guard section < visible.count else { return }
        let project = visible[section]
        let key = collapseKey(project)
        let nowCollapsed = !collapsed.contains(key)
        if nowCollapsed { collapsed.insert(key) } else { collapsed.remove(key) }
        UserDefaults.standard.set(Array(collapsed), forKey: "sessions.collapsedProjects")
        header.setCollapsed(nowCollapsed, animated: true)
        let rows = (0..<project.sessions.count).map { IndexPath(row: $0, section: section) }
        guard !rows.isEmpty else { return }
        tableView.performBatchUpdates {
            if nowCollapsed {
                tableView.deleteRows(at: rows, with: .fade)
            } else {
                tableView.insertRows(at: rows, with: .fade)
            }
        }
    }

    // MARK: - Empty state

    private func configureEmptyState(below topBar: UIView) {
        emptyState.isHidden = true
        // The button's job depends on the state: unpaired → go pair a Mac in
        // Settings; stalled reconnect → kick the socket now ("Try Again").
        emptyState.onAction = { [weak self] in self?.emptyStateAction() }
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyState)
        NSLayoutConstraint.activate([
            emptyState.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 16),
            emptyState.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyState.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// Show the zero state only when there are genuinely no rows, and phrase it
    /// for where the link is: unpaired (onboard), connecting (reassure) →
    /// stalled (the Mac isn't answering — offer Try Again), or connected-but-idle
    /// (nudge toward starting one on the Mac).
    private func updateEmptyState() {
        emptyState.isHidden = !visible.isEmpty
        guard !emptyState.isHidden else {
            stopConnectingGraceTimer()
            return
        }
        switch CompanionLink.state {
        case .unpaired:
            stopConnectingGraceTimer()
            reconnectStalled = false
            emptyState.configure(
                symbol: "macbook.and.iphone",
                title: "No Mac connected",
                message: "Open termio on your Mac, then pair this phone to see and drive your sessions from here.",
                actionTitle: "Connect a Mac",
                busy: false
            )
        case .connecting where reconnectStalled:
            // The socket has been down long enough that the Mac is probably
            // asleep or off-network. Say so, and let the user force a retry —
            // the link keeps trying on its slow heartbeat regardless.
            emptyState.configure(
                symbol: "wifi.exclamationmark",
                title: "Can't reach your Mac",
                message: "It may be asleep or off your network. termio keeps trying — reopen the lid, or tap to retry now.",
                actionTitle: "Try Again",
                busy: false
            )
        case .connecting:
            startConnectingGraceTimer()
            emptyState.configure(
                symbol: nil,
                title: "Connecting…",
                message: "Reaching your Mac over the companion link.",
                actionTitle: nil,
                busy: true
            )
        case .connected:
            stopConnectingGraceTimer()
            reconnectStalled = false
            emptyState.configure(
                symbol: "tray",
                title: "No active sessions",
                message: "Start a session on your Mac, or tap ＋ above, and it'll show up here.",
                actionTitle: nil,
                busy: false
            )
        }
    }

    /// After ~15s of unbroken "Connecting…", assume the Mac isn't coming right
    /// back and escalate the copy. Foreground/path events that reconnect will
    /// flip the state to `.connected` and cancel this.
    private func startConnectingGraceTimer() {
        guard connectingGraceTimer == nil, !reconnectStalled else { return }
        connectingGraceTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            guard let self else { return }
            connectingGraceTimer = nil
            reconnectStalled = true
            updateEmptyState()
        }
    }

    private func stopConnectingGraceTimer() {
        connectingGraceTimer?.invalidate()
        connectingGraceTimer = nil
    }

    /// The zero-state button. Unpaired → open pairing; stalled → force an
    /// immediate reconnect and drop back to the "Connecting…" copy.
    private func emptyStateAction() {
        if case .unpaired = CompanionLink.state {
            presentSettings()
            return
        }
        reconnectStalled = false
        updateEmptyState()
        if let client {
            client.reconnectNow()
        } else if let url = CompanionLink.savedURL {
            connectRoster(to: url)
        }
    }

    // MARK: - Roster

    /// A companion roster URL comes from a launch arg (`-roster-url ws://…`) or
    /// UserDefaults; when present the list switches to the Mac's live roster.
    private func connectRosterIfConfigured() {
        // Demo modes (UI tests, screenshots) are hermetic: they show the
        // bundled mock roster, not whatever Mac this device paired with last.
        // This is the ONLY path that surfaces the sample sessions.
        guard !ProcessInfo.processInfo.arguments.contains("-demo") else {
            projects = MockProject.samples
            refilter()
            return
        }
        let arg = ProcessInfo.processInfo.arguments
            .firstIndex(of: "-roster-url")
            .flatMap { idx -> String? in
                let next = idx + 1
                return ProcessInfo.processInfo.arguments.indices.contains(next)
                    ? ProcessInfo.processInfo.arguments[next] : nil
            }
        let saved = CompanionLink.savedURL?.absoluteString
        guard let urlString = arg ?? saved, let url = URL(string: urlString) else { return }
        connectRoster(to: url)
    }

    /// Open (or replace) the app's single Mac link: one socket, whole roster.
    private func connectRoster(to url: URL) {
        companionURL = url
        CompanionLink.state = .connecting
        let client = CompanionClient(url: url)
        client.onConnected = { connected in
            CompanionLink.state = connected ? .connected : .connecting
        }
        client.onRoster = { [weak self] roster in
            guard let self else { return }
            projects = roster.projects.map(MockProject.init(roster:))
            enabledAgents = roster.agents
            refilter()
            // Open terminals track their session's live status from here —
            // the roster socket is the app's only status feed.
            let statuses = Dictionary(
                roster.projects.flatMap { project in
                    project.sessions.map { ($0.id, SessionStatus(wire: $0.status)) }
                },
                uniquingKeysWith: { first, _ in first }
            )
            NotificationCenter.default.post(
                name: .sessionStatusesDidChange, object: nil,
                userInfo: ["statuses": statuses]
            )
        }
        client.onStarted = { [weak self] sessionID in
            self?.openStartedSession(sessionID)
        }
        client.onError = { [weak self] reason in
            guard let self, pendingStart != nil else { return }
            pendingStart = nil
            let alert = UIAlertController(title: "Couldn't start session", message: reason, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
        client.start()
        self.client = client
    }

    private func startSession(agent: String, in project: MockProject) {
        guard let projectID = project.rosterID else { return }
        pendingStart = (project, agent)
        client?.send(.start(projectID: projectID, agent: agent))
    }

    /// The Mac created the session; open it attached, like tapping its row.
    private func openStartedSession(_ sessionID: String) {
        guard let pending = pendingStart else { return }
        pendingStart = nil
        let title = switch pending.agent {
        case "claude": "Claude Code"
        case "codex": "Codex"
        default: "Terminal"
        }
        let session = MockSession(
            title: title,
            project: pending.project.name,
            agent: AgentKind(wire: pending.agent),
            status: .idle,
            subtitle: "", time: "",
            rosterID: sessionID,
            projectRosterID: pending.project.rosterID,
            projectPath: pending.project.path,
            branch: pending.project.branch
        )
        onOpenSession?(session, companionURL)
    }
}

// MARK: - Table data source / delegate

extension SessionListViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int {
        visible.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        isCollapsed(section) ? 0 : visible[section].sessions.count
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let header = tableView.dequeueReusableHeaderFooterView(
            withIdentifier: ProjectHeaderView.reuseID
        ) as! ProjectHeaderView
        let project = visible[section]
        header.configure(
            title: project.name,
            canCollapse: true,
            collapsed: isCollapsed(section)
        )
        header.onToggle = { [weak self, weak header] in
            guard let self, let header else { return }
            self.toggleCollapse(section: section, header: header)
        }
        // The Mac project menu's "New … Session" actions, as a + on the group
        // header — the project-level home for project-level actions (reachable
        // even when every session is closed). Shown only for live projects.
        if companionURL != nil, project.rosterID != nil {
            header.addButton.isHidden = false
            header.addButton.accessibilityLabel = "New session in \(project.name)"
            header.addButton.menu = UIMenu(children: newSessionActions(in: project))
        } else {
            header.addButton.isHidden = true
            header.addButton.menu = nil
        }
        return header
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        // One height for every group so, when collapsed, the folder rows stack
        // on an even rhythm with each between-group hairline sitting exactly
        // midway — the content is centered, so symmetric top/bottom spacing.
        42
    }

    /// A whitespace gap below each group — the divider-free separator between
    /// projects, matching the macOS sidebar's spacing-based grouping.
    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        12
    }

    /// An empty (transparent) footer view, so the gap above is just whitespace.
    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        UIView()
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "session", for: indexPath)
        cell.selectionStyle = .none
        cell.backgroundColor = .clear
        let session = visible[indexPath.section].sessions[indexPath.row]
        cell.contentConfiguration = UIHostingConfiguration {
            SidebarSessionRow(session: session, isCurrent: session.key == currentSessionKey)
        }
        // Indent past the folder mark so the sessions read as nested under their
        // project (no divider line needed to tell the groups apart).
        .margins(.leading, 30)
        .margins(.trailing, 12)
        .margins(.vertical, 1)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let session = visible[indexPath.section].sessions[indexPath.row]
        onOpenSession?(session, companionURL)
    }

    /// Trailing swipe: the Mac session menu's "Close Session". New-session
    /// actions live on the project HEADER's + menu, not on session rows —
    /// they act on the project, and headers can't swipe on iOS.
    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard companionURL != nil,
              let sessionID = visible[indexPath.section].sessions[indexPath.row].rosterID
        else { return nil }
        let close = UIContextualAction(style: .destructive, title: "Close") { [weak self] _, _, done in
            // Close on the Mac; the next roster push drops the row.
            self?.client?.send(.stop(sessionID: sessionID))
            done(true)
        }
        close.image = UIImage(systemName: "xmark.circle")
        return UISwipeActionsConfiguration(actions: [close])
    }

    func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard companionURL != nil,
              let sessionID = visible[indexPath.section].sessions[indexPath.row].rosterID
        else { return nil }
        let title = visible[indexPath.section].sessions[indexPath.row].title
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(title: title, children: [
                UIAction(
                    title: "Close Session",
                    image: UIImage(systemName: "xmark.circle"),
                    attributes: .destructive
                ) { [weak self] _ in
                    // Close on the Mac; the next roster push drops the row.
                    self?.client?.send(.stop(sessionID: sessionID))
                },
            ])
        }
    }
}

// MARK: - Project header

/// A collapsible project group header, mirroring the macOS sidebar: the folder
/// glyph itself is the open/closed affordance — an **open** folder when the
/// project's sessions are showing, a **closed** one when folded — so there is
/// no separate chevron. Tapping anywhere across the name row toggles collapse;
/// the project's "New … Session" ＋ menu rides the right, kept as its own hit
/// target so reaching for it never folds the group. Like the macOS sidebar,
/// there is **no divider line** between groups — the bold header, the folder
/// mark, and the whitespace footer below each group carry the grouping, and the
/// session rows indent beneath it. Content is vertically centered.
private final class ProjectHeaderView: UITableViewHeaderFooterView {
    static let reuseID = "projectHeader"

    /// The same Hugeicons folder marks the macOS sidebar draws, rendered once
    /// as tintable template images (open = expanded, closed = collapsed).
    private let openFolder: UIImage?
    private let closedFolder: UIImage?

    private let folderIcon = UIImageView()
    private let titleLabel = UILabel()
    /// Exposed so the list can hang the per-project "New Session" menu on it.
    let addButton = UIButton(type: .system)
    /// The tap region (folder + name, filling the row up to the ＋ button).
    private let discloseButton = UIControl()

    /// Fired when the row is tapped.
    var onToggle: (() -> Void)?

    override init(reuseIdentifier: String?) {
        openFolder = ProjectHeaderView.renderFolder(open: true, size: 18)
        closedFolder = ProjectHeaderView.renderFolder(open: false, size: 18)
        super.init(reuseIdentifier: reuseIdentifier)

        folderIcon.tintColor = .secondaryLabel
        folderIcon.contentMode = .center
        folderIcon.setContentHuggingPriority(.required, for: .horizontal)

        // Bigger than the 15pt session titles but at a normal weight — the size
        // and the folder mark set the project apart, not a heavy stroke.
        titleLabel.font = .systemFont(ofSize: 18, weight: .regular)
        titleLabel.textColor = .label
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addButton.setImage(UIImage(systemName: "plus"), for: .normal)
        addButton.setPreferredSymbolConfiguration(.init(pointSize: 18, weight: .regular), forImageIn: .normal)
        addButton.tintColor = .secondaryLabel
        addButton.showsMenuAsPrimaryAction = true

        let content = UIStackView(arrangedSubviews: [folderIcon, titleLabel])
        content.axis = .horizontal
        content.alignment = .center
        content.spacing = 9
        content.isUserInteractionEnabled = false
        content.translatesAutoresizingMaskIntoConstraints = false

        discloseButton.translatesAutoresizingMaskIntoConstraints = false
        discloseButton.addSubview(content)
        discloseButton.addAction(UIAction { [weak self] _ in self?.onToggle?() }, for: .touchUpInside)
        discloseButton.addTarget(self, action: #selector(pressDown), for: [.touchDown, .touchDragEnter])
        discloseButton.addTarget(
            self, action: #selector(pressUp),
            for: [.touchUpInside, .touchUpOutside, .touchDragExit, .touchCancel]
        )

        addButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(discloseButton)
        contentView.addSubview(addButton)

        NSLayoutConstraint.activate([
            // 16pt leading lines the folder mark up with the "Sessions" title's
            // left rail; the session rows below indent past it to read as nested
            // children.
            content.leadingAnchor.constraint(equalTo: discloseButton.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(lessThanOrEqualTo: discloseButton.trailingAnchor),
            content.centerYAnchor.constraint(equalTo: discloseButton.centerYAnchor),

            discloseButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            discloseButton.topAnchor.constraint(equalTo: contentView.topAnchor),
            discloseButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            discloseButton.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -8),

            addButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            addButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 44),
            addButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The macOS sidebar's Hugeicons folder, stroked at its native 1.5-on-24
    /// ratio and flattened to a tintable template image.
    @MainActor
    private static func renderFolder(open: Bool, size: CGFloat) -> UIImage? {
        let mark = HugeIconShape(icon: open ? .folderOpen : .folder)
            .stroke(
                Color.black,
                style: StrokeStyle(lineWidth: max(1.1, size * 1.5 / 24), lineCap: .round, lineJoin: .round)
            )
            .frame(width: size, height: size)
        let renderer = ImageRenderer(content: mark)
        renderer.scale = UIScreen.main.scale
        return renderer.uiImage?.withRenderingMode(.alwaysTemplate)
    }

    @objc private func pressDown() {
        UIView.animate(withDuration: 0.1) { self.discloseButton.alpha = 0.5 }
    }

    @objc private func pressUp() {
        UIView.animate(withDuration: 0.2) { self.discloseButton.alpha = 1 }
    }

    func configure(title: String, canCollapse: Bool, collapsed: Bool) {
        titleLabel.text = title
        discloseButton.isUserInteractionEnabled = canCollapse
        discloseButton.isAccessibilityElement = true
        discloseButton.accessibilityTraits = canCollapse ? .button : .header
        discloseButton.accessibilityLabel = title
        setCollapsed(canCollapse ? collapsed : false, animated: false)
    }

    /// Swap between the open and closed folder — the disclosure state — and
    /// update the a11y value. Cross-fade on tap; instant on a data reload.
    func setCollapsed(_ collapsed: Bool, animated: Bool) {
        discloseButton.accessibilityValue = collapsed ? "Collapsed" : "Expanded"
        let image = collapsed ? closedFolder : openFolder
        guard folderIcon.image !== image else { return }
        if animated {
            UIView.transition(with: folderIcon, duration: 0.22, options: .transitionCrossDissolve) {
                self.folderIcon.image = image
            }
        } else {
            folderIcon.image = image
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onToggle = nil
        addButton.menu = nil
        discloseButton.alpha = 1
    }
}

// MARK: - Rows

/// A session row, ChatGPT-chat-list style: mostly just the title, the agent
/// mark (or its working spinner) leading, the status dot trailing, and the
/// current session wrapped in a rounded pill. When the session carries live
/// activity text (a pending question, the running command), it appears as a
/// gray preview line under the title — Messages' "last message", shown only
/// when there is one, so quiet sessions stay one dense line.
private struct SidebarSessionRow: View {
    let session: MockSession
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if session.status == .working {
                    WorkingIndicator(tint: session.agent.tintColor)
                } else {
                    AgentIconView(agent: session.agent, size: 14)
                }
            }
            .frame(width: 16, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !session.subtitle.isEmpty {
                    Text(session.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 4)
            StatusDot(status: session.status)
                .frame(height: 18)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            isCurrent ? Color.primary.opacity(0.08) : .clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }
}

// MARK: - Empty state view

/// The centered zero state — a quiet glyph (or spinner), a title, a line of
/// guidance, and an optional pill button. Modeled on Messages/Telegram's empty
/// inbox: never fake content, always a status + a next step.
private final class SessionListEmptyState: UIView {
    private let icon = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let actionButton = UIButton(type: .system)
    /// Fired when the pill button is tapped (only shown when it has a title).
    var onAction: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        icon.contentMode = .center
        icon.tintColor = .tertiaryLabel
        icon.preferredSymbolConfiguration = .init(pointSize: 44, weight: .regular)
        spinner.color = .secondaryLabel
        spinner.hidesWhenStopped = true

        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center

        messageLabel.font = .systemFont(ofSize: 15)
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        actionButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        actionButton.addAction(UIAction { [weak self] _ in self?.onAction?() }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [icon, spinner, titleLabel, messageLabel, actionButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.setCustomSpacing(16, after: icon)
        stack.setCustomSpacing(20, after: messageLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            // Nudged above dead-center so it reads as content, not a modal.
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -44),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 44),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -44),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(symbol: String?, title: String, message: String, actionTitle: String?, busy: Bool) {
        if let symbol {
            icon.image = UIImage(systemName: symbol)
            icon.isHidden = false
        } else {
            icon.isHidden = true
        }
        if busy { spinner.startAnimating() } else { spinner.stopAnimating() }
        titleLabel.text = title
        messageLabel.text = message
        if let actionTitle {
            actionButton.setTitle(actionTitle, for: .normal)
            actionButton.isHidden = false
        } else {
            actionButton.isHidden = true
        }
    }
}
