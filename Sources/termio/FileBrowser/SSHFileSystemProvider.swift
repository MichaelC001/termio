import Foundation

/// The OpenSSH ControlMaster socket termio-spawned `ssh` sessions share with the
/// inspector's remote file tree. The terminal session is the master: its launch
/// command carries `masterShellOptions`, the user authenticates once in the
/// terminal (agent, ProxyJump, 2FA — all OpenSSH's problem), and every pane
/// operation rides the same socket via `clientOptions` — no second handshake,
/// no auth prompt a background pane could ever raise.
enum SSHMux {
    /// Where the control sockets live: `~/.termio[-dev]/ssh-mux` — a stable path
    /// (never bundle-derived; a rebuilt dev app must keep reaching the same
    /// sockets) that is also SHORT, because a Unix socket path is capped at 103
    /// bytes (`sun_path`): under Application Support the dev channel's path plus
    /// ssh's 40-hex `%C` hash (per local host/remote host/port/user, which is
    /// what lets two sessions to one alias share one master) already measures
    /// 104 and ssh refuses with "ControlPath too long".
    static var directory: URL {
        AppChannel.homeConfigDirectory.appendingPathComponent("ssh-mux", isDirectory: true)
    }

    /// The `ControlPath` value both sides pass — `%C` is expanded by ssh itself.
    static var controlPathTemplate: String { directory.path + "/%C" }

