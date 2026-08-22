import Network
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

/// The keystroke-echo guard's input clock.
///
/// Input echo repaints the screen exactly like agent output does, so the status
/// tap suppresses promotion for a moment after something was typed. That only
/// works if it can see typing from *every* device. The Mac and a phone hold
/// separate attachments to one session, so a timestamp kept on either
/// attachment is invisible to the other — which made composing on the phone
/// promote an idle agent to `working`.
@MainActor
final class SessionInputClockTests: XCTestCase {
    private func makeStore(_ session: Session) -> TermioStore {
        let workspace = Workspace(name: "Sessions")
        let project = Project(workspaceID: workspace.id, name: "termio", path: "/code/termio",
                              branch: "main", sessions: [session])
        let defaults = UserDefaults(suiteName: "input-clock-\(UUID().uuidString)")
        return TermioStore(workspaces: [workspace], projects: [project],
                           settings: AppSettings(defaults: defaults ?? .standard))
    }

    /// The clock is per session, not per attachment: whichever device carried
    /// the keystroke, the guard reads one answer.
    func testInputIsRecordedAgainstTheSessionNotTheConnection() {
        let session = Session(title: "agent", agent: .terminal)
        let store = makeStore(session)
        XCTAssertNil(store.inputClock.lastInput(for: session.id), "nothing has been typed yet")

        store.noteInput(for: session.id)

        let stamped = store.inputClock.lastInput(for: session.id)
        XCTAssertNotNil(stamped)
        XCTAssertLessThan(
            Date().timeIntervalSince(stamped ?? .distantPast), 1,
            "the stamp must be the moment of the keystroke")
    }

    /// The phone's route in. It attaches separately from the Mac, so this is the
    /// only path by which its typing reaches the guard — and it is addressed by
    /// wire id, the phone's name for the session, not by `Session.ID`.
    func testAPhoneKeystrokeReachesTheSameClock() throws {
        let session = Session(title: "agent", agent: .terminal)
        let store = makeStore(session)

        store.noteCompanionInput(session.id.uuidString)

        XCTAssertNotNil(
            store.inputClock.lastInput(for: session.id),
            "a phone's keystroke never reached the session's input clock")
    }

    /// A wire id for a session this Mac does not have must not stamp anything —
    /// a stale phone re-attaching after a session closed would otherwise keep
    /// an unrelated row's guard alive.
    func testAnUnknownWireIDStampsNothing() {
        let session = Session(title: "agent", agent: .terminal)
        let store = makeStore(session)

        store.noteCompanionInput(UUID().uuidString)

        XCTAssertTrue(store.inputClock.isEmpty, "an unknown session was stamped")
    }
}

/// The phone's keystrokes reaching the session's input clock — through the
/// bridge that actually carries them.
///
/// The first version of this coverage called `noteCompanionInput` directly,
/// which proved only that a store method works. Severing `SessionBridge`'s
/// `onInput` — the line that was actually missing — left it green. A test that
/// cannot fail for the reason the bug existed is not coverage.
///
/// No daemon here on purpose: an unattached link buffers what it is handed
/// instead of writing a socket, which is all this claim needs. Attaching one
/// would only add a reader thread for the teardown to race.
@MainActor
final class CompanionInputBridgeTests: XCTestCase {
    func testWritingThroughTheBridgeStampsTheSession() throws {
        let session = Session(title: "agent", agent: .terminal)
        let workspace = Workspace(name: "Sessions")
        let project = Project(workspaceID: workspace.id, name: "termio", path: "/code/termio",
                              branch: "main", sessions: [session])
        let defaults = UserDefaults(suiteName: "companion-input-\(UUID().uuidString)")
        let store = TermioStore(workspaces: [workspace], projects: [project],
                                settings: AppSettings(defaults: defaults ?? .standard))

        let link = TermiodSessionLink(
            sessionName: session.id.uuidString,
            specification: Termiod.CreateSpecification(
                cwd: NSTemporaryDirectory(), argv: [], env: [], rows: 24, cols: 80),
            rows: 24, cols: 80)

        // Never started, either of them: `write` touches neither the socket nor
        // the connection, and starting them would make this depend on machinery
        // the claim has nothing to do with.
        let connection = NWConnection(to: .hostPort(host: "127.0.0.1", port: 9), using: .tcp)
        let bridge = SessionBridge(link: link, connection: connection)
        bridge.onInput = { store.noteInput(for: session.id) }

        XCTAssertNil(store.inputClock.lastInput(for: session.id), "nothing typed yet")
        bridge.write(Data("hello".utf8))

        XCTAssertNotNil(
            store.inputClock.lastInput(for: session.id),
            "a keystroke crossed the bridge without stamping the session")
    }
}
