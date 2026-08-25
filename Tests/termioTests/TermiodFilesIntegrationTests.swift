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
    private var socketPath = ""
    private var root = URL(fileURLWithPath: "/")

    /// Starts a daemon on this test's socket and waits for it to answer. Split
    /// out because one test kills it mid-flight to make sure a pooled channel
    /// that died between requests reconnects rather than failing the click.
    private func startDaemon() throws -> Process {
        // A killed daemon leaves its socket file behind, and a client that finds
        // one nobody is listening on would try to autostart a daemon from the
        // bundle rather than use this test's binary. Wait for *this* daemon's
        // socket, not for a corpse.
        try? FileManager.default.removeItem(atPath: socketPath)
        let serve = Process()
        serve.executableURL = URL(fileURLWithPath: binary)
        serve.arguments = ["serve"]
        serve.environment = ProcessInfo.processInfo.environment.merging(
            ["TERMIOD_SOCK": socketPath]) { _, new in new }
        serve.standardOutput = FileHandle.nullDevice
        serve.standardError = FileHandle.nullDevice
        try serve.run()

        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: socketPath), Date() < deadline {
            usleep(50_000)
        }
        return serve
    }

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
        socketPath = socket
        daemon = try startDaemon()

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
        try Data("Widget lives here\n".utf8).write(
            to: root.appendingPathComponent("widget.txt"))
        // `fs.search` is `git grep`, so the workspace has to be a real checkout
        // for it to run at all. The `.git` directory above is what the listing
        // tests expect to see; this makes it a repository rather than a husk.
        try gitInit()
    }

    private func gitInit() throws {
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", root.path, "init", "--quiet"]
        git.standardOutput = FileHandle.nullDevice
        git.standardError = FileHandle.nullDevice
        try git.run()
        git.waitUntilExit()
    }

    override func tearDownWithError() throws {
        // The pool is process-wide and keyed by route, so a channel left open
        // here would be handed to the next test — pointed at a daemon this one
        // is about to kill.
        Termiod.ControlPool.closeAll()
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
        let file = try Termiod.readFile(
            route: .local, path: root.appendingPathComponent("a.txt").path)
        XCTAssertEqual(file.data, Data("hello\n".utf8))
    }

    /// Several `F` frames' worth, so the chunk loop is genuinely exercised rather
    /// than short-circuited by a payload that fits in one frame.
    func testAMultiChunkFileReassembles() throws {
        let file = try Termiod.readFile(
            route: .local, path: root.appendingPathComponent("sub/b.txt").path)
        XCTAssertEqual(file.data, Data(nestedContents.utf8))
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

    /// Save, end to end: the bytes cross, the version claimed is the one that was
    /// read, and the file on the device is the file that comes back.
    func testSavingAFileLandsOnTheDeviceAndReVersionsIt() throws {
        let path = root.appendingPathComponent("a.txt").path
        let read = try Termiod.readFile(route: .local, path: path)
        XCTAssertEqual(read.data, Data("hello\n".utf8))
        XCTAssertGreaterThan(read.mtime, 0, "the read carries the version it holds")

        let landed = try Termiod.writeFile(
            route: .local, root: root.path, path: path,
            data: Data("edited\n".utf8), ifUnmodifiedSince: read.mtime)

        XCTAssertGreaterThan(landed, 0, "the write answers with the version it made")
        let after = try Termiod.readFile(route: .local, path: path)
        XCTAssertEqual(after.data, Data("edited\n".utf8))
        XCTAssertEqual(after.mtime, landed, "the version the write reported is the file's")
    }

    /// The lost-update guard, over the wire: the agent in that checkout wrote
    /// first, so this save is refused rather than silently replacing its work.
    func testSavingIsRefusedWhenTheDeviceFileMovedOn() throws {
        let path = root.appendingPathComponent("a.txt").path
        let read = try Termiod.readFile(route: .local, path: path)

        // The other writer. The wait is the resolution of the timestamp itself.
        Thread.sleep(forTimeInterval: 1.1)
        try Data("theirs\n".utf8).write(to: URL(fileURLWithPath: path))

        XCTAssertThrowsError(try Termiod.writeFile(
            route: .local, root: root.path, path: path,
            data: Data("mine\n".utf8), ifUnmodifiedSince: read.mtime)
        ) { error in
            guard case DeviceFileError.conflict(let message) = error else {
                return XCTFail("expected a conflict, got \(error)")
            }
            XCTAssertTrue(message.contains("changed"), message)
        }
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: path)), Data("theirs\n".utf8),
            "the other writer's file is untouched")
    }

    /// Claiming nothing is how "overwrite anyway" travels, and it must land even
    /// though the file has moved on since it was read.
    func testAnUnversionedSaveOverwritesWhatIsThere() throws {
        let path = root.appendingPathComponent("a.txt").path
        Thread.sleep(forTimeInterval: 1.1)
        try Data("theirs\n".utf8).write(to: URL(fileURLWithPath: path))

        _ = try Termiod.writeFile(
            route: .local, root: root.path, path: path,
            data: Data("mine\n".utf8), ifUnmodifiedSince: nil)

        XCTAssertEqual(try Termiod.readFile(route: .local, path: path).data,
                       Data("mine\n".utf8))
    }

    /// A save may not walk out of the checkout it is rooted at — the same
    /// confinement the listing has, on the write side where it matters more.
    func testASaveOutsideTheRootIsRefused() throws {
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("escaped.txt").path
        XCTAssertThrowsError(try Termiod.writeFile(
            route: .local, root: root.path, path: outside,
            data: Data("nope\n".utf8), ifUnmodifiedSince: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside))
    }

    /// The Search pane's whole contract in one call: hits stream as events and
    /// the terminal reply closes them, paths come back relative to the searched
    /// root, and the line numbers are the ones the pane jumps to.
    func testSearchAnswersHitsWithRootRelativePaths() throws {
        let result = try Termiod.searchContents(
            route: .local, root: root.path, query: "Widget", limit: 400)

        XCTAssertFalse(result.limitHit)
        XCTAssertEqual(result.hits.map(\.path), ["widget.txt"])
        XCTAssertEqual(result.hits.first?.line, 1)
        XCTAssertEqual(result.hits.first?.text, "Widget lives here")
    }

    /// Smart case, matching what the local pane has always done: an all-lowercase
    /// query matches insensitively, and an uppercase letter opts into exactness.
    func testSearchIsSmartCase() throws {
        let loose = try Termiod.searchContents(
            route: .local, root: root.path, query: "widget", limit: 400)
        XCTAssertEqual(loose.hits.map(\.path), ["widget.txt"])

        let exact = try Termiod.searchContents(
            route: .local, root: root.path, query: "WIDGET", limit: 400)
        XCTAssertTrue(exact.hits.isEmpty, "an uppercase query means what it says")
    }

    /// The cap is what keeps a one-letter query in a monorepo from flooding the
    /// pane, and the pane says "more exist" only because the reply does.
    func testSearchStopsAtTheLimitAndSaysSo() throws {
        let result = try Termiod.searchContents(
            route: .local, root: root.path, query: "nested", limit: 5)

        XCTAssertTrue(result.limitHit)
        XCTAssertEqual(result.hits.count, 5)
        XCTAssertTrue(result.hits.allSatisfy { $0.path == "sub/b.txt" })
    }

    /// A query nothing matches is an answer, not a failure — `git grep` exits 1
    /// for it, and the pane must show "no matches" rather than an error.
    func testSearchWithNoHitsSucceedsEmpty() throws {
        let result = try Termiod.searchContents(
            route: .local, root: root.path, query: "nothing-here-at-all", limit: 400)
        XCTAssertTrue(result.hits.isEmpty)
        XCTAssertFalse(result.limitHit)
    }

    // MARK: - The pooled channel

    /// The premise of the whole pool: a second request reaches the device over
    /// the connection the first one opened. If this ever stops holding, nothing
    /// fails — every call still answers — the app just quietly goes back to an
    /// SSH handshake per folder expand.
    func testASecondRequestReusesTheFirstsConnection() throws {
        _ = try Termiod.listDirectories(route: .local, root: root.path, paths: [root.path])
        let first = try Termiod.ControlPool.channel(route: .local, caps: ["files"])
        _ = try Termiod.readFile(route: .local, path: root.appendingPathComponent("a.txt").path)
        let second = try Termiod.ControlPool.channel(route: .local, caps: ["files"])
        XCTAssertTrue(first === second, "the files plane must hold one channel per device")
    }

    /// A channel that negotiated one capability set must not answer for another:
    /// the daemon settles capabilities at the handshake, so handing a `files`
    /// channel a request it never negotiated would hang on a reply it will not
    /// send.
    func testChannelsAreKeyedByWhatTheyNegotiated() throws {
        let files = try Termiod.ControlPool.channel(route: .local, caps: ["files"])
        let other = try Termiod.ControlPool.channel(route: .local, caps: ["files", "git"])
        XCTAssertFalse(files === other)
    }

    /// Requests are demultiplexed by `re`, so several may be outstanding at once
    /// — the daemon `tokio::spawn`s each one and answers out of order. This is
    /// the claim that would fail loudest if the routing were wrong: with replies
    /// matched by arrival instead of by id, a listing would come back holding a
    /// file's bytes.
    func testConcurrentRequestsOnOneChannelGetTheirOwnAnswers() throws {
        let done = expectation(description: "all requests answered")
        done.expectedFulfillmentCount = 3
        let listed = UncheckedBox<[Termiod.DirectoryListing]>([])
        let read = UncheckedBox<Data>(Data())
        let found = UncheckedBox<Termiod.SearchResult?>(nil)
        let root = root

        // The search is much the slowest of the three, so it is issued first: if
        // anything serialised behind it, the other two would land after it
        // rather than while it runs.
        DispatchQueue.global().async {
            found.value = try? Termiod.searchContents(
                route: .local, root: root.path, query: "nested", limit: 400)
            done.fulfill()
        }
        DispatchQueue.global().async {
            listed.value = (try? Termiod.listDirectories(
                route: .local, root: root.path, paths: [root.path])) ?? []
            done.fulfill()
        }
        DispatchQueue.global().async {
            read.value = (try? Termiod.readFile(
                route: .local, path: root.appendingPathComponent("sub/b.txt").path))?.data ?? Data()
            done.fulfill()
        }
        wait(for: [done], timeout: 30)

        XCTAssertEqual(listed.value.first?.path, root.path)
        XCTAssertTrue(listed.value.first?.entries.contains { $0.name == "a.txt" } ?? false)
        XCTAssertEqual(read.value, Data(nestedContents.utf8), "the read got its own bytes")
        XCTAssertEqual(found.value?.hits.count, 400)
    }

    /// The cost of holding a connection: it can die between requests, and the
    /// first click after a laptop wakes must reconnect rather than show an error.
    /// Killing the daemon under a live pooled channel is exactly that.
    func testAChannelThatDiedBetweenRequestsReconnects() throws {
        _ = try Termiod.listDirectories(route: .local, root: root.path, paths: [root.path])

        daemon?.terminate()
        daemon?.waitUntilExit()
        daemon = nil
        // The client is not told; it finds out by writing into a dead pipe,
        // which is the case this has to survive without raising SIGPIPE.
        let restarted = try startDaemon()
        daemon = restarted

        let listings = try Termiod.listDirectories(
            route: .local, root: root.path, paths: [root.path])
        XCTAssertTrue(listings.first?.entries.contains { $0.name == "a.txt" } ?? false)
    }
}

/// A box for handing a result back from a detached queue in a test. The values
/// are read only after `wait(for:)` has returned, which is the barrier that
/// makes this safe; the compiler cannot see that.
private final class UncheckedBox<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}
