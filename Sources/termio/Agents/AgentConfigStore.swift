import Foundation

/// The files an agent integration is written into, on whichever machine the
/// agent will run on.
///
/// The hook installers and the skill installer used to call `FileManager`
/// directly, which silently meant *this Mac* — so an agent on a device got
/// neither, and its status could only ever come from the screen tap
/// (`TermioStore+Termiod.applyTermiodStatus`). This is the seam that makes the
/// machine an argument instead of an assumption.
///
/// Paths arrive **unexpanded** (`~/.claude/settings.json`) and are resolved by
/// the store, because `~` names the home directory of the machine the agent runs
/// on and `NSString.expandingTildeInPath` can only ever name this one.
protocol AgentConfigStore: Sendable {
    /// Absolute path for a manifest path, expanding a leading `~` against the
    /// target's home rather than this process's.
    func resolve(_ path: String) -> String

    /// Whether something exists at `path`. Kept separate from `read` so a caller
    /// can still tell "no file yet" from "a file we could not parse" — the
    /// distinction that stops an unreadable config being overwritten.
    func exists(_ path: String) -> Bool

    /// The file's bytes, or `nil` when it is absent or unreadable.
    func read(_ path: String) -> Data?

    /// Writes `data`, creating parent directories. `executable` marks the file
    /// 0755 for the script-directory dialect, whose hooks the agent execs.
    @discardableResult
    func write(_ data: Data, to path: String, executable: Bool) -> Bool

    @discardableResult
    func remove(_ path: String) -> Bool

    /// Entry names directly inside `path`, or `nil` when it cannot be listed.
    /// Names only: the sweeps join them back onto a directory they already hold.
    func listDirectory(_ path: String) -> [String]?

    /// Whether `command`'s binary can be run on this machine. A fact about the
    /// machine, which is why it belongs here rather than beside the local `PATH`
    /// probe: an agent installed on the Mac says nothing about the VPS, and the
    /// skill install already refuses to create a skills directory for a CLI that
    /// is not there.
    ///
    /// Both implementations answer `true` when they could not look, so a probe
    /// that fails never reads as "not installed" — the same don't-cry-wolf rule
    /// `AgentAvailability` follows locally.
    func isCommandInstalled(_ command: String) -> Bool
}

extension AgentConfigStore {
    /// Convenience for the many call sites that read UTF-8 text.
    func readText(_ path: String) -> String? {
        read(path).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Writes only when the bytes differ. Every installer wants this: a sync runs
    /// on each launch, the result is almost always identical, and rewriting a
    /// user-owned file needlessly widens the window in which an atomic write can
    /// clobber a concurrent hand-edit.
    @discardableResult
    func writeIfChanged(_ data: Data, to path: String, executable: Bool = false) -> Bool {
        if read(path) == data { return true }
        return write(data, to: path, executable: executable)
    }
}

/// This Mac. Behaviour is byte-for-byte what the installers did inline before
/// the store existed.
struct LocalAgentConfigStore: AgentConfigStore {
    func resolve(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: resolve(path))
    }

    func read(_ path: String) -> Data? {
        FileManager.default.contents(atPath: resolve(path))
    }

    @discardableResult
    func write(_ data: Data, to path: String, executable: Bool) -> Bool {
        let url = URL(fileURLWithPath: resolve(path))
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            if executable {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
            return true
        } catch {
            AgentStatusHooks.log("could not write \(url.path): \(error)")
            return false
        }
    }

    @discardableResult
    func remove(_ path: String) -> Bool {
        let resolved = resolve(path)
        guard FileManager.default.fileExists(atPath: resolved) else { return true }
        do {
            try FileManager.default.removeItem(atPath: resolved)
            return true
        } catch {
            AgentStatusHooks.log("could not remove \(resolved): \(error)")
            return false
        }
    }

    func listDirectory(_ path: String) -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: resolve(path))
    }

    func isCommandInstalled(_ command: String) -> Bool {
        AgentAvailability.isCommandInstalled(command)
    }
}

/// A device, reached the way everything else in termio reaches one: the user's
/// own `ssh`, with the multiplexing options `Termiod` already resolves for that
/// host, so each operation rides the existing ControlMaster instead of paying a
/// fresh TCP and key exchange.
///
/// This is the v0 arm described in `docs/design/20260824-agent-integration-on-a-device.md`
/// §D6: it works today and only from a Mac. The v1 arm moves the same operations
/// onto the session protocol's transfer plane, so a phone or a browser can
/// install too; the store is the seam that lets that land without touching a
/// single installer.
struct SSHAgentConfigStore: AgentConfigStore {
    let host: String

    /// A remote `~` is expanded by the remote shell, so the path is passed
    /// through and quoted for `sh` at the point of use. Returned unchanged so
    /// log lines name what the manifest declared.
    func resolve(_ path: String) -> String { path }

