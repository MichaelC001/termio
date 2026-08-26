import Darwin
import Foundation

/// A normalized status report sent by an agent's hook into termio's local socket.
/// The agent-specific knowledge ("this lifecycle event means the agent is now
/// working") is baked into the hook command installed per agent, so every agent
/// speaks the same tiny vocabulary and termio needs no per-agent parsing:
///
/// - `termioSession` — the `TERMIO_SESSION` env value termio stamped into the PTY
///   (see `TermioStore.surface`), echoed back so the event maps to the exact
///   session even when several share one project directory.
/// - `state` — one of `working` / `attention` / `done` / `idle`.
/// - `cwd` — the agent's working directory, a correlation fallback for any agent
///   whose environment didn't carry `TERMIO_SESSION` through to the hook.
struct StatusReport: Decodable {
    let termioSession: String?
    let state: String
    let tool: String?
    let cwd: String?
    /// The agent's own conversation log for this session (Claude Code's
    /// `transcript_path`), forwarded by the hook so termio can hand a caller the
    /// address of the raw Q&A instead of scraping the terminal. Absent for agents
    /// whose hook doesn't carry it.
    let transcriptPath: String?
    /// The agent's own id for the conversation this session is currently writing,
    /// forwarded by hooks/plugins whose host exposes it (the manifest's
    /// `hooks.conversation` locator). Lets termio advance the resume pin the moment
    /// the agent rotates conversations in-process (`/new`), without needing the id
    /// to be encoded in a transcript filename. Absent for identity-blind hooks.
    let conversationID: String?
    /// Raw first-prompt title candidate forwarded by hook hosts that expose one.
    /// `TermioStore` normalizes and bounds it before persisting anything.
    let promptTitle: String?

    private enum CodingKeys: String, CodingKey {
        case termioSession = "termio_session"
        case state
        case tool
        case cwd
        case transcriptPath = "transcript_path"
        case conversationID = "conversation_id"
        case promptTitle = "prompt_title"
    }
}

/// Turns an agent hook's raw user prompt into a quiet sidebar fallback. This is
/// intentionally deterministic: hooks run before the model, so the title must be
/// available immediately without another request or a transcript-format dependency.
enum AgentPromptTitle {
    static let maximumLength = 64

    /// Markdown a prompt often opens with. It decorates; it never names the topic.
    private static let decoration: Set<Character> = ["#", ">", "*", "-", "•", "`"]

    static func normalized(_ raw: String) -> String? {
        let collapsed = raw.split(whereSeparator: isNoise).joined(separator: " ")
        let title = collapsed.drop { decoration.contains($0) || $0 == " " }
        guard !title.isEmpty else { return nil }
        guard title.count > maximumLength else { return String(title) }
        return bounded(title) + "…"
    }

    /// A control character travels in a prompt as literally as a newline does, and on
    /// one sidebar line both are noise rather than text.
    private static func isNoise(_ character: Character) -> Bool {
        character.isWhitespace
            || character.unicodeScalars.allSatisfy(CharacterSet.controlCharacters.contains)
    }

    /// Cuts to fit, preferring a word boundary — but only one past the halfway mark,
    /// so a long opening word cannot shrink the label to a syllable.
    private static func bounded(_ title: Substring) -> String {
        let head = title.prefix(maximumLength - 1)
        guard let lastSpace = head.lastIndex(of: " "),
              head.distance(from: head.startIndex, to: lastSpace) >= maximumLength / 2
        else { return String(head) }
        return String(head[..<lastSpace])
    }
}

/// A local Unix-domain socket that agent hooks report into. This is what gives
/// termio per-turn activity ("working", the rotating spinner): the zero-config
/// bell/OSC signals fire on command *finish*, never *start*, so "is the agent
/// thinking right now" can't be inferred from them alone. Each agent's hook
/// command (installed by `AgentStatusHooks`) pipes a `StatusReport` straight here.
///
/// This type owns only the transport: it decodes one `StatusReport` per connection
/// and hands it to `onReport` on the main actor. Correlating a report to a session
/// and the resulting state transition live in `TermioStore`.
final class HookListener {
    /// The socket file, under termio's Application Support directory — the same
    /// place the session tree is saved.
    static var socketURL: URL {
        AppChannel.supportDirectory.appendingPathComponent("agent-status.sock")
    }

