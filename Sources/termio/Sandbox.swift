import Foundation

/// Per-project sandbox configuration. Lives on `Project` (so it persists for free via
/// the existing `Codable` project store) and is the single source of truth the
/// per-project Security panel edits.
///
/// A session opted into a sandbox runs as a normal host process wrapped in an Apple
/// Seatbelt profile (compiled by `SeatbeltProfile`): the project directory stays
/// read-write, system paths stay readable, and everything else — SSH keys, the login
/// Keychain, the rest of the home directory — is invisible. The agent's whole process
/// tree inherits it (Seatbelt restrictions only tighten, never widen across fork/exec),
/// so it confines the agent itself, not just the commands it runs.
///
/// The structured fields here are the editing surface; SBPL is an implementation detail
/// users never touch (except the deliberately advanced `extraRules`). The security
/// baseline (`SeatbeltProfile.compile`) is applied regardless and can only be relaxed
/// through the explicit escape-hatch flags below — a config mistake can widen what the
/// user added, never remove the floor.
struct SandboxProfile: Codable, Hashable {
    enum Network: String, Codable, Hashable {
        case off
        case full
    }

    /// `/workspace` (the project directory) is read-write by default — the agent's edits
    /// are meant to land in the real repo. Read-only suits "let it look, not touch".
    var workspaceReadOnly: Bool = false

    var network: Network = .full

    /// Hide `.env` / `.env.*` files from the agent even though they live inside the
    /// writable workspace. Default on. Note this also stops the agent's own subprocesses
    /// (`npm run dev`, test runners) from loading them — the Security panel surfaces that.
    var blockDotEnv: Bool = true

    /// Extra host trees the agent may read / read-write beyond the workspace (a sibling
    /// repo, a shared cache). These widen the sandbox; the baseline denies still win.
    var extraReadPaths: [String] = []
    var extraReadWritePaths: [String] = []

    /// Extra paths to hide on top of the baseline (e.g. a `secrets/` dir in the repo).
    var extraDenyPaths: [String] = []

    /// Escape hatches, each dropping one baseline deny when the agent legitimately needs
    /// it. Off by default — turning one on is a deliberate widening of the blast radius.
    var allowSSH: Bool = false
    var allowFullHomeRead: Bool = false

    /// Advanced: raw SBPL appended verbatim after everything else. Empty for almost
    /// everyone. Present so a power user has full reach without us exposing SBPL as the
    /// primary surface — it can only add rules on top of the baseline, never replace it.
    var extraRules: String = ""
}

