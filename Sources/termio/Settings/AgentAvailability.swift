import Foundation

/// Whether an agent's launch command resolves to a real executable on the same PATH
/// termio's sessions launch with — the user's *login-shell* PATH (`-ilc`, matching
/// `TermioStore.launchArgv`), not the minimal PATH a Finder-launched app inherits.
///
/// Used by the Agents settings tab to flag an agent whose CLI isn't installed (or
/// lives somewhere off PATH) so the user can enter a full path in the command field
/// or follow the install link — turning the cryptic "failed to launch / 0 ms" pane
/// into a fixable, up-front signal.
enum AgentAvailability {
    /// The login-shell PATH directories, resolved once off the main thread and cached
    /// for the app run. The probe is bounded so a slow/hung rc can't wedge Settings;
    /// on failure it yields an empty list, which makes every check fall back to
    /// "assume available" rather than raise a false alarm.
    private static let resolvedPath = Task.detached(priority: .utility) { pathDirectories() }

    /// The resolved login-shell PATH, shared between the async probe and the
    /// synchronous installer check so both agree on one answer. The detached task
    /// populates it when it finishes; the sync check reads it without blocking.
    private static let pathLock = NSLock()
    // Guarded by `pathLock` on every access; the lock is the synchronization the
    // compiler cannot see.
    nonisolated(unsafe) private static var pathCache: [String]?
    /// The login-shell values of the variables a Finder-launched app never sees.
    /// Populated by the same probe and guarded by the same lock.
    nonisolated(unsafe) private static var environmentCache: [String: String]?

    private static func pathDirectories() -> [String] {
        pathLock.withLock {
            if let cached = pathCache { return cached }
            let resolved = probeLoginShell()
            pathCache = resolved.path
            environmentCache = resolved.environment
            return resolved.path
        }
    }

    /// Whether the first word of `command` (its binary) is an executable on PATH. An
    /// absolute/`~` path is checked directly; an empty command (the plain login shell)
    /// is always "available".
    static func isCommandAvailable(_ command: String) async -> Bool {
        guard let binary = firstWord(command), !binary.isEmpty else { return true }
        if binary.hasPrefix("/") || binary.hasPrefix("~") {
            return FileManager.default.isExecutableFile(atPath: (binary as NSString).expandingTildeInPath)
        }
        let directories = await resolvedPath.value
        // Probe failed (no PATH) → don't cry wolf; only flag when we actually looked.
        guard !directories.isEmpty else { return true }
        return directories.contains {
            FileManager.default.isExecutableFile(atPath: $0 + "/" + binary)
        }
    }

    /// Which of these commands resolve on this Mac, by agent id.
    ///
    /// Takes the map rather than reading it from settings, so a caller that is
    /// already inside a task — the launch sync is one — never has to reach back
    /// into an observable object to answer this.
    static func presentIDs(in commands: [String: String]) async -> [String] {
        var present: [String] = []
        for (id, command) in commands where await isCommandAvailable(command) {
            present.append(id)
        }
        return present.sorted()
    }

    /// The binary a command line names: its first shell word, with quoting
    /// honoured.
    ///
    /// Splitting on a bare space is wrong for the case that most needs a path
    /// typed by hand — `"/Users/me/Agent Tools/codex"` — where it yields
    /// `"/Users/me/Agent` and answers "not installed" for a CLI sitting right
    /// there. `termiod`'s `machine::first_word` resolves the same string the
    /// same way; the two must agree, or this side reports an agent available and
    /// that side refuses to write its config.
    static func firstWord(_ command: String) -> String? {
        // Unicode *scalars*, not Characters: a combining mark right after a
        // closing quote forms one grapheme with it, and iterating graphemes
        // would miss the quote. `termiod` walks scalars, and the two answers
        // have to be the same one.
        var word = String.UnicodeScalarView()
        var quote: Unicode.Scalar?
        var escaped = false
        for scalar in command.unicodeScalars.drop(while: { $0.properties.isWhitespace }) {
            if escaped {
                word.append(scalar)
                escaped = false
            } else if scalar == "\\", quote != "'" {
                // Never inside single quotes, where the shell keeps a backslash
                // literally — `'/opt/agent\tools/cli'` names a path that has one.
                escaped = true
            } else if scalar == quote {
                quote = nil
            } else if quote == nil, scalar == "'" || scalar == "\"" {
                quote = scalar
            } else if quote == nil, scalar.properties.isWhitespace {
                break
            } else {
                word.append(scalar)
            }
        }
        return word.isEmpty ? nil : String(word)
    }

    /// One login-shell spawn answers for everything a GUI-launched app cannot see
    /// about its user's environment. `PATH` is why this exists; the XDG bases ride
    /// along because they have the same problem and asking twice would mean paying
    /// for a second shell whose rc can take seconds.
    private static func probeLoginShell() -> (path: [String], environment: [String: String]) {
        let names = ["XDG_CONFIG_HOME", "XDG_DATA_HOME"]
        // `${VAR-}` rather than `$VAR`, so an unset variable is an empty field and
        // the fields stay positional under `set -u`.
        let fields = (["$PATH"] + names.map { "${\($0)-}" })
            .map { "\"\($0)\"" }
            .joined(separator: " ")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: loginShell)
        process.arguments = ["-ilc", "printf '%s\\n' \(fields)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return ([], [:]) }
        // Bound the probe: a login shell whose rc blocks must not hang forever.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning { process.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        guard let path = lines.first else { return ([], [:]) }
        var environment: [String: String] = [:]
        for (index, name) in names.enumerated() {
            let value = index + 1 < lines.count ? lines[index + 1] : ""
            if !value.isEmpty { environment[name] = value }
        }
        return (path.split(separator: ":").map(String.init), environment)
    }

    /// A login-shell environment value, for the variables a Finder launch drops.
    /// Non-blocking: the process environment until the probe lands, which only
    /// means an early call answers the way today's code already does.
    static func loginShellEnvironment(_ name: String) -> String? {
        if let value = ProcessInfo.processInfo.environment[name], !value.isEmpty { return value }
        var resolved: [String: String]?
        pathLock.withLock { resolved = environmentCache }
        return resolved?[name]
    }

    /// The user's real login shell, read from the password database rather than the
    /// ambient `SHELL` (which a GUI launch may leave unset or `/bin/sh`) — the same
    /// resolution `TermioStore.launchArgv` uses, so this checks the exact PATH a
    /// session would launch with.
    private static var loginShell: String {
        if let entry = getpwuid(getuid()), let cString = entry.pointee.pw_shell {
            let value = String(cString: cString)
            if !value.isEmpty { return value }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }
}
