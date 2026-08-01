import Darwin
import Foundation

/// Attach client for the local `termiod` session host (Session Protocol v0.1,
/// see termiod/src/protocol.rs). Behind the opt-in `TERMIO_TERMIOD=1` flag the
/// app stops owning PTYs itself: every session lives inside the daemon, the app
/// merely attaches over the Unix socket, and quitting detaches instead of
/// killing — which is what lets sessions survive an app quit or self-update.
///
/// Framing is `[kind: u8][length: u32 big-endian][payload]`. Control payloads
/// are JSON; `D` (data) is raw PTY bytes and `R` (resize) is rows/cols as two
/// big-endian u16. This client negotiates no optional capability yet — without
/// `snapshot` the daemon bootstraps an attach with a ring-buffer byte replay,
/// which is the accepted (possibly torn) repaint for this slice; the clean `S`
/// snapshot path is the next one.
enum Termiod {
    /// Checked once — the flag flips the app's session backend wholesale, so a
    /// mid-run change could not be honored anyway.
    static let isEnabled = ProcessInfo.processInfo.environment["TERMIO_TERMIOD"] == "1"

    /// When set (with the flag on), new sessions run on this SSH host — reached
    /// via `ssh <host> termiod stdio`, the exact same framed protocol as local.
    /// The remote must already have `termiod` deployed (`termiod remote deploy`).
    /// A single demo/dev host; per-session host selection is a UI follow-up.
    static let remoteHost: String? = {
        let host = ProcessInfo.processInfo.environment["TERMIO_TERMIOD_REMOTE"]
        return (host?.isEmpty == false) ? host : nil
    }()

    static let protocolVersion: UInt32 = 1

    /// Mirrors termiod/src/paths.rs exactly — both sides must derive the same
    /// socket or the app talks to a different daemon than the CLI:
    /// `TERMIOD_SOCK` override, else `$XDG_RUNTIME_DIR/termiod/`, else a
    /// uid-scoped directory under the temp dir (`$TMPDIR`, else `/tmp` — the
    /// same fallback order as Rust's `std::env::temp_dir()`).
    static func socketPath() -> String {
        let environment = ProcessInfo.processInfo.environment
        if let explicit = environment["TERMIOD_SOCK"], !explicit.isEmpty {
            return explicit
        }
        if let runtimeDirectory = environment["XDG_RUNTIME_DIR"], !runtimeDirectory.isEmpty {
            return runtimeDirectory + "/termiod/termiod.sock"
        }
        let temporaryDirectory = environment["TMPDIR"] ?? "/tmp"
        let base = temporaryDirectory.hasSuffix("/")
            ? String(temporaryDirectory.dropLast())
            : temporaryDirectory
        return "\(base)/termiod-\(getuid())/termiod.sock"
    }

    /// The daemon binary used for autostart: `TERMIO_TERMIOD_BIN` when set,
    /// else the dev build inside the working tree the app was launched from.
    /// One resolution point so autostart and diagnostics can never disagree.
    static func daemonBinaryPath() -> String {
        let environment = ProcessInfo.processInfo.environment
        if let explicit = environment["TERMIO_TERMIOD_BIN"], !explicit.isEmpty {
            return explicit
        }
        return FileManager.default.currentDirectoryPath + "/termiod/target/debug/termiod"
    }

    // MARK: - Socket

