import XCTest
import TermioShared
@testable import termio

/// `Termiod.developmentDaemonCandidates` — the checkout half of daemon
/// resolution. The bundle half cannot be tested from `swift test` (the test
/// process has no `.app`, which is exactly the case the checkout half exists
/// for), so what is pinned here is the fallback that must keep a developer
/// working and, above all, that resolution is anchored at the running binary
/// rather than at the working directory: a Finder-launched app has cwd `/`, and
/// the previous fallback resolved `/termiod/target/debug/termiod` there — the
/// reason no released build could start a daemon.
final class TermiodDaemonBinaryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("termiod-resolution-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func makeCheckout(at directory: URL) throws {
        let daemon = directory.appendingPathComponent("termiod")
        try FileManager.default.createDirectory(at: daemon, withIntermediateDirectories: true)
        try Data("[package]\nname = \"termiod\"\n".utf8)
            .write(to: daemon.appendingPathComponent("Cargo.toml"))
    }

    /// The `.build/<triple>/debug/termio` case: a bare SwiftPM binary sitting
    /// three levels below the checkout it was built in.
    func testFindsTheCheckoutAboveASwiftPMBinary() throws {
        try makeCheckout(at: root)
        let binaryDirectory = root.appendingPathComponent(".build/arm64-apple-macosx/debug")
        try FileManager.default.createDirectory(at: binaryDirectory, withIntermediateDirectories: true)

        let candidates = Termiod.developmentDaemonCandidates(near: binaryDirectory)

        XCTAssertEqual(candidates, [
            root.appendingPathComponent("termiod/target/release/termiod").path,
            root.appendingPathComponent("termiod/target/debug/termiod").path,
        ], "release before debug, both anchored at the checkout, not at the cwd")
    }

    /// The `.app`-assembled-at-the-repo-root case: `Contents/MacOS` is two
    /// levels down, and the daemon in the checkout is the right answer when the
    /// bundle carries none (a dev build made without a Rust toolchain).
    func testFindsTheCheckoutAboveAnAppBundle() throws {
        try makeCheckout(at: root)
        let binaryDirectory = root.appendingPathComponent("termio-dev.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: binaryDirectory, withIntermediateDirectories: true)

        XCTAssertEqual(Termiod.developmentDaemonCandidates(near: binaryDirectory).first,
                       root.appendingPathComponent("termiod/target/release/termiod").path)
    }

    /// The shipped case: an app in /Applications has no checkout above it, and
    /// answering with a path anyway is what produced `/termiod/target/debug/termiod`.
    func testAnswersNothingWithNoCheckoutAbove() throws {
        let binaryDirectory = root.appendingPathComponent("Applications/termio.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: binaryDirectory, withIntermediateDirectories: true)

        XCTAssertEqual(Termiod.developmentDaemonCandidates(near: binaryDirectory), [])
    }

    /// The walk stops rather than running to `/`: a `termiod/Cargo.toml` far
    /// enough above the binary is somebody else's checkout, not this build's.
    func testStopsWalkingBeforeTheFilesystemRoot() throws {
        try makeCheckout(at: root)
        let deep = root.appendingPathComponent("a/b/c/d/e/f/g/h/i")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)

        XCTAssertEqual(Termiod.developmentDaemonCandidates(near: deep), [])
    }

    /// The development override outranks everything, including a bundled daemon
    /// — it is what a developer sets to run a build they just made.
    func testEnvironmentOverrideWins() throws {
        let override = root.appendingPathComponent("my-termiod").path
        setenv("TERMIO_TERMIOD_BIN", override, 1)
        defer { unsetenv("TERMIO_TERMIOD_BIN") }

        XCTAssertEqual(Termiod.daemonBinaryPath(), override)
    }

    // MARK: - Channel scoping

    /// The dev build and the release app must not land on one socket. The socket
    /// is the rendezvous for a whole session table — in Rust `state_dir()` is the
    /// socket's own directory, so `host.id` and the roster hang off it too — and
    /// sharing it makes the two channels **one device**: each is handed the
    /// other's sessions to draw under Also Running, and each can kill them.
    func testTheDevChannelDerivesItsOwnSocket() {
        let environment = ["TMPDIR": "/var/folders/xx/T/"]
        let release = Termiod.socketPath(channelSuffix: "", environment: environment)
        let dev = Termiod.socketPath(channelSuffix: "-dev", environment: environment)

        XCTAssertNotEqual(release, dev)
        XCTAssertTrue(dev.hasSuffix("-dev/termiod.sock"), dev)
        XCTAssertEqual(URL(fileURLWithPath: release).deletingLastPathComponent().path + "-dev",
                       URL(fileURLWithPath: dev).deletingLastPathComponent().path)
    }

    /// The release channel's suffix is empty, so its path is byte-identical to
    /// the one it had before channels were scoped. Anything else would strand
    /// every session running under a shipped termio the day this ships.
    func testTheReleaseChannelSocketIsUnchanged() {
        let path = Termiod.socketPath(channelSuffix: "",
                                      environment: ["TMPDIR": "/var/folders/xx/T"])

        XCTAssertEqual(path, "/var/folders/xx/T/termiod-\(getuid())/termiod.sock")
    }

    /// `TERMIOD_SOCK` still outranks the channel. It is how the tests and a
    /// deliberate side-by-side daemon isolate, and a channel must not quietly
    /// redirect a path the user pinned by hand.
    func testAPinnedSocketOutranksTheChannel() {
        let path = Termiod.socketPath(
            channelSuffix: "-dev",
            environment: ["TERMIOD_SOCK": "/tmp/pinned/termiod.sock", "TMPDIR": "/var/folders/xx/T"])

        XCTAssertEqual(path, "/tmp/pinned/termiod.sock")
    }

    /// `$XDG_RUNTIME_DIR` is the preferred base on the systems that set it, and
    /// it carries the channel too — otherwise the scoping holds on macOS and
    /// silently does not on a Linux box reached over SSH.
    func testTheRuntimeDirectoryBaseCarriesTheChannel() {
        let path = Termiod.socketPath(channelSuffix: "-dev",
                                      environment: ["XDG_RUNTIME_DIR": "/run/user/501"])

        XCTAssertEqual(path, "/run/user/501/termiod-dev/termiod.sock")
    }

    /// What the app hands the daemon as `TERMIO_CHANNEL`. The release channel is
    /// named rather than left empty: the daemon may be spawned from a process
    /// that already has the variable set, and an unset key would let that value
    /// through to redirect it.
    func testTheReleaseChannelIsNamedNotOmitted() {
        XCTAssertFalse(Termiod.channelName.isEmpty)
    }
}
