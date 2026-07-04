import SwiftUI
import TermioSSH
import TermioShared
import UIKit

/// The root screen, iMessage-inbox style: a large title with sort and compose
/// buttons riding it, the sessions grouped under small gray project headers,
/// and a floating settings button bottom-right. Lives at the root of
/// RootContainerViewController's navigation stack and owns the companion
/// roster connection; pairing itself lives in Settings ▸ Connectivity.
final class SessionListViewController: UIViewController {
    /// Open a session row; `companionURL` is non-nil when the row is live.
    var onOpenSession: ((MockSession, URL?) -> Void)?
    var onOpenSSH: ((SSHConfig) -> Void)?
    /// `MockSession.key` of the session filling the screen — its row gets
    /// the current-chat pill.
    var currentSessionKey: String?

    /// Live roster from the Mac when a companion URL is configured, else the
    /// bundled mock so the UI is explorable offline.
    private var projects: [MockProject] = MockProject.samples
    /// `projects` in the chosen order — what the table shows.
    private var visible: [MockProject] = []
    private var client: CompanionClient?
    private var companionURL: URL?
    /// The project+agent of an in-flight `start`, so the `.started` reply
    /// knows what to open.
    private var pendingStart: (project: MockProject, agent: String)?
    /// Mirrors the Mac sidebar's sort pull-down. The roster arrives in the
    /// Mac's recent-activity order, so "Recent Activity" means "as pushed";
    /// "Name" re-sorts locally A→Z.
    private var sortByName = UserDefaults.standard.string(forKey: "sessions.sortOrder") == "name"

    private let filterButton = UIButton(type: .system)
    private let composeButton = UIButton(type: .system)
    private let tableView = UITableView(frame: .zero, style: .grouped)
    private var pairingObserver: NSObjectProtocol?