    /// One blocking connect attempt against the daemon socket.
    private static func openSocket() -> Int32? {
        let path = socketPath()
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path) - 1
        guard pathBytes.count <= capacity else {
            close(descriptor)
            return nil
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.connect(descriptor, rebound, length)
            }
        }
        guard connected == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    /// Connect, auto-starting `termiod serve` when no daemon answers — the
    /// same detached-spawn-and-poll the Rust CLI performs, so whichever side
    /// touches the socket first brings the daemon up for both.
    static func connectWithAutostart() throws -> Int32 {
        if let descriptor = openSocket() { return descriptor }
        try spawnDaemon()
        for _ in 0 ..< 50 {
            usleep(40_000)
            if let descriptor = openSocket() { return descriptor }
        }
        throw TermiodClientError.daemonUnreachable(socketPath())
    }

    /// The remote `termiod` path invoked over SSH. Matches the CLI's deploy
    /// target (`termiod remote deploy` installs to `~/.local/bin/termiod`);
    /// overridable so a non-standard install still works.
    static func remoteBinary() -> String {
        ProcessInfo.processInfo.environment["TERMIOD_REMOTE_BIN"]
            ?? "$HOME/.local/bin/termiod"
    }

    /// A bidirectional byte channel to a daemon. Local is one Unix-socket fd
    /// used for both directions; SSH is a pipe pair around an `ssh <host>
    /// termiod stdio` child — the exact same framed protocol either way, which
    /// is the whole point of the stdio bridge. The frame helpers read from
    /// `readDescriptor` and write to `writeDescriptor`.
    final class Transport {
        let readDescriptor: Int32
        let writeDescriptor: Int32
        private let sshPid: pid_t?

        private init(readDescriptor: Int32, writeDescriptor: Int32, sshPid: pid_t?) {
            self.readDescriptor = readDescriptor
            self.writeDescriptor = writeDescriptor
            self.sshPid = sshPid
        }

        /// Local Unix socket; the same fd serves both directions.
        static func local() throws -> Transport {
            let descriptor = try connectWithAutostart()
            return Transport(readDescriptor: descriptor, writeDescriptor: descriptor, sshPid: nil)
        }

        /// `ssh <host> termiod stdio`: the framed protocol rides the SSH pipe,
        /// so the remote daemon (auto-starting on first contact) is reached
        /// with the identical messages. System OpenSSH is the trust plane; no
        /// keys or crypto live in termio.
        static func ssh(host: String) throws -> Transport {
            var toChild = [Int32](repeating: -1, count: 2) // app writes [1] → child stdin [0]
            var fromChild = [Int32](repeating: -1, count: 2) // child stdout [1] → app reads [0]
            guard pipe(&toChild) == 0 else {
                throw TermiodClientError.daemonUnreachable("ssh:\(host)")
            }
            // Close the first pair before bailing, or a second-pipe failure (most
            // likely under fd exhaustion — exactly when it happens) leaks two fds.
            guard pipe(&fromChild) == 0 else {
                Darwin.close(toChild[0])
                Darwin.close(toChild[1])
                throw TermiodClientError.daemonUnreachable("ssh:\(host)")
            }

            var fileActions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&fileActions)
            defer { posix_spawn_file_actions_destroy(&fileActions) }
            posix_spawn_file_actions_adddup2(&fileActions, toChild[0], 0)
            posix_spawn_file_actions_adddup2(&fileActions, fromChild[1], 1)
            // Child inherits stderr for SSH diagnostics; close the pipe ends it
            // must not keep open.
            posix_spawn_file_actions_addclose(&fileActions, toChild[1])
            posix_spawn_file_actions_addclose(&fileActions, fromChild[0])

            let command = "\(remoteBinary()) stdio"
            let arguments = ["ssh", "-o", "ServerAliveInterval=15", host, command]
            let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
            defer { argv.forEach { free($0) } }

            var pid: pid_t = 0
            let status = posix_spawnp(&pid, "ssh", &fileActions, nil, argv, environ)
            Darwin.close(toChild[0])
            Darwin.close(fromChild[1])
            guard status == 0 else {
                Darwin.close(toChild[1])
                Darwin.close(fromChild[0])
                throw TermiodClientError.daemonSpawnFailed(status)
            }
            return Transport(readDescriptor: fromChild[0], writeDescriptor: toChild[1], sshPid: pid)
        }

        /// Detach: closing the pipe/socket ends the attach without killing the
        /// session, and reaps the SSH child so it can't linger. Closing the fds
        /// is synchronous (it wakes the blocked reader); reaping the SSH child is
        /// dispatched off the caller's thread so a wedged connection can never
        /// beachball the app — `detach()` runs on the main actor at quit, once
        /// per session, and a blocking `waitpid` on a network-stalled ssh would
        /// hang Cmd-Q.
        func close() {
            Darwin.close(writeDescriptor)
            if readDescriptor != writeDescriptor {
                Darwin.close(readDescriptor)
            }
            guard let sshPid else { return }
            DispatchQueue.global(qos: .utility).async {
                kill(sshPid, SIGTERM)
                // Bounded, non-blocking reap: SIGTERM then poll briefly, escalate
                // to SIGKILL, and never block indefinitely. If it still lingers,
                // it is reparented to launchd, which reaps it.
                for _ in 0 ..< 20 {
                    var ignored: Int32 = 0
                    if waitpid(sshPid, &ignored, WNOHANG) != 0 { return }
                    usleep(50_000)
                }
                kill(sshPid, SIGKILL)
                var ignored: Int32 = 0
                _ = waitpid(sshPid, &ignored, WNOHANG)
            }
        }
    }

    /// Spawns `termiod serve` in its own session (`POSIX_SPAWN_SETSID`) with
    /// stdio on /dev/null, so the daemon survives the app — and, under
    /// `swift run`, a terminal Ctrl-C aimed at the app's process group.
    private static func spawnDaemon() throws {
        let binary = daemonBinaryPath()
        Log.termiod.info("starting daemon binary=\(binary, privacy: .public)")
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            throw TermiodClientError.daemonBinaryMissing(binary)
        }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, 2, "/dev/null", O_WRONLY, 0)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // CLOEXEC_DEFAULT matters as much as SETSID: without it the daemon
        // inherits every open descriptor of the app — including its listening
        // control sockets, which then stay half-alive after the app quits and
        // wedge the next binding (observed: `termio sessions` hanging against
        // a socket the long-lived daemon still held open).
        posix_spawnattr_setflags(
            &attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        // The daemon derives its socket path from its own environment, so it
        // must inherit ours (TMPDIR above all) or the two sides rendezvous at
        // different sockets.
        let argumentStrings = [binary, "serve"]
        let argv: [UnsafeMutablePointer<CChar>?] = argumentStrings.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] =
            ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, binary, &fileActions, &attributes, argv, envp)
        guard status == 0 else {
            throw TermiodClientError.daemonSpawnFailed(status)
        }
    }

    // MARK: - Framing

    enum FrameKind: UInt8 {
        case control = 0x43 // 'C'
        case data = 0x44 // 'D'
        case resize = 0x52 // 'R'
        case event = 0x45 // 'E'
        case snapshot = 0x53 // 'S'
        case history = 0x48 // 'H'
        case grid = 0x47 // 'G'
    }

    static let maximumFrameSize = 16 * 1024 * 1024
    /// The daemon chunks its own data frames at this size; mirror it upstream
    /// so a huge paste can't produce an oversized frame.
    static let maximumDataFrameSize = 64 * 1024

    static func writeFully(_ descriptor: Int32, _ data: Data) throws {
        var offset = 0
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            while offset < raw.count {
                let written = write(descriptor, base + offset, raw.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw TermiodClientError.connectionClosed
                }
            }
        }
    }

    static func writeFrame(_ descriptor: Int32, kind: FrameKind, payload: Data) throws {
        var frame = Data(capacity: 5 + payload.count)
        frame.append(kind.rawValue)
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        try writeFully(descriptor, frame)
    }

    private static func readExactly(_ descriptor: Int32, count: Int) throws -> Data {
        var buffer = Data(count: count)
        var offset = 0
        try buffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let base = raw.baseAddress else {
                throw TermiodClientError.connectionClosed
            }
            while offset < count {
                let readCount = read(descriptor, base + offset, count - offset)
                if readCount > 0 {
                    offset += readCount
                } else if readCount < 0, errno == EINTR {
                    continue
                } else {
                    throw TermiodClientError.connectionClosed
                }
            }
        }
        return buffer
    }

    /// Blocking read of one whole frame. Unknown kinds are a protocol error —
    /// the kind byte is the one non-additive part of the framing.
    static func readFrame(_ descriptor: Int32) throws -> (kind: FrameKind, payload: Data) {
        let header = try readExactly(descriptor, count: 5)
        let length = header.subdata(in: 1 ..< 5).withUnsafeBytes { raw in
            UInt32(bigEndian: raw.loadUnaligned(as: UInt32.self))
        }
        guard let kind = FrameKind(rawValue: header[0]), Int(length) <= maximumFrameSize else {
            throw TermiodClientError.malformedFrame
        }
        let payload = length == 0 ? Data() : try readExactly(descriptor, count: Int(length))
        return (kind, payload)
    }

    // MARK: - Control payloads

    /// Spawn parameters for `attach` with `create_if_missing`. The daemon
    /// fills `name` from the attach target, so it is not repeated here.
    struct CreateSpecification: Encodable {
        let cwd: String
        let argv: [String]
        /// Wire shape of Rust's `Vec<(String, String)>` — an array of pairs.
        let env: [[String]]
        let rows: UInt16
        let cols: UInt16
    }

    private struct HelloOperation: Encodable {
        let op = "hello"
        let proto: UInt32
        let minProto: UInt32
        let role: String
        let caps: [String]
        let client: String
    }

    private struct AttachOperation: Encodable {
        let op = "attach"
        let target: String
        let createIfMissing: CreateSpecification?
        let rows: UInt16
        let cols: UInt16
        let mode = "interact"
        let seq: UInt64
    }

    private struct ListOperation: Encodable {
        let op = "list"
        let seq: UInt64
    }

    private struct KillOperation: Encodable {
        let op = "kill"
        let id: String
        let seq: UInt64
    }

    private struct DetachOperation: Encodable {
        let op = "detach"
    }

    /// Only the `op` tag — the second decode pass picks the payload shape.
    private struct ControlTag: Decodable {
        let op: String
    }

    struct AttachedPayload: Decodable {
        let sessionId: String
        let writer: Bool
        let rows: UInt16
        let cols: UInt16
    }

    struct ExitedPayload: Decodable {
        let id: String
        let status: Int32
    }

    struct ErrorPayload: Decodable {
        let code: String?
        let message: String
    }

    struct SessionsPayload: Decodable {
        let sessions: [SessionInformation]
    }

    /// The subset of `termiod list` this client acts on; unknown fields are
    /// ignored so the daemon can grow the record additively.
    struct SessionInformation: Decodable {
        let id: String
        let name: String
        let pid: Int32
        let alive: Bool
    }

    /// Decoded control frames the client reacts to. Anything else — unknown
    /// ops, responses this slice doesn't consume — becomes `.unknown` and is
    /// ignored, matching the protocol's additive-evolution rule.
    enum IncomingControl {
        case helloOk
        case helloError(String)
        case attached(AttachedPayload)
        case exited(ExitedPayload)
        case sessions(SessionsPayload)
        case error(ErrorPayload)
        case unknown(String)
    }

    static func encodeControl(_ operation: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(operation)
    }

    static func decodeControl(_ payload: Data) throws -> IncomingControl {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let tag = try decoder.decode(ControlTag.self, from: payload)
        switch tag.op {
        case "hello_ok":
            return .helloOk
        case "hello_err":
            return .helloError("protocol negotiation failed")
        case "attached":
            return .attached(try decoder.decode(AttachedPayload.self, from: payload))
        case "exited":
            return .exited(try decoder.decode(ExitedPayload.self, from: payload))
        case "sessions":
            return .sessions(try decoder.decode(SessionsPayload.self, from: payload))
        case "error":
            return .error(try decoder.decode(ErrorPayload.self, from: payload))
        default:
            return .unknown(tag.op)
        }
    }

    // MARK: - Handshake and control channel

    /// Sends `hello` and waits for `hello_ok`. An attach channel offers the
    /// `snapshot` capability so a reattach bootstraps from the daemon's
    /// authoritative VT (one clean `S` repaint) instead of ring replay; the
    /// control channel negotiates nothing. `scrollback`/`grid_diff` stay
    /// unoffered — a byte-stream surface can neither inject history above the
    /// viewport nor consume dirty-row diffs (a deeper libghostty integration).
    static func performHello(_ transport: Transport, role: String, caps: [String] = []) throws {
        let hello = HelloOperation(
            proto: protocolVersion,
            minProto: protocolVersion,
            role: role,
            caps: caps,
            client: "termio-mac/dev"
        )
        try writeFrame(transport.writeDescriptor, kind: .control, payload: encodeControl(hello))
        let reply = try readFrame(transport.readDescriptor)
        guard reply.kind == .control else { throw TermiodClientError.malformedFrame }
        switch try decodeControl(reply.payload) {
        case .helloOk:
            return
        case .helloError(let message):
            throw TermiodClientError.handshakeRejected(message)
        case .error(let payload):
            throw TermiodClientError.handshakeRejected(payload.message)
        default:
            throw TermiodClientError.handshakeRejected("unexpected reply to hello")
        }
    }

    /// One-shot control request: connect, hello as `control`, run `body`,
    /// close. Used for `list` at startup and `kill` on Close Session.
    private static func withControlChannel<Result>(
        host: String? = nil,
        _ body: (Transport) throws -> Result
    ) throws -> Result {
        let transport = try host.map(Transport.ssh(host:)) ?? Transport.local()
        defer { transport.close() }
        try performHello(transport, role: "control")
        return try body(transport)
    }

    static func listSessions(host: String? = nil) throws -> [SessionInformation] {
        try withControlChannel(host: host) { transport in
            try writeFrame(transport.writeDescriptor, kind: .control,
                           payload: encodeControl(ListOperation(seq: 1)))
            while true {
                let frame = try readFrame(transport.readDescriptor)
                guard frame.kind == .control else { continue }
                switch try decodeControl(frame.payload) {
                case .sessions(let payload):
                    return payload.sessions
                case .error(let payload):
                    throw TermiodClientError.requestFailed(payload.message)
                default:
                    continue
                }
            }
        }
    }

    /// Ends a session for real — the explicit user-facing destroy verb, never
    /// part of quit/detach. The target may be a termiod id or name (the app
    /// uses the session UUID it named the session with).
    static func killSession(target: String, host: String? = nil) {
        DispatchQueue.global(qos: .utility).async {
            do {
                try withControlChannel(host: host) { transport in
                    try writeFrame(transport.writeDescriptor, kind: .control,
                                   payload: encodeControl(KillOperation(id: target, seq: 1)))
                    // One reply either way; "no such session" just means the
                    // process already exited, which is fine for a destroy.
                    _ = try readFrame(transport.readDescriptor)
                }
            } catch {
                Log.termiod.error("""
                kill \(target, privacy: .public) failed: \
                \(error.localizedDescription, privacy: .public)
                """)
            }
        }
    }

    static func attachPayload(
        target: String,
        specification: CreateSpecification?,
        rows: UInt16,
        cols: UInt16
    ) throws -> Data {
        try encodeControl(AttachOperation(
            target: target,
            createIfMissing: specification,
            rows: rows,
            cols: cols,
            seq: 1
        ))
    }

    static func detachPayload() throws -> Data {
        try encodeControl(DetachOperation())
    }
}

