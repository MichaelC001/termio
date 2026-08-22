import XCTest
@testable import termio

/// Two attachments on one session, against a real daemon.
///
/// The daemon hands the write token to whoever attached last, which is right
/// for a single client and wrong the moment a second device looks at the same
/// session: a phone opening a session would mute the Mac until it detached,
/// and the Mac had no way to answer short of tearing its attachment down.
/// `claim_writer` is what lets the token follow the device being *used*, and
/// this is the only test that exercises both halves of that against a real
/// daemon rather than against fixtures.
///
/// Opt-in on the same terms as the other daemon suites: set
/// `TERMIO_TERMIOD_TEST_BIN` to run it.
final class TermiodWriteTokenIntegrationTests: XCTestCase {
    private var binary = ""
    private var daemon: Process?
    private var socketDirectory: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let configured = ProcessInfo.processInfo.environment["TERMIO_TERMIOD_TEST_BIN"] ?? ""
        try XCTSkipIf(configured.isEmpty, "set TERMIO_TERMIOD_TEST_BIN to run this")
        binary = configured

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wtk-\(UUID().uuidString.prefix(8))")
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

    private func link(_ name: String) -> TermiodSessionLink {
        TermiodSessionLink(
            sessionName: name,
            specification: Termiod.CreateSpecification(
                cwd: NSTemporaryDirectory(),
                argv: ["/bin/cat"],
                env: [], rows: 24, cols: 80),
            rows: 24, cols: 80)
    }

    /// Waits for a link's writer state to reach `expected`, so the assertions
    /// describe the settled outcome rather than racing the event that carries it.
    private func waitForWriter(
        _ holder: WriterWatcher, _ expected: Bool, _ what: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(5)
        while holder.isWriter != expected, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(holder.isWriter, expected, what, file: file, line: line)
    }

    /// `onWriter` fires on the main queue; the tests read it from there too.
    private final class WriterWatcher {
        var isWriter = false
    }

    func testTypingTakesTheWriteTokenBackFromTheDeviceThatAttachedLast() throws {
        let name = "write-token-\(UUID().uuidString.prefix(8))"

        let mac = link(name)
        let macWriter = WriterWatcher()
        mac.onWriter = { macWriter.isWriter = $0 }
        mac.start()
        defer { mac.detach() }
        waitForWriter(macWriter, true, "the first attachment holds the token")

        // A phone opens the same session. Attaching still takes the token —
        // that is what makes a fresh client usable without a round trip.
        let phone = link(name)
        let phoneWriter = WriterWatcher()
        phone.onWriter = { phoneWriter.isWriter = $0 }
        phone.start()
        defer { phone.detach() }
        waitForWriter(phoneWriter, true, "the newer attachment takes the token")
        waitForWriter(macWriter, false, "and the older one is told it lost it")

        // The Mac's user types. Before `claim_writer` this input was simply
        // refused by the daemon and the Mac stayed mute.
        mac.send(Data("echo\n".utf8))
        waitForWriter(macWriter, true, "typing on the Mac takes the token back")
        waitForWriter(phoneWriter, false, "and the phone is told it lost it")

        // And back again, so the token is genuinely mobile rather than
        // one-directional.
        phone.send(Data("echo\n".utf8))
        waitForWriter(phoneWriter, true, "typing on the phone takes it back")
        waitForWriter(macWriter, false, "the Mac yields in turn")
    }
}
