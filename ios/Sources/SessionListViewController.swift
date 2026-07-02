import SwiftUI
import TermioSSH
import TermioShared
import UIKit

/// The home list: a single expandable tree matching the macOS sidebar —
/// projects are collapsible headers, their sessions nested inline, everything
/// in one scroll. Tap a project to expand/collapse; tap a session to open it.
final class ProjectTreeViewController: UITableViewController {
    /// Live roster from the Mac when a companion URL is configured, else the
    /// bundled mock so the UI is explorable offline.
    private var projects: [MockProject] = MockProject.samples
    /// Indices of expanded projects — all open by default, like the desktop.
    private var expanded: Set<Int> = []
    private var client: CompanionClient?
    /// The companion server URL when the tree is live — session taps open the
    /// real Mac PTY through it instead of the bundled demo shell.
    private var companionURL: URL?

    /// A flattened row is either a project header or one of its sessions,
    /// rebuilt from `expanded` on every toggle (the file-tree pattern).
    private enum Row {
        case project(Int)
        case session(project: Int, session: Int)
    }
    private var rows: [Row] = []

    init() {
        super.init(style: .plain)
        expanded = Set(projects.indices)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "termio"
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            primaryAction: UIAction { [weak self] _ in self?.presentConnectSheet() }
        )
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        tableView.separatorStyle = .none
        rebuildRows()
        connectRosterIfConfigured()
    }

    /// A companion roster URL comes from a launch arg (`-roster-url ws://…`) or
    /// UserDefaults; when present the tree switches to the Mac's live list.
    private func connectRosterIfConfigured() {
        let arg = ProcessInfo.processInfo.arguments
            .firstIndex(of: "-roster-url")
            .flatMap { idx -> String? in
                let next = idx + 1
                return ProcessInfo.processInfo.arguments.indices.contains(next)
                    ? ProcessInfo.processInfo.arguments[next] : nil
            }
        let saved = UserDefaults.standard.string(forKey: "companion.rosterURL")
        guard let urlString = arg ?? saved, let url = URL(string: urlString) else { return }

        companionURL = url
        let client = CompanionClient(url: url)
        client.onRoster = { [weak self] roster in
            guard let self else { return }
            projects = roster.map(MockProject.init(roster:))
            expanded = Set(projects.indices)
            rebuildRows()
            tableView.reloadData()
        }
        client.start()
        self.client = client
    }

    private func rebuildRows() {
        rows = []
        for (p, _) in projects.enumerated() {
            rows.append(.project(p))
            if expanded.contains(p) {
                for s in projects[p].sessions.indices {
                    rows.append(.session(project: p, session: s))
                }
            }
        }
    }

    private func presentConnectSheet() {
        let connect = ConnectViewController()
        connect.onConnect = { [weak self] config in
            self?.navigationController?.pushViewController(
                TerminalViewController(sshConfig: config),
                animated: true
            )
        }
        present(UINavigationController(rootViewController: connect), animated: true)
    }

    // MARK: - Table

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        switch rows[indexPath.row] {
        case .project: 38
        case .session: 44
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        cell.selectionStyle = .none
        switch rows[indexPath.row] {
        case .project(let p):
            let project = projects[p]
            let isOpen = expanded.contains(p)
            cell.contentConfiguration = UIHostingConfiguration {
                ProjectHeaderRow(project: project, expanded: isOpen)
            }
            .margins(.vertical, 4)
        case .session(let p, let s):
            let session = projects[p].sessions[s]
            cell.contentConfiguration = UIHostingConfiguration {
                SessionRow(session: session)
            }
            .margins(.vertical, 2)
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        switch rows[indexPath.row] {
        case .project(let p):
            if expanded.contains(p) { expanded.remove(p) } else { expanded.insert(p) }
            rebuildRows()
            tableView.reloadSections([0], with: .automatic)
        case .session(let p, let s):
            let session = projects[p].sessions[s]
            let terminal: TerminalViewController
            if let companionURL, session.rosterID != nil {
                terminal = TerminalViewController(companionURL: companionURL, session: session)
            } else {
                terminal = TerminalViewController(session: session)
            }
            navigationController?.pushViewController(terminal, animated: true)
        }
    }
}

// MARK: - Rows

/// A project header: folder mark (open when expanded), the project name in the
/// desktop's uppercase style, and a roll-up of session state on the right.
private struct ProjectHeaderRow: View {
    let project: MockProject
    let expanded: Bool

    var body: some View {
        HStack(spacing: 6) {
            HugeIconView(icon: expanded ? .folderOpen : .folder, size: 15, color: .monochromeInk)
                .frame(width: 16)
            Text(project.name.uppercased())
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let tint = workingTint {
                WorkingIndicator(tint: tint)
            }
            if hasAttention {
                StatusDot(status: .needsAttention)
            }
            Text("\(project.sessions.count)")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
    }

    private var workingTint: Color? {
        project.sessions.first { $0.status == .working }?.agent.tintColor
    }

    private var hasAttention: Bool {
        project.sessions.contains { $0.status == .needsAttention }
    }
}

/// A session row under a project, matching the desktop sidebar: the working
/// spinner (in the agent's brand color) while a turn is in flight, else the
/// brand mark; a status dot trails only when done or awaiting the user.
private struct SessionRow: View {
    let session: MockSession

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if session.status == .working {
                    WorkingIndicator(tint: session.agent.tintColor)
                } else {
                    AgentIconView(agent: session.agent, size: 13)
                }
            }
            .frame(width: 16)
            Text(session.title)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            StatusDot(status: session.status)
        }
        .padding(.leading, 16) // nest under the project's folder mark
    }
}