enum TermiodClientError: LocalizedError {
    case daemonUnreachable(String)
    case daemonBinaryMissing(String)
    case daemonSpawnFailed(Int32)
    case connectionClosed
    case malformedFrame
    case handshakeRejected(String)
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .daemonUnreachable(let socket):
            return "could not reach termiod at \(socket)"
        case .daemonBinaryMissing(let binary):
            return "termiod binary not found at \(binary)"
        case .daemonSpawnFailed(let status):
            return "posix_spawn of termiod failed with status \(status)"
        case .connectionClosed:
            return "the termiod connection closed"
        case .malformedFrame:
            return "malformed termiod frame"
        case .handshakeRejected(let message):
            return "termiod hello rejected: \(message)"
        case .requestFailed(let message):
            return message
        }
    }
}

/// One session's attach channel: the termiod-backed stand-in for what
/// `PTYProcess` is on the in-process path. Owns the socket, forwards surface
/// input as `D` frames and grid changes as `R` frames, and delivers the
/// daemon's output/exit back to the surface. Closing the socket is a detach —
/// the daemon keeps the session running; only `killAndClose` destroys it.
final class TermiodSessionLink: @unchecked Sendable {
    /// All connection state is confined to this serial queue: the handshake
    /// runs on it, sends hop onto it, and the reader thread only touches state
    /// through it — so no lock is needed.
    private let workQueue = DispatchQueue(label: "sh.termio.termiod.link", qos: .userInitiated)

