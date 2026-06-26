import Foundation
import GhosttyTerminal

/// App-wide state: the project/session tree plus a cache of live terminal
/// surfaces. The cache ("SurfaceCache" in unpeel's terms) keeps one
/// `TerminalViewState` alive per session so switching sessions in the sidebar
/// does not tear down the running shell.
@MainActor
final class TermioStore: ObservableObject {
    @Published var projects: [Project]
    @Published var selectedSessionID: Session.ID?

    private var surfaces: [Session.ID: TerminalViewState] = [:]

    init(projects: [Project]) {
        self.projects = projects
        self.selectedSessionID = projects.first?.sessions.first?.id
    }

    func session(_ id: Session.ID) -> Session? {
        for project in projects {
            if let session = project.sessions.first(where: { $0.id == id }) {
                return session
            }
        }
        return nil
    }

    func project(for sessionID: Session.ID) -> Project? {
        projects.first { $0.sessions.contains { $0.id == sessionID } }
    }

    /// Returns the cached terminal surface for a session, creating and starting
    /// it on first access. The surface launches `session.command` (or the login
    /// shell) in the project's working directory via the real PTY (`.exec`).
    func surface(for session: Session, in project: Project) -> TerminalViewState {
        if let existing = surfaces[session.id] {
            return existing
        }

        let controller = TerminalController { builder in
            if let command = session.command {
                builder.withCustom("command", command)
            }
        }
        let state = TerminalViewState(controller: controller)
        state.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: project.path
        )
        surfaces[session.id] = state
        return state
    }

    func addSession(to projectID: Project.ID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let session = Session(title: "session \(projects[index].sessions.count + 1)")
        projects[index].sessions.append(session)
        selectedSessionID = session.id
    }
}