    /// Creates the socket directory (0700 — a socket grants the session's access).
    static func ensureDirectory() {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    /// Appended to the `ssh <host>` command a terminal session launches:
    /// opportunistically become (or reuse) the master, and linger 60s after the
    /// terminal closes so a pane mid-listing isn't cut off. `auto` composes with
    /// a user config that already runs its own ControlMaster.
    static var masterShellOptions: String {
        "-o ControlMaster=auto -o ControlPath=\(shellQuoted(controlPathTemplate)) -o ControlPersist=60"
    }

    /// The argv options for pane-side helper commands: reuse the session's
    /// socket, never *become* a master (a pane must not own the connection), and
    /// `BatchMode` so a missing socket fails instead of prompting.
    static var clientOptions: [String] {
        ["-o", "ControlPath=\(controlPathTemplate)", "-o", "ControlMaster=no", "-o", "BatchMode=yes"]
    }

    /// POSIX single-quote escaping — the Application Support path contains a space.
    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Why a remote operation failed, split so the pane can react honestly:
/// `disconnected` (the mux socket is gone — terminal closed or ControlPersist
/// expired) shows a reconnect state rather than silently re-dialing.
enum SSHProviderError: Error {
    case disconnected
    case commandFailed(String)
    /// The host's `ls` output didn't parse — the pane says so instead of
    /// mis-rendering (an exotic uname / busybox remote).
    case unsupportedListing
    /// The file exceeds the preview byte cap.
    case tooLarge
}

/// Browses an SSH host's filesystem over the terminal session's own connection
/// (see `SSHMux`) by running plain shell commands — the xpipe approach, which
/// also works on hosts with the sftp subsystem disabled. `list` parses
/// `LC_ALL=C ls -lAn` output (numeric ids, C locale — the stable form), with the
/// GNU/BSD flag split decided by a one-time `uname` probe; `read` is a
/// byte-capped `cat`. Read-only in v1. An actor: the probe cache is mutated from
/// concurrent pane loads.
actor SSHFileSystemProvider: FileSystemProvider {
    let host: String

    private enum Flavor { case gnu, bsd }
    /// The per-host probe result (`uname -s` + `$HOME`), cached for the
    /// provider's lifetime so the tree pays for it once.
    private var probed: (flavor: Flavor, home: String)?

    init(host: String) {
        self.host = host
    }

    func root() async throws -> String {
        try await probe().home
    }

    func list(_ path: String) async throws -> [FileEntry] {
        let flavor = try await probe().flavor
        // `-l` for the type char, `-A` dotfiles, `-n` numeric ids (names with
        // spaces would shift the columns); GNU's `--full-time` / BSD's `-T` pin
        // the date to a fixed field count so the name offset is stable. `env`
        // rather than a `VAR=… cmd` prefix so a csh/fish login shell parses it.
        let listCommand = flavor == .gnu
            ? "env LC_ALL=C ls -lAn --full-time \(Self.quoted(path))"
            : "env LC_ALL=C ls -lAnT \(Self.quoted(path))"
        let output = try await run(listCommand)
        let text = String(decoding: output, as: UTF8.self)
        return try Self.parseListing(text, flavor: flavor).sortedForTree()
    }

    func read(_ path: String, limit: Int) async throws -> Data {
        // Cap at limit+1 so an over-limit file is detected (and refused) rather
        // than silently truncated — a cut-off image or half a file would look
        // like the real thing.
        let data = try await run("cat \(Self.quoted(path))", captureLimit: limit + 1)
        guard data.count <= limit else { throw SSHProviderError.tooLarge }
        return data
    }

    // MARK: Connection

    /// Runs one remote command over the session's mux socket. The master is
    /// checked first (`ssh -O check` — a local socket poke, no network): if it's
    /// gone the call throws `.disconnected` and *nothing* attempts a fresh dial,
    /// so the pane can never trigger an auth prompt.
    private func run(_ remoteCommand: String, captureLimit: Int? = nil) async throws -> Data {
        let check = await Self.runProcess(
            ["/usr/bin/ssh"] + SSHMux.clientOptions + ["-O", "check", host])
        guard check.status == 0 else { throw SSHProviderError.disconnected }

        let result = await Self.runProcess(
            ["/usr/bin/ssh"] + SSHMux.clientOptions + ["-T", host, "--", remoteCommand],
            captureLimit: captureLimit)
        // The capped read terminates ssh mid-stream — an expected non-zero exit.
        if let captureLimit, result.stdout.count > captureLimit - 1 { return result.stdout }
        guard result.status == 0 else {
            throw SSHProviderError.commandFailed(
                result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.stdout
    }

    /// `uname -s` picks the `ls` dialect (Linux → GNU, everything BSD-shaped →
    /// BSD flags), `$HOME` roots the tree. One round trip, cached per host.
    private func probe() async throws -> (flavor: Flavor, home: String) {
        if let probed { return probed }
        let output = try await run("uname -s; echo \"$HOME\"")
        let lines = String(decoding: output, as: UTF8.self)
            .split(separator: "\n").map(String.init)
        let flavor: Flavor = lines.first == "Linux" ? .gnu : .bsd
        let home = lines.count > 1 && lines[1].hasPrefix("/") ? lines[1] : "/"
        let result = (flavor, home)
        probed = result
        return result
    }

    // MARK: Parsing

    /// Parses `ls -lAn` output into entries. Fields are split by whitespace with
    /// the name as the untouched remainder, so names with internal spaces
    /// survive; a symlink's ` -> target` suffix is stripped and the link shown
    /// as a file (v1 doesn't chase targets). Unrecognizable lines are skipped —
    /// unless *every* line is, which reads as an unsupported host rather than an
    /// empty directory.
    private static func parseListing(_ text: String, flavor: Flavor) throws -> [FileEntry] {
        // GNU --full-time: perms links uid gid size date time tz name
        // BSD -T:          perms links uid gid size month day time year name
        let metadataFields = flavor == .gnu ? 8 : 9
        var entries: [FileEntry] = []
        var skipped = 0
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: metadataFields,
                                   omittingEmptySubsequences: true)
            guard parts.count == metadataFields + 1,
                  let kind = parts[0].first, "dl-bcps".contains(kind) else {
                // `total N` header and anything unparseable.
                if !line.hasPrefix("total ") { skipped += 1 }
                continue
            }
            var name = String(parts[metadataFields])
            if kind == "l", let range = name.range(of: " -> ") {
                name = String(name[..<range.lowerBound])
            }
            guard !name.isEmpty else { continue }
            entries.append(FileEntry(
                name: name,
                isDirectory: kind == "d",
                size: Int64(parts[4]),
                modified: parseDate(parts, flavor: flavor)))
        }
        if entries.isEmpty, skipped > 0 { throw SSHProviderError.unsupportedListing }
        return entries
    }

    private static func parseDate(_ parts: [Substring], flavor: Flavor) -> Date? {
        switch flavor {
        case .gnu:
            // "2026-07-20 10:11:12.000000000 +0000" — drop the fraction.
            let time = parts[6].split(separator: ".").first ?? parts[6]
            return gnuDateFormatter.date(from: "\(parts[5]) \(time) \(parts[7])")
        case .bsd:
            // "Jul 20 10:11:12 2026" — the host's local time; close enough for
            // a listing that doesn't even display it yet.
            return bsdDateFormatter.date(from: "\(parts[5]) \(parts[6]) \(parts[7]) \(parts[8])")
        }
    }

    private static let gnuDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter
    }()

    private static let bsdDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d HH:mm:ss yyyy"
        return formatter
    }()

    /// Quotes a remote path for the shell on the *remote* side (ssh hands the
    /// command words to the login shell there).
    private static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Process

    /// Runs an argv off the main thread and collects its output. With
    /// `captureLimit`, stdout is read in chunks and the child terminated once
    /// the cap is passed — a multi-GB remote `cat` must not stream to the Mac.
    /// stderr is drained after stdout EOF (ssh's diagnostics are small, so this
    /// can't deadlock the 64 KB pipe the way a large payload could).
    private static func runProcess(
        _ argv: [String], captureLimit: Int? = nil
    ) async -> (status: Int32, stdout: Data, stderr: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runProcessSync(argv, captureLimit: captureLimit))
            }
        }
    }

    private static func runProcessSync(
        _ argv: [String], captureLimit: Int?
    ) -> (status: Int32, stdout: Data, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch {
            return (127, Data(), error.localizedDescription)
        }

        var stdout = Data()
        let reader = out.fileHandleForReading
        while let chunk = try? reader.read(upToCount: 65536), !chunk.isEmpty {
            stdout.append(chunk)
            if let captureLimit, stdout.count > captureLimit {
                process.terminate()
                break
            }
        }
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, stdout, String(decoding: stderr, as: UTF8.self))
    }
}