    private let sessionName: String
    private let specification: Termiod.CreateSpecification
    /// When set, the session lives on this SSH host (reached via
    /// `ssh <host> termiod stdio`); when nil, on the local daemon. The framed
    /// protocol and every other field are identical either way.
    private let remoteHost: String?
    private let initialRows: UInt16
    private let initialCols: UInt16
    private let startedAt = Date()

    private var transport: Termiod.Transport?
    private var attached = false
    private var isWriter = false
    /// Keystrokes typed during the connect/attach window — flushed, in order,
    /// the moment the channel is writable so nothing the user typed is lost.
    private var pendingInput = Data()
    /// The latest grid reported before attach completed; applied once writable.
    private var pendingResize: (rows: UInt16, cols: UInt16)?
    /// Set on any deliberate teardown so the reader's EOF is not misread as a
    /// daemon crash.
    private var closed = false
    private var exitDelivered = false

    /// Raw PTY bytes from the daemon — fed to the surface exactly where
    /// `PTYProcess`'s read pump delivers on the in-process path. Called on the
    /// reader thread; the consumer (`InMemoryTerminalSession.receive`) is
    /// thread-safe.
    var onOutput: ((Data) -> Void)?
    /// Fired once on the main queue with the exit status and elapsed
    /// milliseconds since this link started (the daemon does not report the
    /// child's true runtime; elapsed-since-attach serves ghostty's
    /// abnormal-exit heuristic the same way).
    var onExit: ((Int32, UInt64) -> Void)?

