import Darwin
import Foundation

/// One request from the `termio sessions …` CLI, sent as a single JSON object
/// over `SessionControlListener`'s local socket. This is the write/drive
/// counterpart to `HookListener`'s read-only status stream: where a hook reports
/// "this session is now working", a control request *acts on* a sibling session
/// — listing them, sending a prompt, answering a menu, starting or stopping one.
///
/// - `op` — `list` / `read` / `send` / `answer` / `start` / `stop`.
/// - `format` — `text` (human-readable lines, the default) or `json`.
/// - `callerSession` / `callerCwd` — who is asking, used to scope every operation
///   to the caller's own project. `callerSession` is the `TERMIO_SESSION` the PTY
///   carries; `callerCwd` (`$PWD`) is the fallback for a shell that isn't a termio
///   session but sits inside an open project's directory.
/// - `target` — the session to act on, matched within the caller's project by full
///   id, id prefix, or title.
/// - `text` — the prompt (`send`) or menu answer (`answer`).
/// - `agent` — which preset to launch (`start`).
struct ControlRequest: Decodable {
    let op: String
    let format: String?
    let callerSession: String?
    let callerCwd: String?
    let target: String?
    let text: String?
    let lines: Int?
    let agent: String?

    private enum CodingKeys: String, CodingKey {
        case op, format, target, text, lines, agent
        case callerSession = "caller_session"
        case callerCwd = "caller_cwd"
    }

    var wantsJSON: Bool { format == "json" }
}

/// A local Unix-domain socket the `termio sessions` CLI connects to. Unlike
/// `HookListener` (which only receives), this is request/response: it decodes one
/// `ControlRequest`, runs the handler on the main actor, and writes the handler's
/// reply back down the same connection before closing — so the CLI can print it.
///
/// This type owns only the transport. Resolving the caller's project, enforcing
/// project scope, and acting on sessions all live in `TermioStore` (the handler).
final class SessionControlListener {
    /// The control socket, alongside the status socket and session tree under
    /// termio's Application Support directory. Deliberately a *different* file from
    /// `HookListener.socketURL`: this one accepts drive commands, not status pings.
    static var socketURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            .map { $0.appendingPathComponent("termio", isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".termio", isDirectory: true)
        return base.appendingPathComponent("session-control.sock")
    }

    private let onRequest: @MainActor (ControlRequest) -> Data
    private let queue = DispatchQueue(label: "com.termio.session-control")
    private var source: DispatchSourceRead?
    private var listenDescriptor: Int32 = -1

    init(onRequest: @escaping @MainActor (ControlRequest) -> Data) {
        self.onRequest = onRequest
    }

    func start() {
        queue.async { [weak self] in self?.bindAndListen() }
    }

    func stop() {
        queue.async { [weak self] in
            self?.source?.cancel()
            self?.source = nil
        }
    }

    private func bindAndListen() {
        let url = Self.socketURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let path = url.path
        // A stale socket from a previous run makes bind() fail with EADDRINUSE.
        unlink(path)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { Self.log("socket() failed: \(errno)"); return }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let bytes = Array(path.utf8)
        guard bytes.count < capacity else {
            Self.log("socket path too long (\(bytes.count) ≥ \(capacity)): \(path)")
            close(descriptor)
            return
        }
        withUnsafeMutablePointer(to: &address.sun_path) {
            $0.withMemoryRebound(to: UInt8.self, capacity: capacity) { destination in
                for (index, byte) in bytes.enumerated() { destination[index] = byte }
                destination[bytes.count] = 0
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, size) }
        }
        guard bound == 0 else { Self.log("bind() failed: \(errno)"); close(descriptor); return }
        guard listen(descriptor, 16) == 0 else {
            Self.log("listen() failed: \(errno)"); close(descriptor); return
        }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(descriptor) }
        listenDescriptor = descriptor
        self.source = source
        source.resume()
    }

    private func acceptPending() {
        while true {
            let client = accept(listenDescriptor, nil, nil)
            if client < 0 { break }
            handle(client)
        }
    }

    private func handle(_ descriptor: Int32) {
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var request: ControlRequest?
        while data.count < 256 * 1024 {
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
            if let decoded = Self.decode(data) { request = decoded; break }
        }
        let decoded = request ?? Self.decode(data)
        guard let decoded else {
            Self.writeAll(descriptor, Data("error: malformed request\n".utf8))
            close(descriptor)
            return
        }
        // The handler touches `TermioStore`, so it must run on the main actor; the
        // reply is written back on this private queue so the socket work stays off
        // the main thread.
        let handler = onRequest
        Task { @MainActor in
            let response = handler(decoded)
            self.queue.async {
                Self.writeAll(descriptor, response)
                close(descriptor)
            }
        }
    }

    private static func writeAll(_ descriptor: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = write(descriptor, base + offset, data.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }

    private static func decode(_ data: Data) -> ControlRequest? {
        try? JSONDecoder().decode(ControlRequest.self, from: data)
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("termio: session control \(message)\n".utf8))
    }
}

