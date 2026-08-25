import XCTest
import TermioShared
@testable import termio

/// The files client against a real daemon, end to end.
///
/// Opt-in on the same terms as `TermiodTransferIntegrationTests`: point
/// `TERMIO_TERMIOD_TEST_BIN` at a built `termiod` and it runs, otherwise it
/// skips, so `swift test` never grows a cargo dependency. It is a real daemon
/// rather than a stub because the half worth pinning is *this client's* — the
/// `files` capability gate, the `fs_listed` shape, the `F` chunk header, and the
/// confinement refusal that stops a tree walking out of its root.
final class TermiodFilesIntegrationTests: XCTestCase {
    private var binary = ""
    private var daemon: Process?
    private var socketDirectory: URL?
    private var root = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        try super.setUpWithError()
        let configured = ProcessInfo.processInfo.environment["TERMIO_TERMIOD_TEST_BIN"] ?? ""
        try XCTSkipIf(configured.isEmpty, "set TERMIO_TERMIOD_TEST_BIN to run this")
        binary = configured

        // Short socket directory name: `sun_path` is capped at 104 bytes and the
        // per-user temp directory already spends half of it.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tfx-\(UUID().uuidString.prefix(8))")
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

        // A tree with one of everything the pane draws: a file, a directory, a
        // nested file, and the VCS directory the host stubs rather than walks.
        root = directory.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("hello\n".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data(nestedContents.utf8).write(
            to: root.appendingPathComponent("sub/b.txt"))
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

    private let nestedContents = String(repeating: "nested line\n", count: 400)

    func testTheRootListsAsTheTreeWouldDrawIt() throws {
        let listings = try Termiod.listDirectories(
            route: .local, root: root.path, paths: [root.path])
        XCTAssertEqual(listings.count, 1)
        let listing = try XCTUnwrap(listings.first)
        XCTAssertNil(listing.error)
        XCTAssertEqual(listing.path, root.path, "the reply echoes the path asked for")

        let byName = Dictionary(uniqueKeysWithValues: listing.entries.map { ($0.name, $0) })
        XCTAssertEqual(byName["a.txt"]?.kind, .file)
        XCTAssertEqual(byName["sub"]?.kind, .directory)
        // `.git` comes back as `unloaded_dir` and must still read as a directory,
        // because the tree's own ignore list — not the wire — is what hides it.
        XCTAssertEqual(byName[".git"]?.kind, .directory)
        XCTAssertFalse(listing.entries.sortedForTree().contains { $0.name == ".git" })
    }

    func testASubdirectoryListsUnderTheSameRoot() throws {
        let listings = try Termiod.listDirectories(
            route: .local, root: root.path,
            paths: [root.appendingPathComponent("sub").path])
        let listing = try XCTUnwrap(listings.first)
        XCTAssertNil(listing.error)
        XCTAssertEqual(listing.entries.map(\.name), ["b.txt"])
    }

    /// The confinement the pane depends on: a tree rooted at a checkout must not
    /// be able to list its parent, and the failure is per-path rather than an
    /// error that blanks the pane.
    func testAPathOutsideTheRootIsRefusedOnItsOwn() throws {
        let outside = root.deletingLastPathComponent().path
        let listings = try Termiod.listDirectories(
            route: .local, root: root.path, paths: [root.path, outside])
        XCTAssertEqual(listings.count, 2)
        XCTAssertNil(listings[0].error, "the confined path still answers")
        XCTAssertNotNil(listings[1].error, "the escape is refused")
    }

    func testAFileComesBackByteForByte() throws {
        let data = try Termiod.readFile(
            route: .local, path: root.appendingPathComponent("a.txt").path)
        XCTAssertEqual(data, Data("hello\n".utf8))
    }

    /// Several `F` frames' worth, so the chunk loop is genuinely exercised rather
    /// than short-circuited by a payload that fits in one frame.
    func testAMultiChunkFileReassembles() throws {
        let data = try Termiod.readFile(
            route: .local, path: root.appendingPathComponent("sub/b.txt").path)
        XCTAssertEqual(data, Data(nestedContents.utf8))
    }

    /// A preview that would be a prefix is refused, so the pane says the file is
    /// too big instead of rendering half of it.
    func testAFileOverTheCallersLimitIsRefusedRatherThanTruncated() throws {
        XCTAssertThrowsError(try Termiod.readFile(
            route: .local, path: root.appendingPathComponent("sub/b.txt").path,
            limit: 16)) { error in
            XCTAssertEqual(error as? DeviceFileError, .tooLarge)
        }
    }

    /// The daemon's own message reaches the caller instead of a hang, for the
    /// path that is not there at all.
    func testAMissingFileFailsWithTheDaemonsReason() {
        XCTAssertThrowsError(try Termiod.readFile(
            route: .local, path: root.appendingPathComponent("nope.txt").path))
    }
}
