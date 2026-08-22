import XCTest
@testable import termio

/// The line between detaching and destroying, against a real daemon.
///
/// A session outliving its viewer is the point of the daemon, so almost every
/// teardown path on this side must *detach*. The exceptions are the paths that
/// destroy the session on purpose — Close Session, a respawn in place, and
/// removing the project that holds them — and they have to say so explicitly,
/// because doing nothing now means leaving an agent running with nothing left
/// on this side that can reach it.
///
/// That failure is invisible to every other kind of test: the app looks right,
/// the row is gone, and the process is still burning tokens in the daemon. It
/// is only visible by asking the daemon what it still holds, which is what
/// these do.
///
/// Opt-in on the same terms as the other daemon suites: set
/// `TERMIO_TERMIOD_TEST_BIN` to run them.
@MainActor
final class TermiodDestroyIntegrationTests: XCTestCase {
    private var binary = ""
    private var daemon: Process?
    private var socketDirectory: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let configured = ProcessInfo.processInfo.environment["TERMIO_TERMIOD_TEST_BIN"] ?? ""
        try XCTSkipIf(configured.isEmpty, "set TERMIO_TERMIOD_TEST_BIN to run this")
        binary = configured

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dst-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketDirectory = directory
        let socket = directory.appendingPathComponent("termiod.sock").path
        XCTAssertLessThan(socket.utf8.count, 104, "socket path must fit sun_path")
        setenv("TERMIOD_SOCK", socket, 1)

        let serve = Process()
        serve.executableURL = URL(fileURLWithPath: binary)
        serve.arguments = ["serve"]
        serve.environment = ProcessInfo.processInfo.environment.merging(
            ["TERMIOD_SOCK": socket]) { _, new in new }
        serve.standardOutput = FileHandle.nullDevice
        serve.standardError = FileHandle.nullDevice
        try serve.run()
        daemon = serve

        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: socket), Date() < deadline {
            usleep(50_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket), "daemon never bound")
    }

    override func tearDownWithError() throws {
        daemon?.terminate()
        daemon?.waitUntilExit()
        if let socketDirectory {
            try? FileManager.default.removeItem(at: socketDirectory)
        }
        unsetenv("TERMIOD_SOCK")
        try super.tearDownWithError()
    }

    /// What the daemon still holds, read through its own CLI so the assertion
    /// does not depend on the client under test.
    private func daemonHoldsSession(named name: String) -> Bool {
        let list = Process()
        list.executableURL = URL(fileURLWithPath: binary)
        list.arguments = ["list"]
        list.environment = ProcessInfo.processInfo.environment
        let pipe = Pipe()
        list.standardOutput = pipe
        list.standardError = FileHandle.nullDevice
        guard (try? list.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        list.waitUntilExit()
        return String(data: data, encoding: .utf8)?.contains(name) ?? false
    }

    /// A store holding one project with one session, plus a live attachment to
    /// a real daemon session of the same name.
    private func makeStoreWithLiveSession() -> (TermioStore, Session, Project, String) {
        let session = Session(title: "agent", agent: .terminal)
        let workspace = Workspace(name: "Sessions")
        let project = Project(workspaceID: workspace.id, name: "termio", path: "/code/termio",
                              branch: "main", sessions: [session])
        let defaults = UserDefaults(suiteName: "termiod-destroy-\(UUID().uuidString)")
        let store = TermioStore(workspaces: [workspace], projects: [project],
                                settings: AppSettings(defaults: defaults ?? .standard))

        let name = session.id.uuidString
        let link = TermiodSessionLink(
            sessionName: name,
            specification: Termiod.CreateSpecification(
                cwd: NSTemporaryDirectory(),
                // Long-lived and harmless: the point is that something is still
                // running for the teardown to have to kill.
                argv: ["/bin/sh", "-c", "while :; do sleep 3600; done"],
                env: [], rows: 24, cols: 80),
            rows: 24, cols: 80)
        link.start()
        store.termiodLinks[session.id] = link

        let deadline = Date().addingTimeInterval(5)
        while !daemonHoldsSession(named: name), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return (store, session, project, name)
    }

    private func waitUntilDaemonDrops(_ name: String) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while daemonHoldsSession(named: name), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return !daemonHoldsSession(named: name)
    }

    /// Removing a project destroys the sessions filed under it. Before the
    /// in-process backend was deleted this was carried by terminating each PTY;
    /// nothing on this side does it implicitly any more.
    func testRemovingAProjectKillsItsSessionsInTheDaemon() throws {
        let (store, _, project, name) = makeStoreWithLiveSession()
        XCTAssertTrue(daemonHoldsSession(named: name), "the fixture never reached the daemon")

        store.removeProject(project.id)

        XCTAssertTrue(
            waitUntilDaemonDrops(name),
            "the project's sessions are still running in the daemon with no row left to reach them")
        XCTAssertNil(store.termiodLinks[project.sessions[0].id], "the attachment leaked")
    }

    /// Close Session is the destroy verb for one row, and has always said so.
    /// Pinned here beside the project case so the two cannot drift apart again.
    func testClosingASessionKillsItInTheDaemon() throws {
        let (store, session, _, name) = makeStoreWithLiveSession()
        XCTAssertTrue(daemonHoldsSession(named: name), "the fixture never reached the daemon")

        store.closeSession(session.id)

        XCTAssertTrue(waitUntilDaemonDrops(name), "Close Session left the process running")
        XCTAssertNil(store.termiodLinks[session.id], "the attachment leaked")
    }

    /// The counterpart, and the reason the daemon exists: quitting the app is
    /// not a destroy verb. Every session must survive it.
    func testQuittingDetachesRatherThanKilling() throws {
        let (store, _, _, name) = makeStoreWithLiveSession()
        XCTAssertTrue(daemonHoldsSession(named: name), "the fixture never reached the daemon")

        store.terminateAllSessions()

        // Settle long enough that a kill would have landed.
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertTrue(
            daemonHoldsSession(named: name),
            "quitting killed the session — detach-not-kill is the whole point of the daemon")
    }
}
