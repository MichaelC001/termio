import XCTest
@testable import termio

/// Records what an install wrote instead of touching a machine, so the generated
/// hook for a device can be asserted without a VPS in the loop.
private final class RecordingConfigStore: AgentConfigStore, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]

    func resolve(_ path: String) -> String { path }

    func exists(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return files[path] != nil
    }

    func read(_ path: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return files[path]
    }

    @discardableResult
    func write(_ data: Data, to path: String, executable: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        files[path] = data
        return true
    }

    @discardableResult
    func remove(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        files.removeValue(forKey: path)
        return true
    }

    func listDirectory(_ path: String) -> [String]? { nil }

    /// Every agent is present, so the install is judged on what it generates
    /// rather than on which CLIs this test machine happens to carry.
    func isCommandInstalled(_ command: String) -> Bool { true }

    /// The text written to the one path ending in `suffix`.
    func text(endingIn suffix: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return files.first { $0.key.hasSuffix(suffix) }
            .flatMap { String(data: $0.value, encoding: .utf8) }
    }

    var allText: [String] {
        lock.lock(); defer { lock.unlock() }
        return files.values.compactMap { String(data: $0, encoding: .utf8) }
    }
}

/// The device arm of the hook installers. A hook that names a path the device
/// does not have fails on every agent turn and is silent about it — the form ends
/// in `2>/dev/null || true` — so what these emit is asserted, not eyeballed.
final class DeviceHookInstallTests: XCTestCase {
    private func install() -> RecordingConfigStore {
        let store = RecordingConfigStore()
        AgentStatusHooks.sync(
            enabled: true,
            target: AgentIntegrationTarget(store: store, reporter: .termiodDaemon))
        return store
    }

    /// `Termiod.remoteBinary()` is a shell *expression*, not a path: quoting it
    /// whole emits a literal `$HOME` directory that cannot exist, and every
    /// device hook then execs something that is not there.
    func testTheDeviceCommandKeepsItsHomeExpandable() {
        let command = AgentStatusHooks.reportCommand(state: "working", reporter: .termiodDaemon)
        XCTAssertFalse(
            command.contains("'$HOME"), "a single-quoted $HOME reaches the kernel literally")
        XCTAssertTrue(command.contains("\"$HOME\"/"))
    }

    /// `~/.config` is the default value of `XDG_CONFIG_HOME`, and the agents that
    /// live there — OpenCode, Amp — read the variable. A device whose owner moved
    /// their config would otherwise take the plugin into a directory the agent
    /// never reads.
    func testConfigPathsFollowXDGOnTheDevice() {
        XCTAssertEqual(
            SSHAgentConfigStore.quote("~/.config/opencode/plugin"),
            "\"${XDG_CONFIG_HOME:-$HOME/.config}\"/'opencode/plugin'")
        XCTAssertEqual(
            SSHAgentConfigStore.quote("~/.config"), "\"${XDG_CONFIG_HOME:-$HOME/.config}\"")
        // Everything outside `~/.config` is untouched: Pi and Claude Code keep
        // their own dot-directories, which no spec relocates.
        XCTAssertEqual(
            SSHAgentConfigStore.quote("~/.pi/agent/extensions"),
            "\"$HOME\"/'.pi/agent/extensions'")
    }

    /// The three plugin dialects used to decline on a device outright.
    func testThePluginDialectsInstallOnADevice() {
        let store = install()
        for suffix in ["opencode/plugin/termio.js", "amp/plugins/termio.ts",
                       ".pi/agent/extensions/termio.js"] {
            XCTAssertNotNil(store.text(endingIn: suffix), "\(suffix) was not installed")
        }
    }

    /// A device has no `termio` binary and no app socket to report into, so no
    /// generated hook may reach for either — in any dialect.
    func testNoDeviceHookReachesForTheLocalContract() {
        for source in install().allText {
            XCTAssertFalse(source.contains("agent report"), source)
            XCTAssertFalse(source.contains("TERMIO_SESSION"), source)
            XCTAssertFalse(source.contains("--conversation"), source)
        }
    }

    /// Bun escapes each `$` interpolation into one argv token, so a `$HOME` handed
    /// to it survives as literal text the same way an over-quoted shell path does.
    /// The join has to happen in JavaScript.
    func testGeneratedPluginsJoinTheirBinaryInJavaScript() {
        let store = install()
        for suffix in ["opencode/plugin/termio.js", "amp/plugins/termio.ts"] {
            guard let source = store.text(endingIn: suffix) else {
                return XCTFail("\(suffix) was not installed")
            }
            XCTAssertTrue(source.contains("process.env.HOME"), source)
            XCTAssertTrue(source.contains("set-status"), source)
            XCTAssertTrue(source.contains("process.env.TERMIOD_SESSION_ID"), source)
            // Reporting with an empty id is a call the daemon rejects; a plugin
            // loaded outside a termiod session stays silent instead.
            XCTAssertTrue(source.contains("if (!session) return;"), source)
        }
    }

    /// Pi shells out through `pi.exec("sh", …)`, so its device form is the very
    /// string the JSON-manifest dialects get — no second spelling to drift.
    func testPiCarriesTheSameDaemonCommandAsTheShellDialects() {
        guard let source = install().text(endingIn: ".pi/agent/extensions/termio.js") else {
            return XCTFail("the Pi extension was not installed")
        }
        XCTAssertTrue(source.contains("$TERMIOD_SESSION_ID"), source)
        XCTAssertTrue(source.contains("set-status"), source)
    }

    /// Ownership is what lets uninstall remove our file and refuse a user's. The
    /// device form drops `agent report`, so it must still carry the socket marker.
    func testDevicePluginsStayRecognizablyOurs() {
        for source in install().allText {
            XCTAssertTrue(
                source.contains(AgentStatusHooks.marker)
                    || source.contains(AgentStatusHooks.hookVersionMarker),
                source)
        }
    }
}
