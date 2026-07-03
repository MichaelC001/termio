import SwiftUI
import TermioSSH
import TermioShared
import UIKit

/// The root screen, iMessage-inbox style: a large title over a search field
/// with a compose button, the sessions grouped under small gray project
/// headers, and the Mac connection pinned to the bottom like ChatGPT's
/// account row. Lives at the root of RootContainerViewController's
/// navigation stack and owns the companion roster connection.
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
    /// `projects` filtered by the search query — what the table shows.
    private var visible: [MockProject] = []
    private var client: CompanionClient?
    private var companionURL: URL?
    /// The project+agent of an in-flight `start`, so the `.started` reply
    /// knows what to open.
    private var pendingStart: (project: MockProject, agent: String)?
    private var query = ""

    private let searchField = UITextField()
    private let composeButton = UIButton(type: .system)
    private let tableView = UITableView(frame: .zero, style: .grouped)
    private let macLabel = UILabel()
    private let statusDot = UIView()
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

    // MARK: - Top bar (large title + search + compose)

    private func configureTopBar() -> UIView {
        let pageTitle = UILabel()
        pageTitle.text = "Sessions"
        pageTitle.font = .systemFont(ofSize: 34, weight: .bold)
        pageTitle.textColor = .label

        let searchBox = UIView()
        searchBox.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 0.16, alpha: 1) : UIColor(white: 0.92, alpha: 1)
        }
        searchBox.layer.cornerRadius = 10

        let glass = UIImageView(image: UIImage(systemName: "magnifyingglass"))
        glass.tintColor = .secondaryLabel
        glass.contentMode = .scaleAspectFit

        searchField.attributedPlaceholder = NSAttributedString(
            string: "Search",
            attributes: [.foregroundColor: UIColor.secondaryLabel]
        )
        searchField.textColor = .label
        searchField.font = .preferredFont(forTextStyle: .subheadline)
        searchField.autocorrectionType = .no
        searchField.autocapitalizationType = .none
        searchField.returnKeyType = .search
        searchField.clearButtonMode = .whileEditing
        searchField.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            query = searchField.text ?? ""
            refilter()
        }, for: .editingChanged)

        glass.translatesAutoresizingMaskIntoConstraints = false
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchBox.addSubview(glass)
        searchBox.addSubview(searchField)

        composeButton.applyGlassSymbol("square.and.pencil")
        composeButton.tintColor = .label
        composeButton.showsMenuAsPrimaryAction = true
        composeButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.composeMenuItems() ?? [])
            },
        ])

        let bar = UIStackView(arrangedSubviews: [searchBox, composeButton])
        bar.axis = .horizontal
        bar.alignment = .center
        bar.spacing = 8

        // Messages-inbox chrome: the bold page title sits above the search
        // row (the compose button rides the search row, not a nav bar).
        let top = UIStackView(arrangedSubviews: [pageTitle, bar])
        top.axis = .vertical
        top.alignment = .fill
        top.spacing = 10
        top.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(top)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            top.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            top.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            searchBox.heightAnchor.constraint(equalToConstant: 36),
            composeButton.widthAnchor.constraint(equalToConstant: 36),
            composeButton.heightAnchor.constraint(equalToConstant: 36),
            glass.leadingAnchor.constraint(equalTo: searchBox.leadingAnchor, constant: 10),
            glass.centerYAnchor.constraint(equalTo: searchBox.centerYAnchor),
            glass.widthAnchor.constraint(equalToConstant: 16),
            glass.heightAnchor.constraint(equalToConstant: 16),
            searchField.leadingAnchor.constraint(equalTo: glass.trailingAnchor, constant: 6),
            searchField.trailingAnchor.constraint(equalTo: searchBox.trailingAnchor, constant: -8),
            searchField.centerYAnchor.constraint(equalTo: searchBox.centerYAnchor),
        ])
        return top
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
            let action: (String, String, String) -> UIAction = { [weak self] title, icon, agent in
                UIAction(title: title, image: UIImage(systemName: icon)) { _ in
                    self?.startSession(agent: agent, in: project)
                }
            }
            return UIMenu(title: project.name, image: UIImage(systemName: "folder"), children: [
                action("Claude Code", "sparkles", "claude"),
                action("Codex", "cube", "codex"),
                action("Terminal", "terminal", "terminal"),
            ])
        }
    }

    // MARK: - Bottom bar (the "account" row: Mac connection)

    /// Telegram's iOS 26 tab bar: nothing spans the width. A rounded **glass
    /// pill** floats bottom-left (the Mac device — tap to pair/switch), and a
    /// **detached circular glass button** floats bottom-right (settings). The
    /// list scrolls under both, so the footer reads as chrome, not a divider.
    private func configureBottomBar() {
        let bar = UIView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        // Purely a layout guide for the floating pieces — no fill, no hairline.
        view.addSubview(bar)

        let avatar = UIImageView(image: UIImage(systemName: "desktopcomputer"))
        avatar.tintColor = .label
        avatar.contentMode = .center
        avatar.preferredSymbolConfiguration = .init(pointSize: 15, weight: .semibold)

        macLabel.text = "Connect to Mac"
        macLabel.font = .preferredFont(forTextStyle: .subheadline)
        macLabel.textColor = .label

        // Presence dot on the Mac avatar, iMessage-style: green = roster link
        // up, orange = paired but reconnecting. Hidden until a Mac is paired.
        statusDot.backgroundColor = .systemOrange
        statusDot.layer.cornerRadius = 5
        statusDot.layer.borderWidth = 2
        statusDot.layer.borderColor = UIColor.systemBackground.cgColor
        statusDot.isHidden = true

        // The device pill: a capsule of liquid glass holding the avatar + name.
        let pill = Self.makeGlassView(interactive: true)
        let pillContent = pill.contentView
        for subview in [avatar, macLabel, statusDot] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            pillContent.addSubview(subview)
        }
        pill.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(bottomBarTapped)))

        // The settings puck: a circle of the same glass, detached to the right.
        let gear = UIButton(type: .system)
        gear.setImage(
            UIImage(systemName: "gearshape", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)),
            for: .normal
        )
        gear.tintColor = .label
        gear.addAction(UIAction { [weak self] _ in
            self?.presentSettings()
        }, for: .touchUpInside)
        let puck = Self.makeGlassView(interactive: true)
        gear.translatesAutoresizingMaskIntoConstraints = false
        puck.contentView.addSubview(gear)

        for piece in [pill, puck] {
            piece.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(piece)
        }

        let pillHeight: CGFloat = 44
        pill.layer.cornerRadius = pillHeight / 2
        pill.clipsToBounds = true
        puck.layer.cornerRadius = pillHeight / 2
        puck.clipsToBounds = true

        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            bar.heightAnchor.constraint(equalToConstant: pillHeight),

            pill.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            pill.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            pill.heightAnchor.constraint(equalToConstant: pillHeight),
            pill.trailingAnchor.constraint(lessThanOrEqualTo: puck.leadingAnchor, constant: -10),

            avatar.leadingAnchor.constraint(equalTo: pillContent.leadingAnchor, constant: 8),
            avatar.centerYAnchor.constraint(equalTo: pillContent.centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 28),
            avatar.heightAnchor.constraint(equalToConstant: 28),
            macLabel.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 8),
            macLabel.trailingAnchor.constraint(equalTo: pillContent.trailingAnchor, constant: -16),
            macLabel.centerYAnchor.constraint(equalTo: pillContent.centerYAnchor),
            statusDot.centerXAnchor.constraint(equalTo: avatar.trailingAnchor, constant: -1),
            statusDot.centerYAnchor.constraint(equalTo: avatar.bottomAnchor, constant: -1),
            statusDot.widthAnchor.constraint(equalToConstant: 10),
            statusDot.heightAnchor.constraint(equalToConstant: 10),

            puck.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            puck.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            puck.widthAnchor.constraint(equalToConstant: pillHeight),
            puck.heightAnchor.constraint(equalToConstant: pillHeight),
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

    /// The account row: pair with a Mac ONCE — the roster link then carries
    /// every project and session on it (switch, start, stop), no per-session
    /// setup ever.
    @objc private func bottomBarTapped() {
        let alert = UIAlertController(
            title: "Connect to Mac",
            message: "The address termio on your Mac is serving (one-time — all sessions ride this link).",
            preferredStyle: .alert
        )
        alert.addTextField { [weak self] field in
            field.placeholder = "ws://mac-hostname:8787"
            field.text = CompanionLink.savedURL?.absoluteString
                ?? self?.companionURL?.absoluteString
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.keyboardType = .URL
        }
        alert.addAction(UIAlertAction(title: "Connect", style: .default) { [weak self, weak alert] _ in
            guard let text = alert?.textFields?.first?.text else { return }
            self?.setCompanionURL(text)
        })
        alert.addAction(UIAlertAction(title: "SSH Instead…", style: .default) { [weak self] _ in
            self?.presentConnectSheet()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    /// Save the Mac address and (re)connect the roster link to it.
    private func setCompanionURL(_ raw: String) {
        guard let url = CompanionLink.normalize(raw) else { return }
        UserDefaults.standard.set(url.absoluteString, forKey: CompanionLink.defaultsKey)
        client?.stop()
        client = nil
        connectRoster(to: url)
    }

    /// Forget-Mac teardown: back to the offline mock list.
    private func disconnectRoster() {
        client?.stop()
        client = nil
        companionURL = nil
        macLabel.text = "Connect to Mac"
        statusDot.isHidden = true
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

    private func refilter() {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty {
            visible = projects
        } else {
            visible = projects.compactMap { project in
                if project.name.lowercased().contains(q) { return project }
                let hits = project.sessions.filter { $0.title.lowercased().contains(q) }
                return hits.isEmpty ? nil : MockProject(
                    name: project.name, path: project.path,
                    rosterID: project.rosterID, branch: project.branch,
                    sessions: hits
                )
            }
        }
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
        macLabel.text = url.host ?? "Mac"
        statusDot.isHidden = false
        statusDot.backgroundColor = .systemOrange
        CompanionLink.state = .connecting
        let client = CompanionClient(url: url)
        client.onConnected = { [weak self] connected in
            self?.statusDot.backgroundColor = connected ? .systemGreen : .systemOrange
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
        // ChatGPT's group label: small, gray, flush with the row text.
        let label = UILabel()
        label.text = visible[section].name
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        let header = UIView()
        header.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 22),
            label.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -6),
        ])
        return header
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        section == 0 ? 30 : 36
    }

    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        .leastNonzeroMagnitude
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        44
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
/// current session wrapped in a rounded pill.
private struct SidebarSessionRow: View {
    let session: MockSession
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if session.status == .working {
                    WorkingIndicator(tint: session.agent.tintColor)
                } else {
                    AgentIconView(agent: session.agent, size: 14)
                }
            }
            .frame(width: 16)
            Text(session.title)
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            StatusDot(status: session.status)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            isCurrent ? Color.primary.opacity(0.08) : .clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }
}
