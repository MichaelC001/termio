import Foundation
import Network
import TermioShared

/// Serves the iOS companion app over WebSockets on one port: every connection
/// starts as a roster subscriber (the same project/session tree the sidebar
/// shows, pushed on connect and on change); a connection that sends an
/// `attach` control message becomes a PTY bridge for that session — binary
/// frames carry raw PTY bytes both ways, text frames carry `CompanionControl`.
///
/// Bound to localhost for the PoC; production fronts it with a tunnel
/// (`tunelo port <n>`), so the socket itself never listens on the public net.
@MainActor
final class CompanionServer {
    private let port: UInt16
    private let rosterProvider: () -> CompanionRoster
    private let ptyForSession: (String) -> PTYProcess?
    private var listener: NWListener?
    private var connections: Set<ObjectIdentifier> = []
    private var connectionByID: [ObjectIdentifier: NWConnection] = [:]
    private var bridges: [ObjectIdentifier: PTYBridge] = [:]
    private var lastRoster: CompanionRoster?
    private var pollTimer: Timer?
    private var ticks = 0

    init(
        port: UInt16 = 8787,
        rosterProvider: @escaping () -> CompanionRoster,
        ptyForSession: @escaping (String) -> PTYProcess?
    ) {
        self.port = port
        self.rosterProvider = rosterProvider
        self.ptyForSession = ptyForSession
    }

    func start() {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)

        guard let listener = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!) else {
            NSLog("[companion] failed to bind port \(port)")
            return
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.stateUpdateHandler = { state in
            if case .ready = state { NSLog("[companion] listening on ws://localhost:\(self.port)") }
        }
        listener.start(queue: .main)
        self.listener = listener

        // Poll the store on a light cadence and broadcast only on change; simpler
        // and race-free next to hooking every @Published property, and roster
        // churn is low. The same timer paces the keepalive pings.
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func tick() {
        broadcastIfChanged()
        ticks += 1
        // Active pings (autoReplyPing only answers the peer's): keeps NAT /
        // proxy mappings warm and surfaces half-dead links within ~20s.
        if ticks % 20 == 0 {
            let meta = NWProtocolWebSocket.Metadata(opcode: .ping)
            let context = NWConnection.ContentContext(identifier: "ping", metadata: [meta])
            for connection in connectionByID.values {
                connection.send(content: Data("hb".utf8), contentContext: context, completion: .idempotent)
            }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        listener?.cancel()
        for bridge in bridges.values { bridge.stop() }
        bridges.removeAll()
        for connection in connectionByID.values { connection.cancel() }
        connectionByID.removeAll()
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections.insert(id)
        connectionByID[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                Task { @MainActor in self?.drop(id) }
            default:
                break
            }
        }
        connection.start(queue: .main)
        // Send the current roster straight away so the phone paints immediately.
        send(rosterProvider(), to: connection)
        // Keep the receive pump alive so pings/close are handled.
        receive(on: connection)
    }

    private func drop(_ id: ObjectIdentifier) {
        bridges[id]?.stop()
        bridges[id] = nil
        connectionByID[id]?.cancel()
        connectionByID[id] = nil
        connections.remove(id)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, context, _, error in
            if error != nil {
                Task { @MainActor in self?.drop(ObjectIdentifier(connection)) }
                return
            }
            let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            if let meta, let content, !content.isEmpty {
                switch meta.opcode {
                case .binary:
                    // Keystrokes from the phone into the session's PTY.
                    Task { @MainActor in
                        self?.bridges[ObjectIdentifier(connection)]?.pty.write(content)
                    }
                case .text:
                    if let text = String(data: content, encoding: .utf8),
                       let control = CompanionControl.decode(text) {
                        Task { @MainActor in self?.handle(control, on: connection) }
                    }
                default:
                    break
                }
            }
            self?.receive(on: connection)
        }
    }

    private func handle(_ control: CompanionControl, on connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        switch control {
        case .attach(let sessionID):
            guard let pty = ptyForSession(sessionID) else {
                sendControl(.error(message: "session has no live terminal on the Mac"), to: connection)
                return
            }
            bridges[id]?.stop()
            let bridge = PTYBridge(pty: pty, connection: connection)
            bridges[id] = bridge
            bridge.start()
            pty.addExitObserver { [weak self, weak connection] code in
                guard let connection else { return }
                Task { @MainActor in
                    self?.sendControl(.exit(code: code), to: connection)
                    self?.drop(ObjectIdentifier(connection))
                }
            }
        case .resize(let cols, let rows):
            // Last writer wins, like tmux's newest-client rule — v1 mirrors
            // one PTY, it does not maintain per-client grids.
            bridges[id]?.pty.resize(cols: cols, rows: rows)
        case .exit, .error:
            break
        }
    }

    private func sendControl(_ control: CompanionControl, to connection: NWConnection) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "control", metadata: [meta])
        connection.send(
            content: Data(control.encoded().utf8),
            contentContext: context,
            completion: .idempotent
        )
    }

    private func broadcastIfChanged() {
        guard !connectionByID.isEmpty else { return }
        let roster = rosterProvider()
        guard roster != lastRoster else { return }
        lastRoster = roster
        // Bridged connections are a byte stream now; roster frames would only
        // interleave with PTY traffic for no benefit.
        for (id, connection) in connectionByID where bridges[id] == nil {
            send(roster, to: connection)
        }
    }

    private func send(_ roster: CompanionRoster, to connection: NWConnection) {
        lastRoster = roster
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "roster", metadata: [meta])
        connection.send(
            content: Data(roster.encodedJSON().utf8),
            contentContext: context,
            completion: .idempotent
        )
    }
}