    func exists(_ path: String) -> Bool {
        run("test -e \(Self.quote(path))") != nil
    }

    func read(_ path: String) -> Data? {
        // base64 over the wire: a config file is arbitrary bytes and the shell
        // pipeline is not binary-safe. `-w0`/`-b0` spelling differs between GNU
        // and BSD, so fold nothing and strip newlines here instead.
        guard let output = run("base64 < \(Self.quote(path))") else { return nil }
        let joined = output.components(separatedBy: .whitespacesAndNewlines).joined()
        return Data(base64Encoded: joined)
    }

    @discardableResult
    func write(_ data: Data, to path: String, executable: Bool) -> Bool {
        let quoted = Self.quote(path)
        // Written to a sibling temp file and renamed, so a reader on the device
        // never sees a half-written config — the remote equivalent of the local
        // `.atomic` write, and the reason the directory is created first.
        let chmod = executable ? "chmod 755 \(quoted).termio-tmp && " : ""
        let script = """
            mkdir -p "$(dirname \(quoted))" \
            && base64 -d > \(quoted).termio-tmp \
            && \(chmod)mv \(quoted).termio-tmp \(quoted)
            """
        let encoded = data.base64EncodedString()
        guard run(script, stdin: encoded) != nil else {
            AgentStatusHooks.log("could not write \(host):\(path)")
            return false
        }
        return true
    }

    @discardableResult
    func remove(_ path: String) -> Bool {
        guard run("rm -rf \(Self.quote(path))") != nil else {
            AgentStatusHooks.log("could not remove \(host):\(path)")
            return false
        }
        return true
    }