    init(sessionName: String,
         specification: Termiod.CreateSpecification,
         remoteHost: String? = nil,
         rows: Int,
         cols: Int) {
        self.sessionName = sessionName
        self.specification = specification
        self.remoteHost = remoteHost
        initialRows = UInt16(clamping: rows)
        initialCols = UInt16(clamping: cols)
    }

    /// Kicks off connect → hello → attach in the background. The caller wires
    /// `onOutput`/`onExit` first; input arriving meanwhile is buffered.
    func start() {
        workQueue.async { [self] in
            do {
                let channel = try remoteHost.map(Termiod.Transport.ssh(host:))
                    ?? Termiod.Transport.local()
                transport = channel
                try Termiod.performHello(channel, role: "attach", caps: ["snapshot"])
                let payload = try Termiod.attachPayload(
                    target: sessionName,
                    specification: specification,
                    rows: pendingResize?.rows ?? initialRows,
                    cols: pendingResize?.cols ?? initialCols
                )
                try Termiod.writeFrame(channel.writeDescriptor, kind: .control, payload: payload)
                let reply = try Termiod.readFrame(channel.readDescriptor)
                guard reply.kind == .control,
                      case .attached(let attachedPayload) = try Termiod.decodeControl(reply.payload)
                else {
                    throw TermiodClientError.handshakeRejected("attach was not acknowledged")
                }
                attached = true
                isWriter = attachedPayload.writer
                Log.termiod.info("""
                attached session=\(self.sessionName, privacy: .public) \
                host=\(self.remoteHost ?? "local", privacy: .public) \
                writer=\(attachedPayload.writer, privacy: .public) \
                \(attachedPayload.rows, privacy: .public)x\(attachedPayload.cols, privacy: .public)
                """)
                if let resize = pendingResize, isWriter {
                    try Termiod.writeFrame(channel.writeDescriptor, kind: .resize,
                                           payload: Self.resizePayload(resize.rows, resize.cols))
                }
                pendingResize = nil
                // Only a writer may inject the keystrokes buffered during connect;
                // an observer's input would be rejected frame-by-frame by the
                // daemon. (This client always attaches `interact` today, so it is
                // normally the writer — this keeps it correct if observe is used.)
                if isWriter, !pendingInput.isEmpty {
                    try sendDataLocked(pendingInput)
                }
                pendingInput.removeAll(keepingCapacity: false)
                startReader(channel.readDescriptor)
            } catch {
                Log.termiod.error("""
                attach session=\(self.sessionName, privacy: .public) failed: \
                \(error.localizedDescription, privacy: .public)
                """)
                teardownLocked()
                deliverExitLocked(status: 1)
            }
        }
    }