// MARK: - PTY bridge

/// One phone ↔ one session PTY. Output is tapped via a PTYProcess sink on a
/// private serial queue, so a slow phone can never stall the Mac's terminal;
/// if the socket falls more than `highWater` behind, frames are dropped and a
/// resize jiggle repaints the screen once the pipe drains (catch-up snapshot,
/// not a minutes-long fast-forward).
private final class PTYBridge: @unchecked Sendable {
    let pty: PTYProcess
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "termio.companion.bridge")
    private var sinkToken: UUID?
    private let lock = NSLock()
    private var pendingBytes = 0
    private var behind = false
    private static let highWater = 1 << 20   // start dropping above 1 MB in flight
    private static let lowWater = 128 << 10  // recovered once under 128 KB

    init(pty: PTYProcess, connection: NWConnection) {
        self.pty = pty
        self.connection = connection
    }

    func start() {
        sinkToken = pty.addSink(on: queue, replayingBuffer: true) { [weak self] data in
            self?.send(data)
        }
        // The replayed buffer ends wherever the last write happened; a spurious
        // SIGWINCH makes TUI apps repaint so the phone shows the live screen.
        pty.jiggleResize()
    }

    func stop() {
        if let token = sinkToken { pty.removeSink(token) }
        sinkToken = nil
    }

    private func send(_ data: Data) {
        lock.lock()
        if pendingBytes > Self.highWater {
            behind = true
            lock.unlock()
            return
        }
        pendingBytes += data.count
        lock.unlock()
        let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "pty", metadata: [meta])
        connection.send(
            content: data,
            contentContext: context,
            completion: .contentProcessed { [weak self] _ in
                guard let self else { return }
                lock.lock()
                pendingBytes -= data.count
                let recovered = behind && pendingBytes < Self.lowWater
                if recovered { behind = false }
                lock.unlock()
                if recovered { pty.jiggleResize() }
            }
        )
    }
}

// MARK: - Store → roster

extension TermioStore {
    /// Snapshot the current projects/sessions as a wire roster, mirroring what
    /// the sidebar renders (display titles, live agent status).
    func companionRoster() -> CompanionRoster {
        let projects = self.projects.map { project in
            RosterProject(
                id: project.id.uuidString,
                name: project.name,
                path: project.path,
                sessions: project.sessions.map { session in
                    RosterSession(
                        id: session.id.uuidString,
                        title: displayTitle(for: session),
                        agent: Self.wireAgent(session.agent),
                        status: Self.wireStatus(status(for: session.id))
                    )
                }
            )
        }
        return CompanionRoster(projects: projects)
    }

    private static func wireAgent(_ agent: AgentPreset) -> String {
        switch agent {
        case .claudeCode: "claude"
        case .codex: "codex"
        case .opencode: "opencode"
        case .terminal: "terminal"
        case .pi: "opencode"
        }
    }

    private static func wireStatus(_ status: SessionStatus) -> String {
        switch status {
        case .idle: "idle"
        case .working: "working"
        case .done: "done"
        case .needsAttention: "needsAttention"
        }
    }
}