    func listDirectory(_ path: String) -> [String]? {
        guard let output = run("ls -A \(Self.quote(path))") else { return nil }
        return output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    func isCommandInstalled(_ command: String) -> Bool {
        let binary = command.split(separator: " ").first.map(String.init) ?? ""
        guard !binary.isEmpty else { return true }
        // `command -v` is POSIX, unlike `which`, and is a shell builtin — so this
        // costs one multiplexed ssh channel and no remote process.
        //
        // A login shell is what resolves the user's `PATH`: an agent installed by
        // a version manager lives on a `PATH` that only `~/.profile` sets, and a
        // non-interactive ssh command does not read it. Answering `true` when the
        // probe itself fails keeps a broken link from reading as "not installed".
        guard let result = run(
            "command -v \(Self.quote(binary)) >/dev/null 2>&1 && echo yes || echo no")
        else { return true }
        return result.trimmingCharacters(in: .whitespacesAndNewlines) != "no"
    }

    /// Runs one `sh -c` on the device. `nil` means the command failed or `ssh`
    /// could not be run at all — the caller treats both as "the file is not in
    /// the state we wanted", never as "the file is absent", so a dropped link
    /// cannot be mistaken for a config that needs writing.
    private func run(_ script: String, stdin: String? = nil) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = Termiod.sshArguments(host: host) + [host, script]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let input = Pipe()
        process.standardInput = input
        do {
            try process.run()
        } catch {
            AgentStatusHooks.log("could not run ssh for \(host): \(error)")
            return nil
        }
        if let stdin {
            input.fileHandleForWriting.write(Data(stdin.utf8))
        }
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Quotes a manifest path for the remote `sh`, keeping a leading `~` a
    /// *tilde* rather than a directory name.
    ///
    /// Single-quoting the whole path is what a shell-quoting helper normally
    /// does, and it is wrong here: `'~/.claude/settings.json'` suppresses the
    /// expansion, so every read misses and every write lands in a literal `~`
    /// directory beside the user's home. Only the leading segment gets this
    /// treatment — a `~` anywhere else is an ordinary character, and `~user` is
    /// deliberately not honoured, since a manifest path always means the account
    /// the daemon runs as.
    static func quote(_ value: String) -> String {
        if value == "~" { return "\"$HOME\"" }
        guard value.hasPrefix("~/") else { return singleQuoted(value) }
        let rest = String(value.dropFirst(2))
        // `~/.config` is not a directory name a manifest picked; it is the
        // *default value* of `XDG_CONFIG_HOME`, and on Linux the agents that live
        // there read the variable. OpenCode resolves its global config — plugins
        // included — under `$XDG_CONFIG_HOME/opencode`, and Amp documents
        // `$XDG_CONFIG_HOME/amp/plugins`. A Mac never sets the variable, so this
        // is a no-op there and only ever changes where a device install lands:
        // on a box whose owner moved their config, `~/.config` would write a
        // plugin into a directory the agent does not read.
        if rest == ".config" { return xdgConfigHome }
        if rest.hasPrefix(".config/") {
            return xdgConfigHome + "/" + singleQuoted(String(rest.dropFirst(".config/".count)))
        }
        return "\"$HOME\"/" + singleQuoted(rest)
    }

    /// `$XDG_CONFIG_HOME` when the device sets it, and the spec's own default
    /// otherwise. Double-quoted so a home directory with spaces survives.
    private static let xdgConfigHome = "\"${XDG_CONFIG_HOME:-$HOME/.config}\""

    private static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// A machine an agent integration is installed on: where its files live, and
/// what a hook there runs to report status.
///
/// The two travel together because they are the same decision. A hook on this
/// Mac reports through the `termio` CLI to the app's control socket; a hook on a
/// device has no `termio` and no app, and reports through `termiod set-status`
/// to the daemon that owns its PTY — which then broadcasts `E status` to every
/// attached viewer.
struct AgentIntegrationTarget: Sendable {
    let store: AgentConfigStore
    let reporter: HookReporter

    static let thisMac = AgentIntegrationTarget(
        store: LocalAgentConfigStore(), reporter: .termioCLI)

    static func device(host: String) -> AgentIntegrationTarget {
        AgentIntegrationTarget(store: SSHAgentConfigStore(host: host), reporter: .termiodDaemon)
    }

    var isLocal: Bool { reporter == .termioCLI }

    /// Which bundled skill this machine gets. They are different documents, not
    /// two spellings of one: the Mac's teaches the `termio sessions` CLI and gates
    /// on `TERMIO_SESSION`, and a device has neither — shipping it there would
    /// teach an agent to run a binary that is not installed.
    var skillResourceDirectory: String {
        isLocal ? "skills/termio" : "skills/termio-device"
    }
}

/// How a hook reports, once it is running on the target machine.
enum HookReporter: Hashable {
    /// `termio agent report <state>` against the app's control socket. Reads the
    /// session from `$TERMIO_SESSION` and can mine the agent's stdin blob for a
    /// transcript path, a conversation id, a tool name, and a prompt title.
    case termioCLI

    /// `termiod set-status "$TERMIOD_SESSION_ID" <state>` against the daemon's
    /// own socket (`termiod/src/main.rs`, `SetStatus`).
    ///
    /// **It carries state and title only.** The daemon's `SetStatus` has no
    /// transcript, conversation, tool, or prompt-title field, so the four stdin
    /// mining options are dropped rather than emitted as flags the remote binary
    /// would reject. Extending `SetStatus` is recorded as future work in
    /// `docs/design/20260824-agent-integration-on-a-device.md`; until then a device agent
    /// reports its state accurately and its transcript not at all.
    case termiodDaemon

    /// The binary a hook invokes. Local is the channel-stable CLI copy under
    /// Application Support — never the bundle, whose path can vanish. Remote is
    /// where `termiod remote deploy` installs, and is absolute because an agent's
    /// `PATH` frequently omits `~/.local/bin` and a hook that cannot exec fails
    /// indistinguishably from an agent that never reported.
    var binaryPath: String {
        switch self {
        case .termioCLI: CommandLineTool.supportCopyURL.path
        case .termiodDaemon: Termiod.remoteBinary()
        }
    }

    /// The binary as it must appear **inside a hook's shell command**.
    ///
    /// Single-quoting is right for this Mac — an absolute path that may contain
    /// spaces — and wrong for a device: `Termiod.remoteBinary()` is a shell
    /// *expression* (`$HOME/.local/bin/termiod`, the spelling `TermiodClient`
    /// drops unquoted into its own `ssh` command), so quoting it whole emits a
    /// literal `$HOME` directory that cannot exist. Every device hook then execs
    /// a path that is not there and fails on every turn — silently, because the
    /// command ends in `2>/dev/null || true`, which is exactly the failure this
    /// form is shaped to hide.
    var shellBinaryPath: String {
        let path = binaryPath
        guard path.hasPrefix("$HOME/") else { return AgentStatusHooks.shellQuote(path) }
        return "\"$HOME\"/"
            + AgentStatusHooks.shellQuote(String(path.dropFirst("$HOME/".count)))
    }

    /// The binary as a **JavaScript expression**, for the plugin dialects whose
    /// hook is generated source rather than a shell command. A third spelling
    /// because there is a third escaping context, not because the path differs:
    /// Bun's `$` escapes each interpolation into one argv token, so handing it
    /// `$HOME/...` would reach the kernel as a literal `$HOME` the same way the
    /// over-quoted shell form does.
    func javaScriptBinaryExpression(quotedAs jsString: (String) -> String) -> String {
        let path = binaryPath
        guard path.hasPrefix("$HOME/") else { return jsString(path) }
        return "(process.env.HOME ?? \"\") + " + jsString(String(path.dropFirst("$HOME".count)))
    }
}
