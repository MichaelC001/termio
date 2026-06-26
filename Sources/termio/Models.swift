import Foundation

/// A project is a working directory (typically a git repo) that groups one or
/// more agent/terminal sessions, mirroring the sidebar grouping in unpeel.
struct Project: Identifiable, Hashable {
    let id = UUID()
    var name: String
    /// Absolute path used as the working directory for the project's sessions.
    var path: String
    /// Current git branch, shown in each session's top bar (display only for now).
    var branch: String
    var sessions: [Session]
}

/// A single terminal session within a project. Each session owns one live
/// libghostty terminal surface (see `TermioStore.surface(for:in:)`).
struct Session: Identifiable, Hashable {
    let id = UUID()
    var title: String
    /// Program to launch in the session. `nil` runs the user's login shell;
    /// otherwise this is passed to libghostty's `command` config (e.g. "claude").
    var command: String?
    var createdAt: Date

    init(title: String, command: String? = nil, createdAt: Date = Date()) {
        self.title = title
        self.command = command
        self.createdAt = createdAt
    }
}

extension Project {
    /// Seed data pointing at directories that exist, so the `.exec` backend has
    /// a valid working directory to launch the shell in.
    static func sampleProjects() -> [Project] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let repo = FileManager.default.currentDirectoryPath

        return [
            Project(
                name: "termio",
                path: repo,
                branch: "main",
                sessions: [
                    Session(title: "shell"),
                    Session(title: "build & run"),
                ]
            ),
            Project(
                name: "home",
                path: home,
                branch: "—",
                sessions: [
                    Session(title: "scratch"),
                ]
            ),
        ]
    }
}
