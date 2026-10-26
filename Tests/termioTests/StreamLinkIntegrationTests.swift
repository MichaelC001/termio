import XCTest
import TermioShared
@testable import termio

/// A link on the `vt_stream` plane against a real daemon: the native snapshot
/// becomes the client terminal, bytes reach it, and a viewport change comes
/// back as a `vt_resize` that resizes it — no keyframe, no surface.
///
/// Opt-in on the same terms as the other daemon suites: set
/// `TERMIO_TERMIOD_TEST_BIN` to a termiod built with `vt_stream`.
final class StreamLinkIntegrationTests: XCTestCase {
    private var daemon: Process?
    private var socketDirectory: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let binary = ProcessInfo.processInfo.environment["TERMIO_TERMIOD_TEST_BIN"] ?? ""
        try XCTSkipIf(binary.isEmpty, "set TERMIO_TERMIOD_TEST_BIN to run this")
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stream-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketDirectory = directory
        let socket = directory.appendingPathComponent("termiod.sock").path
        XCTAssertLessThan(socket.utf8.count, 104, "socket path must fit sun_path")
        setenv("TERMIOD_SOCK", socket, 1)
        let serve = Process()
        serve.executableURL = URL(fileURLWithPath: binary)
        serve.arguments = ["serve"]
        serve.environment = ProcessInfo.processInfo.environment.merging(
            ["TERMIOD_SOCK": socket, "TERMIOD_KEEP_AWAKE": "off"]) { _, new in new }
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

    private func wait(_ what: String, file: StaticString = #filePath, line: UInt = #line,
                      until condition: () throws -> Bool) rethrows {
        let deadline = Date().addingTimeInterval(10)
        while try !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(try condition(), what, file: file, line: line)
    }

    private func text(_ link: TermiodSessionLink) throws -> String {
        guard let screen = try link.streamTerminal?.screen() else { return "" }
        return String(decoding: screen.vt, as: UTF8.self)
    }

    func testAStreamLinkFollowsTheSessionThroughAResize() throws {
        let link = TermiodSessionLink(
            sessionName: "stream-\(UUID().uuidString.prefix(8))",
            specification: Termiod.CreateSpecification(
                cwd: NSTemporaryDirectory(),
                argv: ["/bin/sh", "-c", "printf 'hello stream\\n'; exec /bin/cat"],
                env: [], rows: 20, cols: 60),
            rows: 20, cols: 60, offersStream: true)
        var streaming: [Bool] = []
        link.onStreaming = { streaming.append($0) }
        link.start()
        defer { link.detach() }

        wait("the link negotiated vt_stream") { link.isStreaming && link.streamTerminal != nil }
        XCTAssertEqual(streaming, [true])
        try wait("the shell's output reached the client terminal") {
            try text(link).contains("hello stream")
        }
        let first = try XCTUnwrap(link.streamTerminal)

        link.setViewport(rows: 12, cols: 50)
        try wait("the vt_resize marker resized the client terminal") {
            let screen = try link.streamTerminal?.screen()
            return screen?.rows == 12 && screen?.cols == 50
        }
        XCTAssertTrue(link.streamTerminal === first, "a resize keeps the terminal; only an attach replaces it")

        link.send(Data("typed after\n".utf8))
        try wait("input echoed back through the stream") { try text(link).contains("typed after") }
    }

    /// A key reaches the program in the form its modes ask for: the program
    /// turned on application cursor keys after the attach, termiod encoded the
    /// key event against its own VT, and `cat -v` shows the bytes that arrived.
    func testAKeyIsEncodedWithTheModesTheProgramSetAfterTheAttach() throws {
        let link = TermiodSessionLink(
            sessionName: "keys-\(UUID().uuidString.prefix(8))",
            specification: Termiod.CreateSpecification(
                cwd: NSTemporaryDirectory(),
                argv: ["/bin/sh", "-c", "stty -echo; printf 'ready\\033[?1h\\n'; exec /bin/cat -v"],
                env: [], rows: 20, cols: 60),
            rows: 20, cols: 60, offersStream: true)
        link.start()
        defer { link.detach() }
        try wait("the program set its modes") { try text(link).contains("ready") }
        let press = try XCTUnwrap(SessionKeyPress.parse("up"))
        for input in TermiodStreamKeyboard.inputs(for: press) + TermiodStreamKeyboard.inputs(for: .return) {
            link.sendInput(.key(input))
        }
        try wait("cat -v echoed the application-mode arrow") { try text(link).contains("^[OA") }
    }

