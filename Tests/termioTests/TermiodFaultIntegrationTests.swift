import XCTest
@testable import termio

/// What happens when the transport dies under a live session.
///
/// Every other daemon suite is a happy path: start, attach, work, tear down.
/// None of them kills the daemon, and that is the one failure mode with no
/// fallback left now that the in-process backend is gone — the daemon is the
/// only thing holding the PTY.
///
/// The distinction under test is that a broken pipe is not an exit. The child
/// is almost certainly still running, which is the entire point of it living in
/// a daemon; reporting an exit for it invents a status the process never
/// produced, and hands that invented status to the exit policy.
///
/// Opt-in on the same terms as the other daemon suites: set
/// `TERMIO_TERMIOD_TEST_BIN` to run these.
@MainActor
final class TermiodFaultIntegrationTests: XCTestCase {
    private var binary = ""
    private var daemon: Process?
    private var socketDirectory: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let configured = ProcessInfo.processInfo.environment["TERMIO_TERMIOD_TEST_BIN"] ?? ""
        try XCTSkipIf(configured.isEmpty, "set TERMIO_TERMIOD_TEST_BIN to run this")
        binary = configured

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flt-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketDirectory = directory
        let socket = directory.appendingPathComponent("termiod.sock").path
        XCTAssertLessThan(socket.utf8.count, 104, "socket path must fit sun_path")
        setenv("TERMIOD_SOCK", socket, 1)
        try startDaemon(socket: socket)
    }

    private func startDaemon(socket: String) throws {
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

    private func link(_ name: String, argv: [String]) -> TermiodSessionLink {
        TermiodSessionLink(
            sessionName: name,
            specification: Termiod.CreateSpecification(
                cwd: NSTemporaryDirectory(), argv: argv, env: [], rows: 24, cols: 80),
            rows: 24, cols: 80)
    }

    private func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    /// Killing the daemon under an attached session must not look like the
    /// session exiting. Before the split this delivered `exit 1` — a status the
    /// child never produced, which then went to the exit policy and parked the
    /// pane over an error with no error output behind it.
    func testKillingTheDaemonIsNotReportedAsAnExit() throws {
        var exits: [Int32] = []
        var lostConnection = false

        let session = link("fault-\(UUID().uuidString.prefix(8))",
                           argv: ["/bin/sh", "-c", "while :; do sleep 3600; done"])
        session.onExit = { code, _, _ in exits.append(code) }
        session.onConnectionLost = { lostConnection = true }
        session.start()
        defer { session.detach() }

        XCTAssertTrue(
            waitUntil(5) { session.latestInformation != nil || lostConnection },
            "the fixture never attached")

        // SIGKILL, not `terminate()`. A SIGTERM is caught and the daemon drains:
        // it kills each session and reports the real `session_exited` (status
        // 137) before closing the socket, which is correct and is *not* the
        // case under test. A transport failure is the daemon never getting to
        // say anything — the client sees EOF and nothing else, exactly as a cut
        // network or a broken SSH pipe looks.
        if let pid = daemon?.processIdentifier { kill(pid, SIGKILL) }
        daemon?.waitUntilExit()
        daemon = nil

        XCTAssertTrue(waitUntil(5) { lostConnection }, "the dead transport was never reported")
        XCTAssertTrue(
            exits.isEmpty,
            "a broken transport was reported as the session exiting with \(exits)")
    }

    /// The other direction, so the split does not simply mute exits: a session
    /// that genuinely ends still reports its own status, and does not also
    /// arrive as a disconnection when its stream closes behind it.
    func testAGenuineExitIsStillAnExit() throws {
        var exits: [Int32] = []
        var lostConnection = false

        let session = link("exit-\(UUID().uuidString.prefix(8))",
                           argv: ["/bin/sh", "-c", "exit 7"])
        session.onExit = { code, _, _ in exits.append(code) }
        session.onConnectionLost = { lostConnection = true }
        session.start()
        defer { session.detach() }

        XCTAssertTrue(waitUntil(10) { !exits.isEmpty }, "the exit never arrived")
        XCTAssertEqual(exits, [7], "the child's own status, once")

        // The daemon closes the stream right after the exit; that EOF must not
        // be re-reported as a lost connection.
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertFalse(lostConnection, "an ordinary exit was also reported as a disconnection")
    }

    /// Attaching to a daemon that is not there must not invent an exit either.
    ///
    /// This is the arm that made the first version of this fix circular: the
    /// connection-lost handler retired the cached surface, `TerminalPane`'s body
    /// calls `surface(for:)` so the *next render* rebuilt it — not the next
    /// deliberate selection — and `start()` failing against the still-dead
    /// transport delivered the same fabricated `exit 1` through its own catch.
    /// Reaching the daemon and losing it are one class of event, and neither
    /// carries a status.
    func testAttachingWithNoDaemonIsNotReportedAsAnExit() throws {
        // Point the client at a socket path nothing is listening on, which is
        // what a rebuild over a broken transport actually meets.
        let dead = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gone-\(UUID().uuidString.prefix(8)).sock").path
        setenv("TERMIOD_SOCK", dead, 1)
        defer { setenv("TERMIOD_SOCK", socketDirectory?.appendingPathComponent("termiod.sock").path ?? "", 1) }

        var exits: [Int32] = []
        var lostConnection = false
        let session = link("norun-\(UUID().uuidString.prefix(8))", argv: ["/bin/sh"])
        session.onExit = { code, _, _ in exits.append(code) }
        session.onConnectionLost = { lostConnection = true }
        session.start()
        defer { session.detach() }

        XCTAssertTrue(waitUntil(10) { lostConnection || !exits.isEmpty }, "nothing was reported")
        XCTAssertTrue(
            exits.isEmpty,
            "an unreachable daemon was reported as the session exiting with \(exits)")
        XCTAssertTrue(lostConnection, "an unreachable daemon was never reported at all")
    }

    /// The session outlives the connection, which is the claim the split rests
    /// on: after the daemon comes back, the same name resolves to the same
    /// still-running process rather than spawning a replacement.
    func testTheSessionSurvivesTheConnectionAndIsReattachable() throws {
        let name = "survive-\(UUID().uuidString.prefix(8))"
        let first = link(name, argv: ["/bin/sh", "-c", "while :; do sleep 3600; done"])
        var lostConnection = false
        first.onConnectionLost = { lostConnection = true }
        first.start()
        XCTAssertTrue(waitUntil(5) { first.latestInformation != nil }, "never attached")
        let originalPid = first.latestInformation?.pid
        XCTAssertNotNil(originalPid)

        // Sever the client's socket without stopping the daemon: the process
        // keeps running and the name stays resolvable.
        first.detach()
        XCTAssertFalse(lostConnection, "a deliberate detach is not a lost connection")

        let second = link(name, argv: [])
        second.start()
        defer { second.killAndClose() }
        XCTAssertTrue(waitUntil(5) { second.latestInformation != nil }, "never reattached")
        XCTAssertEqual(
            second.latestInformation?.pid, originalPid,
            "reattaching spawned a replacement instead of resolving the surviving session")
    }
}