    override func viewDidLoad() {
        super.viewDidLoad()
        // A full page now, not a drawer: plain system background, like the
        // Messages inbox.
        view.backgroundColor = .systemBackground
        let topBar = configureTopBar()
        configureTable(below: topBar)
        // Added last so the floating glass footer layers over the list.
        configureBottomBar()
        refilter()
        connectRosterIfConfigured()
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

        composeButton.applyGlassSymbol("square.and.pencil")
        composeButton.tintColor = .label
        composeButton.showsMenuAsPrimaryAction = true
        composeButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.composeMenuItems() ?? [])
            },
        ])

        // Messages-inbox chrome: the bold title on the left, the round
        // buttons riding the same line on the right.
        let spacer = UIView()
        let bar = UIStackView(arrangedSubviews: [pageTitle, spacer, filterButton, composeButton])
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
            composeButton.widthAnchor.constraint(equalToConstant: 40),
            composeButton.heightAnchor.constraint(equalToConstant: 40),
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

    /// Compose = ChatGPT's "new chat": pick a project, then the agent. Offline
    /// (no companion roster) it falls back to the SSH connect sheet.
    private func composeMenuItems() -> [UIMenuElement] {
        guard companionURL != nil else {
            return [UIAction(title: "Connect via SSH…", image: UIImage(systemName: "network")) { [weak self] _ in
                self?.presentConnectSheet()
            }]
        }
        return projects.filter { $0.rosterID != nil }.map { project in
            let action: (String, String) -> UIAction = { [weak self] title, agent in
                UIAction(title: title, image: AgentKind(wire: agent).menuIcon()) { _ in
                    self?.startSession(agent: agent, in: project)
                }
            }
            return UIMenu(title: project.name, image: UIImage(systemName: "folder"), children: [
                action("Claude Code", "claude"),
                action("Codex", "codex"),
                action("Terminal", "terminal"),
            ])
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

    /// Forget-Mac teardown: back to the offline mock list.
    private func disconnectRoster() {
        client?.stop()
        client = nil
        companionURL = nil
        CompanionLink.state = .unpaired
        projects = MockProject.samples
        refilter()
    }

    private func presentConnectSheet() {
        let connect = ConnectViewController()
        connect.onConnect = { [weak self] config in self?.onOpenSSH?(config) }
        present(UINavigationController(rootViewController: connect), animated: true)
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
        tableView.keyboardDismissMode = .onDrag
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "session")
        tableView.translatesAutoresizingMaskIntoConstraints = false
        // The floating glass footer sits over the list, so the list runs to the
        // bottom edge and reserves room with an inset — the last rows clear the
        // pill instead of butting a divider.
        tableView.contentInset.bottom = 56
        tableView.verticalScrollIndicatorInsets.bottom = 56
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 4),
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
    }

    // MARK: - Roster

    /// A companion roster URL comes from a launch arg (`-roster-url ws://…`) or
    /// UserDefaults; when present the list switches to the Mac's live roster.
    private func connectRosterIfConfigured() {
        // Demo modes (UI tests, screenshots) are hermetic: they show the
        // bundled mock roster, not whatever Mac this device paired with last.
        guard !ProcessInfo.processInfo.arguments.contains("-demo") else { return }
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
            projects = roster.map(MockProject.init(roster:))
            refilter()
            // Open terminals track their session's live status from here —
            // the roster socket is the app's only status feed.
            let statuses = Dictionary(
                roster.flatMap { project in
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
        visible[section].sessions.count
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        // The group label: semibold and full-contrast so the project names
        // anchor the list, not whisper under it.
        let label = UILabel()
        label.text = visible[section].name
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .label
        label.translatesAutoresizingMaskIntoConstraints = false
        let header = UIView()
        header.addSubview(label)
        // 13pt under the label so the 44pt + button, center-aligned with the
        // label, stays fully inside the header — touches outside a superview's
        // bounds never reach a subview, so an overflowing button reads as a
        // dead zone (its bottom half used to fall through to the row below).
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 22),
            label.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -13),
        ])
        // The Mac project menu's "New … Session" actions, as a + on the
        // group header — the project-level home for project-level actions
        // (and reachable even when every session is closed).
        let project = visible[section]
        if companionURL != nil, project.rosterID != nil {
            let add = UIButton(type: .system)
            add.setImage(UIImage(systemName: "plus"), for: .normal)
            add.setPreferredSymbolConfiguration(.init(pointSize: 17, weight: .medium), forImageIn: .normal)
            add.tintColor = .secondaryLabel
            add.accessibilityLabel = "New session in \(project.name)"
            add.showsMenuAsPrimaryAction = true
            add.menu = UIMenu(children: [
                UIAction(title: "Claude Code", image: AgentKind.claude.menuIcon()) { [weak self] _ in
                    self?.startSession(agent: "claude", in: project)
                },
                UIAction(title: "Codex", image: AgentKind.codex.menuIcon()) { [weak self] _ in
                    self?.startSession(agent: "codex", in: project)
                },
                UIAction(title: "Terminal", image: AgentKind.terminal.menuIcon()) { [weak self] _ in
                    self?.startSession(agent: "terminal", in: project)
                },
            ])
            add.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(add)
            NSLayoutConstraint.activate([
                add.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
                add.centerYAnchor.constraint(equalTo: label.centerYAnchor),
                add.widthAnchor.constraint(equalToConstant: 44),
                add.heightAnchor.constraint(equalToConstant: 44),
            ])
        }
        // A hairline between project groups (none above the first), so the
        // blocks read as separate — the inbox's section split.
        if section > 0 {
            let hairline = UIView()
            hairline.backgroundColor = .separator.withAlphaComponent(0.5)
            hairline.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(hairline)
            NSLayoutConstraint.activate([
                hairline.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 22),
                hairline.trailingAnchor.constraint(equalTo: header.trailingAnchor),
                hairline.topAnchor.constraint(equalTo: header.topAnchor),
                hairline.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            ])
        }
        return header
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        section == 0 ? 46 : 54
    }

    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        .leastNonzeroMagnitude
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "session", for: indexPath)
        cell.selectionStyle = .none
        cell.backgroundColor = .clear
        let session = visible[indexPath.section].sessions[indexPath.row]
        cell.contentConfiguration = UIHostingConfiguration {
            SidebarSessionRow(session: session, isCurrent: session.key == currentSessionKey)
        }
        .margins(.horizontal, 12)
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