    /// A start the daemon refuses never takes the pane to the stream view:
    /// the refusal is shown where the embedded surface shows it.
    func testARefusedStartNeverStreams() throws {
        let link = TermiodSessionLink(
            sessionName: "refused-\(UUID().uuidString.prefix(8))",
            specification: Termiod.CreateSpecification(
                cwd: "/nonexistent-\(UUID().uuidString)", argv: ["/bin/cat"], env: [], rows: 20, cols: 60),
            rows: 20, cols: 60, offersStream: true)
        var refusal: String?
        var streaming: [Bool] = []
        link.onStartRefused = { refusal = $0 }
        link.onStreaming = { streaming.append($0) }
        link.start()
        defer { link.detach() }
        wait("the daemon refused the missing directory") { refusal != nil }
        XCTAssertEqual(streaming, [], "the stream view was never selected")
        XCTAssertFalse(link.isStreaming)
    }

    /// Without the capability the link stays on keyframes and has no terminal.
    /// With `vt_answers`, termiod answers the program and the pane stays
    /// silent, so each query is answered once, with the name the pane gave.
    func testTheHostAnswersOnceForAStreamPaneThatWrites() throws {
        let file = NSTemporaryDirectory() + "answers-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: file) }
        // Waits for one key, so the pane writes before anything is asked;
        // then collects whatever answers arrive within two quiet seconds.
        let script = "stty raw -echo; dd bs=1 count=1 of=/dev/null 2>/dev/null; "
            + "printf '\\033[>q\\033[c'; stty min 0 time 20; cat > \(file); exec cat"
        let link = TermiodSessionLink(
            sessionName: "answers-\(UUID().uuidString.prefix(8))",
            specification: Termiod.CreateSpecification(
                cwd: NSTemporaryDirectory(), argv: ["/bin/sh", "-c", script], env: [], rows: 20, cols: 60),
            rows: 20, cols: 60, offersStream: true)
        link.setHostAnswers(Termiod.HostAnswers(
            xtversion: "ghostty test-name", foreground: "dddddd", background: "111111", cursor: nil,
            palette: [], dark: true))
        link.start()
        defer { link.detach() }

        wait("the link negotiated vt_stream") { link.isStreaming && link.streamTerminal != nil }
        link.send(Data("x".utf8))
        wait("the program collected its answers") {
            ((try? String(contentsOfFile: file, encoding: .utf8)) ?? "").contains("c")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        let answers = try String(contentsOfFile: file, encoding: .utf8)
        XCTAssertEqual(answers, "\u{1b}P>|ghostty test-name\u{1b}\\\u{1b}[?62;22;52c")
    }

    func testALinkThatDoesNotOfferTheStreamStaysOnKeyframes() throws {
        let link = TermiodSessionLink(
            sessionName: "keyframe-\(UUID().uuidString.prefix(8))",
            specification: Termiod.CreateSpecification(
                cwd: NSTemporaryDirectory(), argv: ["/bin/cat"], env: [], rows: 20, cols: 60),
            rows: 20, cols: 60)
        // Delivered on the reader thread.
        let lock = NSLock()
        var received = false
        link.onOutput = { _ in lock.withLock { received = true } }
        link.start()
        defer { link.detach() }
        wait("the keyframe plane delivered the attach repaint") { lock.withLock { received } }
        XCTAssertFalse(link.isStreaming)
        XCTAssertNil(link.streamTerminal)
    }
}