/// Compiles a `SandboxProfile` into an Apple Seatbelt profile string (SBPL). The output
/// is what `sandbox-exec -p` enforces on a session. Proven end-to-end by
/// `scripts/seatbelt-smoke.sh`, which asserts the denies below actually hold.
enum SeatbeltProfile {
    /// Builds the profile for `workspacePath`. `home` and `temporaryDirectory` are
    /// injected (defaulting to the current process's) so the result is deterministic and
    /// testable. Paths are resolved to their canonical form by the caller when it matters
    /// for `subpath` matching (e.g. `/var` → `/private/var`).
    static func compile(_ profile: SandboxProfile,
                        workspacePath: String,
                        home: String = NSHomeDirectory(),
                        temporaryDirectory: String = NSTemporaryDirectory()) -> String {
        // Seatbelt matches `(subpath …)` against the *physical* path the kernel resolves
        // to, so paths must be canonicalized with `realpath` — notably `/var` and the
        // per-user temp dir resolve to `/private/var…`. (Foundation's
        // `resolvingSymlinksInPath()` does the opposite, stripping `/private`, which would
        // make the workspace rule silently never match.)
        let workspace = canonical(workspacePath)
        let tempDirectory = canonical(temporaryDirectory)

        var lines: [String] = []
        func emit(_ rule: String) { lines.append(rule) }

        emit("(version 1)")
        emit("(deny default)")

        // Process / exec basics a shell and its children need to run at all.
        emit("(allow process-exec*)")
        emit("(allow process-fork)")
        emit("(allow process-info* (target self))")
        emit("(allow signal (target self) (target same-sandbox))")
        emit("(allow sysctl-read)")
        emit("(allow system-info)")
        emit("(allow system-fsctl)")
        emit("(allow mach-task-name)")
        emit("(allow mach-per-user-lookup)")
        emit("(allow mach-lookup)")
        emit("(allow ipc-posix-shm-read-data)")
        emit("(allow ipc-posix-shm-write-data)")
        emit("(allow ipc-posix-shm-write-create)")

        // A real terminal session needs the controlling tty.
        emit("(allow pseudo-tty)")
        emit("(allow file-ioctl (literal \"/dev/tty\"))")
        emit("(allow file-ioctl (regex #\"^/dev/ttys[0-9]+$\"))")

        // Reading the root dir entry itself is required for exec path resolution.
        emit("(allow file-read* (literal \"/\"))")

        // System trees so tools, libraries, and dyld work.
        let systemReadRoots = ["/bin", "/sbin", "/usr", "/System", "/Library", "/etc",
                               "/private/etc", "/private/var/db/dyld", "/var/db/dyld",
                               "/opt", "/dev", "/Applications", "/private/var/db/timezone",
                               "/usr/share"]
        emit("(allow file-read* \(subpaths(systemReadRoots)))")

        // Map executables only from those trusted, read-only system trees plus the
        // workspace — this is the DYLD_INSERT_LIBRARIES guard (no loading libraries from
        // arbitrary writable locations outside the sandbox).
        emit("(allow file-map-executable \(subpaths(["/usr", "/System", "/Library", "/opt", workspace])))")

        // Dev toolchain caches the agent legitimately reads.
        let devCaches = ["\(home)/.npm", "\(home)/.nvm", "\(home)/.cache", "/opt/homebrew"]
        emit("(allow file-read* \(subpaths(devCaches)) (literal \(quote("\(home)/.gitconfig"))))")

        // Temp and per-user caches are writable.
        let writableCaches = [tempDirectory, "/private/tmp",
                              "\(home)/Library/Caches", "\(home)/Library/Logs"]
        emit("(allow file-read* file-write* \(subpaths(writableCaches)))")

        // Extra user-granted read / read-write trees.
        if !profile.extraReadPaths.isEmpty {
            emit("(allow file-read* \(subpaths(profile.extraReadPaths)))")
        }
        if !profile.extraReadWritePaths.isEmpty {
            emit("(allow file-read* file-write* \(subpaths(profile.extraReadWritePaths)))")
        }

        // The project workspace itself.
        let workspaceOps = profile.workspaceReadOnly ? "file-read*" : "file-read* file-write*"
        emit("(allow \(workspaceOps) (subpath \(quote(workspace))))")

        switch profile.network {
        case .full:
            emit("(allow network*)")
            emit("(allow system-socket)")
        case .off:
            emit("(deny network*)")
        }

        // Read-everything-in-home escape hatch sits before the deny floor so the floor
        // still wins for the genuinely sensitive paths below.
        if profile.allowFullHomeRead {
            emit("(allow file-read* (subpath \(quote(home))))")
        }

        // ===== Security baseline. Emitted LAST so it overrides every allow above
        // (Seatbelt resolves to the last matching rule). =====
        var credentialDenies = ["\(home)/.gnupg", "\(home)/.aws", "\(home)/.config/gcloud",
                                "\(home)/.kube", "\(home)/.docker"]
        if !profile.allowSSH { credentialDenies.append("\(home)/.ssh") }
        let credentialFiles = ["\(home)/.git-credentials", "\(home)/.netrc", "\(home)/.npmrc"]
        let credentialLiterals = credentialFiles.map { "(literal \(quote($0)))" }.joined(separator: " ")
        emit("(deny file-read* \(subpaths(credentialDenies)) \(credentialLiterals))")

        // The Keychain, denied at the file level AND via the Mach services that would
        // otherwise let a process read it through IPC despite the file deny.
        emit("(deny file-read* \(subpaths(["\(home)/Library/Keychains", "/Library/Keychains"])))")
        for service in ["com.apple.secd", "com.apple.securityd", "com.apple.security.keychaind",
                        "com.apple.SecurityServer", "com.apple.security.agent"] {
            emit("(deny mach-lookup (global-name \(quote(service))))")
        }

        if !profile.extraDenyPaths.isEmpty {
            emit("(deny file-read* \(subpaths(profile.extraDenyPaths)))")
        }

        // `.env` / `.env.local` / `.env.production` anywhere, including inside the
        // writable workspace. `.envrc` (direnv) is intentionally not matched.
        if profile.blockDotEnv {
            emit("(deny file-read* (regex #\"/\\.env(\\.[^/]+)?$\"))")
        }

        let trimmed = profile.extraRules.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { emit(trimmed) }

        return lines.joined(separator: "\n") + "\n"
    }

