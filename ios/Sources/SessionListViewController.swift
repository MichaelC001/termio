import SwiftUI
import TermioShared
import UIKit

// MARK: - Level 1: projects

final class ProjectListViewController: UITableViewController {
    private let projects = MockProject.samples

    init() {
        super.init(style: .plain)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "termio"
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            primaryAction: nil
        )
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "project")
        tableView.rowHeight = 60
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 52, bottom: 0, right: 0)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        projects.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "project", for: indexPath)
        let project = projects[indexPath.row]
        cell.contentConfiguration = UIHostingConfiguration {
            ProjectRow(project: project)
        }
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        navigationController?.pushViewController(
            SessionListViewController(project: projects[indexPath.row]),
            animated: true
        )
    }
}

/// Project row: the desktop sidebar's project header as a list row — folder
/// mark in the same 16-wide icon slot, name, and a roll-up of session state
/// (a working spinner and/or attention dot) so the level-1 page still shows
/// where the action is.
private struct ProjectRow: View {
    let project: MockProject

    var body: some View {
        HStack(spacing: 6) {
            HugeIconView(icon: .folder, size: 15, color: .monochromeInk)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.body.weight(.medium))
                Text(project.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
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

// MARK: - Level 2: sessions in a project

final class SessionListViewController: UITableViewController {
    private let project: MockProject

    init(project: MockProject) {
        self.project = project
        super.init(style: .plain)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = project.name
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "square.and.pencil"),
            primaryAction: nil
        )
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "session")
        tableView.rowHeight = 60
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 52, bottom: 0, right: 0)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        project.sessions.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "session", for: indexPath)
        let session = project.sessions[indexPath.row]
        cell.contentConfiguration = UIHostingConfiguration {
            SessionRow(session: session)
        }
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        navigationController?.pushViewController(
            TerminalViewController(session: project.sessions[indexPath.row]),
            animated: true
        )
    }
}

/// Session row, matching the desktop sidebar's `SessionRow`: while the agent
/// is working the leading mark becomes the rotating nine-dot grid (in the
/// agent's brand color) and reverts to the brand mark when the turn ends; a
/// status dot trails only when the session is done or needs the user.
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
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(session.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(session.time)
                .font(.footnote)
                .foregroundStyle(.tertiary)
            StatusDot(status: session.status)
        }
    }
}