    func send(_ data: Data) {
        guard !data.isEmpty else { return }
        workQueue.async { [self] in
            guard !closed else { return }
            guard attached else {
                pendingInput.append(data)
                return
            }
            do {
                try sendDataLocked(data)
            } catch {
                Log.termiod.error("""
                input write to \(self.sessionName, privacy: .public) failed: \
                \(error.localizedDescription, privacy: .public)
                """)
            }
        }
    }

    func resize(rows: Int, cols: Int) {
        let size = (rows: UInt16(clamping: rows), cols: UInt16(clamping: cols))
        workQueue.async { [self] in
            guard !closed else { return }
            guard attached else {
                pendingResize = size
                return
            }
            // Observers must not resize the shared PTY out from under the
            // writer; the daemon would reject the frame anyway.
            guard isWriter, let transport else { return }
            do {
                try Termiod.writeFrame(transport.writeDescriptor, kind: .resize,
                                       payload: Self.resizePayload(size.rows, size.cols))
            } catch {
                Log.termiod.error("""
                resize of \(self.sessionName, privacy: .public) failed: \
                \(error.localizedDescription, privacy: .public)
                """)
            }
        }
    }

    /// Leaves the stream but keeps the session alive in the daemon — the
    /// app-quit and surface-teardown path. Synchronous so `applicationWillTerminate`
    /// can rely on the detach frame being out before the process dies.
    func detach() {
        workQueue.sync { [self] in
            guard !closed, let transport else {
                closed = true
                return
            }
            if let payload = try? Termiod.detachPayload() {
                try? Termiod.writeFrame(transport.writeDescriptor, kind: .control, payload: payload)
            }
            teardownLocked()
        }
    }