    /// Resolves `path` to its physical form via `realpath(3)` (following `/var` → `/private/var`
    /// and any other symlinks), which is what the Seatbelt kernel matches `subpath` against.
    /// Returns the input unchanged when the path doesn't exist yet (`realpath` fails).
    private static func canonical(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return path }
        return String(cString: buffer)
    }

    private static func subpaths(_ paths: [String]) -> String {
        paths.map { "(subpath \(quote($0)))" }.joined(separator: " ")
    }

    /// Quotes a path as an SBPL string literal, escaping backslashes and double quotes so
    /// a path containing either cannot break out of the literal.
    private static func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

/// Builds the PTY command that runs a session under its project's Seatbelt profile, and
/// owns the on-disk profile files it points `sandbox-exec -f` at.
///
/// Form: `sandbox-exec -f <profile> <login-shell> -lc <agent>` (or a login shell with no
/// command for a plain terminal session). The profile rides in a file rather than inline
/// so its parentheses, quotes, and newlines never have to survive however the terminal
/// tokenizes the command string. The agent is told to stand down its own sandbox (see
/// `AgentPreset.sandboxStandDownArguments`) — termio's profile is the one enforcement
/// layer, and a nested sandbox would fail to initialize anyway.
enum SandboxLauncher {
    /// The command to launch a sandboxed session, or `nil` if the profile file could not
    /// be written — in which case the caller runs on the host rather than launch a session
    /// that believes it is sandboxed but is not.
    static func command(agentCommand: String?,
                        agent: AgentPreset,
                        profile: SandboxProfile,
                        workspacePath: String,
                        sessionID: UUID) -> String? {
        // `compile` canonicalizes the workspace path itself (it must match the physical
        // path the kernel resolves to), so pass it through as-is.
        let sbpl = SeatbeltProfile.compile(profile, workspacePath: workspacePath)
        guard let profilePath = writeProfile(sbpl, sessionID: sessionID) else { return nil }

        let loginShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var argv = ["/usr/bin/sandbox-exec", "-f", profilePath]
        if let agentCommand, !agentCommand.isEmpty {
            var inner = agentCommand
            if let standDown = agent.sandboxStandDownArguments { inner += " " + standDown }
            // A login shell so PATH resolution and the multi-word command behave as they
            // do for an unsandboxed session.
            argv += [loginShell, "-lc", inner]
        } else {
            argv += [loginShell, "-l"]
        }
        return argv.map(shellQuote).joined(separator: " ")
    }

    /// Removes a session's profile file when its surface is torn down.
    static func cleanUp(sessionID: UUID) {
        try? FileManager.default.removeItem(at: profileURL(sessionID: sessionID))
    }

    private static func profileURL(sessionID: UUID) -> URL {
        let name = "termio-sandbox-\(sessionID.uuidString.prefix(8).lowercased()).sb"
        return FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }

    private static func writeProfile(_ sbpl: String, sessionID: UUID) -> String? {
        let url = profileURL(sessionID: sessionID)
        do {
            try sbpl.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        } catch {
            FileHandle.standardError.write(
                Data("termio: could not write the sandbox profile: \(error)\n".utf8))
            return nil
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