/// Tells a coding agent that the `termio sessions` CLI exists and is scoped to its
/// own project, by writing a small marker-wrapped block into the user-level
/// instruction files agents read on startup (`~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`).
///
/// Deliberately writes to the *user-level* files, not a project's own `CLAUDE.md`
/// / `AGENTS.md`: those belong to the user's repository and editing them would
/// dirty their git tree. Conservative like `AgentStatusHooks` — it only ever
/// touches text between its own markers, leaving everything else untouched, and
/// removes exactly that block on uninstall.
enum SessionSkillInstaller {
    private static let beginMarker = "<!-- termio:sessions BEGIN -->"
    private static let endMarker = "<!-- termio:sessions END -->"

    private static var targets: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".claude/CLAUDE.md"),
            home.appendingPathComponent(".codex/AGENTS.md"),
        ]
    }

    /// The injected guidance. Kept short on purpose — the CLI is self-documenting
    /// via `termio sessions --help`, so this only needs to make the agent aware it
    /// exists and that scope is the current project.
    private static var block: String {
        """
        \(beginMarker)
        ## Sibling sessions (termio)

        You are running inside termio alongside other agent sessions in this same
        project. To coordinate with them, use the `termio sessions` command:

        - `termio sessions list` — sibling sessions in this project and their status
        - `termio sessions read <id>` — read a sibling's recent output
        - `termio sessions send <id> "<prompt>"` — send a prompt to a sibling
        - `termio sessions answer <id> "<choice>"` — answer a sibling's menu/prompt
        - `termio sessions start <agent>` / `termio sessions stop <id>`

        Scope is this project only. Prefer reading a sibling's output before you
        send it a prompt. Add `--json` for machine-readable output.
        \(endMarker)
        """
    }

    static func sync(enabled: Bool) {
        for url in targets {
            if enabled { install(into: url) } else { uninstall(from: url) }
        }
    }

    private static func install(into url: URL) {
        let stripped = strippedExisting(at: url)
        let separator = stripped.isEmpty ? "" : "\n\n"
        write(stripped + separator + block + "\n", to: url)
    }

    private static func uninstall(from url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let stripped = strippedExisting(at: url)
        // If removing our block leaves nothing, the file held only our note (we
        // created it), so delete it rather than leaving an empty file behind. A
        // file with the user's own content is rewritten preserving it.
        if stripped.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            write(stripped + "\n", to: url)
        }
    }

    /// The file's current contents with any existing termio block (and the
    /// whitespace around it) removed, so install/uninstall never touch the user's
    /// own text. Returns "" when the file is absent or unreadable.
    private static func strippedExisting(at url: URL) -> String {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        guard let begin = contents.range(of: beginMarker),
              let end = contents.range(of: endMarker, range: begin.upperBound..<contents.endIndex)
        else { return contents.trimmingCharacters(in: .newlines) }
        var result = contents
        result.removeSubrange(begin.lowerBound..<end.upperBound)
        return result.trimmingCharacters(in: .newlines)
    }

    private static func write(_ contents: String, to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.data(using: .utf8)?.write(to: url, options: .atomic)
        } catch {
            FileHandle.standardError.write(
                Data("termio: session skill could not write \(url.path): \(error)\n".utf8))
        }
    }
}

extension AgentPreset {
    /// Resolves a free-text agent name from the CLI (`termio sessions start claude`)
    /// to a preset, accepting the raw case, the display name, and common aliases.
    /// `nil` when nothing matches, so the caller can report it rather than guess.
    static func resolve(_ raw: String?) -> AgentPreset? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else {
            return nil
        }
        for preset in allCases
        where preset.rawValue.lowercased() == raw || preset.displayName.lowercased() == raw {
            return preset
        }
        switch raw {
        case "claude", "claude-code", "claudecode", "cc": return .claudeCode
        case "oc": return .opencode
        case "shell", "term": return .terminal
        default: return nil
        }
    }
}
