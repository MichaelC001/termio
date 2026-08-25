import XCTest
import TermioShared
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
        XCTAssertEqual(
            SSHAgentConfigStore.quote("~/.local/share/opencode/storage"),
            "\"${XDG_DATA_HOME:-$HOME/.local/share}\"/'opencode/storage'")
        // Everything outside the XDG bases is untouched: Pi and Claude Code keep
        // their own dot-directories, which no spec relocates.
        XCTAssertEqual(
            SSHAgentConfigStore.quote("~/.pi/agent/extensions"),
            "\"$HOME\"/'.pi/agent/extensions'")
        // `.configurable` is not `.config`, and a prefix match that ignored the
        // boundary would rewrite it.
        XCTAssertEqual(
            SSHAgentConfigStore.quote("~/.configurable/x"), "\"$HOME\"/'.configurable/x'")
    }

    /// The local half of the same rule the remote store spells in shell. Both
    /// variables are unset on a default macOS account, so this is also the
    /// assertion that the common path did not move.
    func testTheLocalStoreExpandsTheSameBasesTheRemoteOneDoes() {
        let home = NSHomeDirectory()
        XCTAssertEqual(
            XDGBaseDirectories.expand("~/.config/opencode/plugin"),
            ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { $0 + "/opencode/plugin" }
                ?? home + "/.config/opencode/plugin")
        XCTAssertEqual(XDGBaseDirectories.expand("~/.pi/agent"), home + "/.pi/agent")
        XCTAssertEqual(XDGBaseDirectories.expand("/etc/x"), "/etc/x")
        // A boundary, not a prefix: `.configurable` is not `.config`.
        XCTAssertEqual(XDGBaseDirectories.expand("~/.configurable"), home + "/.configurable")
    }

    /// A merge is computed from bytes that were read a network round trip ago.
    /// Committing it unconditionally is what silently discards the edit somebody
    /// made in between — so a stale commit must be refused, not merged over.
    func testAMergeAgainstStaleBytesIsRefused() {
        let store = RecordingConfigStore()
        let path = "~/.claude/settings.json"
        store.write(Data("{\"a\":1}".utf8), to: path, executable: false)
        let read = store.read(path)
        store.write(Data("{\"a\":2}".utf8), to: path, executable: false)

        XCTAssertFalse(store.write(Data("{\"merged\":1}".utf8), to: path, ifUnchangedFrom: read))
        XCTAssertEqual(store.read(path), Data("{\"a\":2}".utf8), "the newer bytes must survive")
        XCTAssertTrue(
            store.write(Data("{\"merged\":1}".utf8), to: path,
                        ifUnchangedFrom: Data("{\"a\":2}".utf8)))
    }

    /// `nil` means "must still be absent", so two installs racing to create the
    /// same config cannot both win.
    func testCreatingAConfigRequiresItToStillBeAbsent() {
        let store = RecordingConfigStore()
        let path = "~/.codex/hooks.json"
        XCTAssertTrue(store.write(Data("{}".utf8), to: path, ifUnchangedFrom: nil))
        XCTAssertFalse(store.write(Data("{\"b\":1}".utf8), to: path, ifUnchangedFrom: nil))
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