    private let onReport: @MainActor (StatusReport) -> Void
    private let queue = DispatchQueue(label: "com.termio.hook-listener")
    private var source: DispatchSourceRead?
    private var listenDescriptor: Int32 = -1
    /// Watches the socket *file* we bound, so an instance that loses the path to
    /// someone else's `unlink` finds out (see `LocalSocket.watchForReplacement`).
    private var pathWatch: DispatchSourceFileSystemObject?
    /// Runs only while another instance holds the path, and takes it back when
    /// that one goes away (see `LocalSocket.retryWhenFree`).
    private var reclaim: DispatchSourceTimer?

    init(onReport: @escaping @MainActor (StatusReport) -> Void) {
        self.onReport = onReport
    }

    /// Binds the socket and begins accepting connections. All socket work happens
    /// on a private serial queue; failures are logged and degrade to "no hook
    /// signal" rather than trapping, per the project's no-crash rule.
    func start() {
        queue.async { [weak self] in self?.bindAndListen() }
    }

    private func bindAndListen() {
        let url = Self.socketURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let path = url.path
        // Only clear a socket file nothing is listening on — the same guard session
        // control uses, and for a worse failure. Unlinking whatever is there lets a
        // second instance steal the channel: the running app keeps its now-unnamed
        // socket, every hook connects to the new file, and once the thief exits the
        // file it leaves behind refuses every connection. Hooks fire constantly, so
        // the command they run ends in `2>/dev/null || true` and cannot say a word
        // about it — the status plane just goes quiet, permanently, with agents
        // still working and every row calm.
        if LocalSocket.isLive(path) {
            Self.log("""
                another termio already answers at \(path) — leaving agent status to it \
                (relaunch this process with TERMIO_CHANNEL=dev for a channel of its own; \
                that steers this run, not how a bundle was built)
                """)
            // Standing down is not a decision for the rest of the run: the other
            // instance is usually a short-lived `swift run`, and when it goes the
            // path is ours to take.
            if reclaim == nil {
                reclaim = LocalSocket.retryWhenFree(path: path, on: queue) { [weak self] in
                    self?.bindAndListen()
                }
            }
            return
        }
        reclaim?.cancel()
        reclaim = nil
        // Nothing answers, so any file here is a leftover: clearing it is what
        // keeps bind() from failing with EADDRINUSE.
        unlink(path)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { Self.log("socket() failed: \(errno)"); return }

        guard var address = LocalSocket.address(for: path) else {
            Self.log("socket path too long: \(path)")
            close(descriptor)
            return
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, size) }
        }
        guard bound == 0 else { Self.log("bind() failed: \(errno)"); close(descriptor); return }
        guard listen(descriptor, 16) == 0 else {
            Self.log("listen() failed: \(errno)"); close(descriptor); return
        }
        // Non-blocking listen socket so the accept loop drains every pending
        // connection per readable event and then stops cleanly on EAGAIN.
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(descriptor) }
        listenDescriptor = descriptor
        self.source = source
        source.resume()
        pathWatch = LocalSocket.watchForReplacement(of: path, on: queue) { [weak self] in
            guard let self else { return }
            Self.log("agent status socket was replaced — rebinding")
            self.pathWatch?.cancel()
            self.pathWatch = nil
            self.source?.cancel()
            self.source = nil
            self.listenDescriptor = -1
            self.bindAndListen()
        }
    }

    private func acceptPending() {
        while true {
            let client = accept(listenDescriptor, nil, nil)
            if client < 0 { break }
            handle(client)
        }
    }

    private func handle(_ descriptor: Int32) {
        defer { close(descriptor) }
        // A receive timeout is the backstop for a client that connects and then
        // neither sends a full payload nor closes — it can't wedge the queue.
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        // Decode after each chunk so we react the instant a complete JSON object
        // has arrived, regardless of whether the sender (`nc`) keeps the
        // connection open afterwards. The cap guards against a runaway stream.
        while data.count < 64 * 1024 {
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
            if let report = Self.decode(data) { dispatch(report); return }
        }
        if let report = Self.decode(data) { dispatch(report) }
    }

    private static func decode(_ data: Data) -> StatusReport? {
        try? JSONDecoder().decode(StatusReport.self, from: data)
    }

    private func dispatch(_ report: StatusReport) {
        let handler = onReport
        Task { @MainActor in handler(report) }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("termio: hook listener \(message)\n".utf8))
    }
}