    /// The destroy verb: asks the daemon to kill the session, then closes.
    func killAndClose() {
        Termiod.killSession(target: sessionName, host: remoteHost)
        workQueue.async { [self] in
            teardownLocked()
        }
    }

    private func sendDataLocked(_ data: Data) throws {
        guard let transport else { return }
        var offset = 0
        while offset < data.count {
            let end = min(offset + Termiod.maximumDataFrameSize, data.count)
            try Termiod.writeFrame(transport.writeDescriptor, kind: .data,
                                   payload: data.subdata(in: offset ..< end))
            offset = end
        }
    }

    private static func resizePayload(_ rows: UInt16, _ cols: UInt16) -> Data {
        var payload = Data(capacity: 4)
        var bigEndianRows = rows.bigEndian
        var bigEndianCols = cols.bigEndian
        withUnsafeBytes(of: &bigEndianRows) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: &bigEndianCols) { payload.append(contentsOf: $0) }
        return payload
    }

    private func teardownLocked() {
        closed = true
        transport?.close()
        transport = nil
    }

    /// Must run on `workQueue` — `exitDelivered` is queue-confined state.
    private func deliverExitLocked(status: Int32) {
        guard !exitDelivered else { return }
        exitDelivered = true
        let runtimeMilliseconds = UInt64(max(0, Date().timeIntervalSince(startedAt) * 1000))
        DispatchQueue.main.async { [self] in
            onExit?(status, runtimeMilliseconds)
        }
    }

    /// Dedicated blocking-read thread (the frame stream has no natural
    /// dispatch-source shape once payloads span multiple reads). Ends on EOF,
    /// error, or the session's exit notice.
    private func startReader(_ socket: Int32) {
        let thread = Thread { [weak self] in
            while true {
                let frame: (kind: Termiod.FrameKind, payload: Data)
                do {
                    frame = try Termiod.readFrame(socket)
                } catch {
                    self?.handleStreamEnd()
                    return
                }
                guard let self else { return }
                switch frame.kind {
                case .data:
                    self.onOutput?(frame.payload)
                case .snapshot:
                    // The daemon guarantees `S` before any post-attach `D`, and
                    // this reader is a single serial thread: synthesising the
                    // repaint and emitting it here — before the next `readFrame`
                    // pulls the first live `D` — preserves S-before-D through
                    // the same `onOutput` seam, with no hold-back buffer needed.
                    // A mid-session `S` (the resize barrier's fresh keyframe)
                    // takes the same path and repaints idempotently.
                    if let repaint = TermiodSnapshot.decode(frame.payload)
                        .map(TermiodSnapshot.render) {
                        self.onOutput?(repaint)
                    } else {
                        Log.termiod.error("""
                        undecodable snapshot frame on \(self.sessionName, privacy: .public)
                        """)
                    }
                case .control:
                    if self.handleControl(frame.payload) { return }
                case .event, .resize, .history, .grid:
                    // `ready` (an `E` event) marks snapshot-complete but needs no
                    // action — serial ordering already sequences S then D. The
                    // rest is unnegotiated in this slice and safe to skip.
                    break
                }
            }
        }
        thread.name = "termiod-read-\(sessionName.prefix(8))"
        thread.start()
    }

    /// Returns true when the reader should stop (the session is over).
    private func handleControl(_ payload: Data) -> Bool {
        let control: Termiod.IncomingControl
        do {
            control = try Termiod.decodeControl(payload)
        } catch {
            Log.termiod.error("""
            undecodable control frame on \(self.sessionName, privacy: .public): \
            \(error.localizedDescription, privacy: .public)
            """)
            return false
        }
        switch control {
        case .exited(let exit):
            workQueue.async { [self] in
                teardownLocked()
                deliverExitLocked(status: exit.status)
            }
            return true
        case .error(let failure):
            Log.termiod.error("""
            daemon error on \(self.sessionName, privacy: .public): \
            \(failure.message, privacy: .public)
            """)
            return false
        default:
            return false
        }
    }

    /// EOF or read error. After a deliberate detach/kill this is expected and
    /// silent; otherwise the daemon went away, and the session is marked
    /// exited so the pane doesn't sit live-looking but dead.
    private func handleStreamEnd() {
        workQueue.async { [self] in
            let wasDeliberate = closed
            teardownLocked()
            guard !wasDeliberate else { return }
            Log.termiod.error("connection to \(self.sessionName, privacy: .public) ended unexpectedly")
            deliverExitLocked(status: 1)
        }
    }
}
