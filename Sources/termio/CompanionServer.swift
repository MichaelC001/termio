import Foundation
import Network
import TermioShared

/// Serves the project/session roster to the iOS companion app over a WebSocket,
/// so the phone shows the same list the sidebar does. Step 1 is read-only: on
/// connect and whenever the store changes, it pushes a `CompanionRoster`. (A
/// later step bridges an individual session's PTY over the same connection.)
///
/// Bound to localhost for the PoC; production fronts it with a tunnel
/// (`tunelo port <n>`), so the socket itself never listens on the public net.
@MainActor
final class CompanionServer {
    private let port: UInt16
    private let rosterProvider: () -> CompanionRoster
    private var listener: NWListener?
    private var connections: Set<ObjectIdentifier> = []
    private var connectionByID: [ObjectIdentifier: NWConnection] = [:]
    private var lastRoster: CompanionRoster?
    private var pollTimer: Timer?

    init(port: UInt16 = 8787, rosterProvider: @escaping () -> CompanionRoster) {
        self.port = port
        self.rosterProvider = rosterProvider
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
        // churn is low.
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.broadcastIfChanged() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stop() {
        pollTimer?.invalidate()
        listener?.cancel()
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
        connectionByID[id]?.cancel()
        connectionByID[id] = nil
        connections.remove(id)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] _, _, _, error in
            if error != nil {
                Task { @MainActor in self?.drop(ObjectIdentifier(connection)) }
                return
            }
            self?.receive(on: connection)
        }
    }

    private func broadcastIfChanged() {
        guard !connectionByID.isEmpty else { return }
        let roster = rosterProvider()
        guard roster != lastRoster else { return }
        lastRoster = roster
        for connection in connectionByID.values { send(roster, to: connection) }
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
