import Foundation
import TermioShared

/// One WebSocket speaking the termiod Session Protocol, and the only place the
/// phone turns a stream of bytes back into frames.
///
/// The daemon's listener is a splice, not a second protocol: it copies the same
/// framed stream a Unix socket carries into binary messages of whatever size its
/// copy loop happened to read. So a WebSocket message boundary means nothing
/// here — one message may hold three frames or a third of one, and
/// `Termiod.FrameReader` is what cuts them apart. The Mac's `Termiod.readFrame`
/// pulls exactly what a header asks for from a blocking descriptor and has no
/// equivalent on this side.
///
/// Everything link-shaped — dialling, backoff, the liveness ping, the
/// foreground retry — belongs to `WebSocketLink`. What lives here is the
/// protocol: the `hello` that must be frame #1, the reassembly, and the decode.
final class TermiodChannel {
    /// One control frame, and the request it is an answer to.
    ///
    /// The two travel together because the `re` lives on the payload rather than
    /// on any decoded case: `decodeControl` throws it away, so reading it after
    /// the decode is impossible and reading it before is the only option. A pair
    /// rather than a second closure argument because both halves need naming —
    /// an unlabelled `UInt64?` at a call site says nothing about which direction
    /// it points.
    struct Reply {
        /// The `seq` the answered request was sent with. `nil` for a frame that
        /// answers nobody, and for a daemon too old to stamp its replies.
        let responseID: UInt64?
        let control: Termiod.IncomingControl
    }

    /// The daemon answered the handshake. Fired on the link's delegate queue,
    /// which is where the frames behind it arrive too, so an owner replying from
    /// here keeps its reply ahead of everything else it sends.
    var onReady: ((Termiod.HelloOkPayload) -> Void)?
    /// A decoded control frame and the request it answers, on the delegate
    /// queue.
    var onControl: ((Reply) -> Void)?
    /// A decoded `E` frame, on the delegate queue.
    var onEvent: ((Termiod.IncomingEvent) -> Void)?
    /// Raw PTY bytes (`D`), on the delegate queue.
    var onData: ((Data) -> Void)?
    /// A snapshot keyframe (`S`) payload, on the delegate queue.
    var onSnapshot: ((Data) -> Void)?
    /// A file chunk (`F`) payload, on the delegate queue.
    var onFileChunk: ((Data) -> Void)?
    /// The link came up (`true`, meaning the handshake landed) or went down
    /// (`false`). `true` arrives on the delegate queue, immediately ahead of
    /// `onReady`; `false` arrives on the main queue, where the link schedules
    /// its own reconnect. An owner whose delegate queue is the main queue sees
    /// both there.
    var onLinkState: ((Bool) -> Void)?
    /// The device refused this connection outright — a rejected handshake, a
    /// stream that lost alignment. Main queue; the reason has to survive the
    /// reconnect loop or it reads as an unexplained outage.
    var onFailure: ((String) -> Void)?

    /// The client id `hello_ok` named this connection, which is the only way to
    /// tell whether a `writer_changed` naming a client means us.
    private(set) var clientID: String?
    /// The device's home directory, for the verbs that must name a path over
    /// there. Empty until the handshake lands.
    private(set) var homeDirectory = "/"

    private let name: String
    private let role: String
    private let capabilities: [String]
    private let link: WebSocketLink
    /// Delegate-queue only, and reset on every dial: a socket that died
    /// mid-frame leaves bytes that mean nothing to the next one.
    private var reader = Termiod.FrameReader()

    init(
        endpoint: DeviceEndpoint,
        name: String,
        role: String,
        capabilities: [String],
        delegateQueue: OperationQueue?,
        pingRunLoopMode: RunLoop.Mode = .default
    ) {
        self.name = name
        self.role = role
        self.capabilities = capabilities
        var configuration = WebSocketLink.Configuration(
            name: name, url: endpoint.url, delegateQueue: delegateQueue,
            pingRunLoopMode: pingRunLoopMode
        )
        // D3: the token rides the negotiated subprotocol. A query string on the
        // Upgrade line is the proxy-log leak the daemon's listener exists to
        // close, so it is never put back here.
        if let token = endpoint.token {
            configuration.subprotocols = ["termiod.\(token)"]
        }
        // D2: the listener's CSRF check refuses a missing Origin, and
        // `URLSession` sends none from a native app. The phone states the
        // operator's own allowed origin — a value it chose, which is why the
        // token remains the only thing authenticating the pipe.
        if let origin = endpoint.origin {
            configuration.headers["Origin"] = origin
        }
        link = WebSocketLink(configuration: configuration)
        link.onConnecting = { [weak self] in self?.onLinkState?(false) }
        link.onOpen = { [weak self] in self?.sendHello() }
        link.onDown = { [weak self] in self?.onLinkState?(false) }
        link.onData = { [weak self] data in self?.receive(data) }
        link.onText = { [weak self] _ in
            // The protocol is binary end to end. A text frame means the peer is
            // not the daemon this channel was built for.
            Log.device.error("\(self?.name ?? "?", privacy: .public) channel got a text frame")
        }
    }

    var isUp: Bool { link.isUp }

    func start() { link.start() }

    func stop(closeCode: URLSessionWebSocketTask.CloseCode = .goingAway) {
        link.stop(closeCode: closeCode)
    }

    func reconnectNow() { link.reconnectNow() }

    func send(kind: Termiod.FrameKind, payload: Data) {
        link.send(Termiod.frame(kind: kind, payload: payload))
    }

    /// Encode and send one control operation. Throws rather than swallowing an
    /// encode failure: the caller is the one holding the request that will now
    /// never be answered, and it is the only place that knows what to say.
    func send(control operation: some Encodable) throws {
        send(kind: .control, payload: try Termiod.encodeControl(operation))
    }

    /// `hello` is frame #1 on every connect. `onOpen` fires inside
    /// `didOpenWithProtocol` on the delegate queue and `URLSession` preserves
    /// send order, so nothing the owner queues afterwards can overtake it.
    private func sendHello() {
        reader.reset()
        do {
            send(kind: .control, payload: try Termiod.helloPayload(
                role: role, caps: capabilities, client: Self.clientBanner))
        } catch {
            Log.device.error("""
            encoding hello for \(self.name, privacy: .public) failed: \
            \(error.localizedDescription, privacy: .public)
            """)
        }
    }

    private func receive(_ chunk: Data) {
        let frames: [(kind: Termiod.FrameKind, payload: Data)]
        do {
            frames = try reader.append(chunk)
        } catch {
            // Alignment is gone: every frame after this one would be read at a
            // garbage offset, so the connection is over rather than degraded.
            Log.device.error("""
            \(self.name, privacy: .public) channel lost frame alignment: \
            \(error.localizedDescription, privacy: .public)
            """)
            fail(localized("The device sent something Termio could not read."))
            return
        }
        for frame in frames {
            switch frame.kind {
            case .data: onData?(frame.payload)
            case .snapshot: onSnapshot?(frame.payload)
            case .file: onFileChunk?(frame.payload)
            case .control: receiveControl(frame.payload)
            case .event: receiveEvent(frame.payload)
            case .upload, .history, .grid, .resize:
                // `R` is client-to-host only, and `H`/`G` need capabilities this
                // client never offers. Receiving one means the daemon sent a
                // frame nobody asked for — say so rather than drop it silently.
                Log.device.error("""
                unnegotiated \(String(UnicodeScalar(frame.kind.rawValue)), privacy: .public) \
                frame on \(self.name, privacy: .public)
                """)
            }
        }
    }

    private func receiveControl(_ payload: Data) {
        let control: Termiod.IncomingControl
        do {
            control = try Termiod.decodeControl(payload)
        } catch {
            Log.device.error("""
            undecodable control on \(self.name, privacy: .public): \
            \(error.localizedDescription, privacy: .public)
            """)
            return
        }
        switch control {
        case .helloOk(let handshake):
            clientID = handshake.clientId
            homeDirectory = handshake.homeDirectory
            onLinkState?(true)
            onReady?(handshake)
        case .helloError(let reason):
            fail(reason)
        default:
            onControl?(Reply(
                responseID: Termiod.responseID(of: payload), control: control))
        }
    }

    private func receiveEvent(_ payload: Data) {
        do {
            onEvent?(try Termiod.decodeEvent(payload))
        } catch {
            Log.device.error("""
            undecodable event on \(self.name, privacy: .public): \
            \(error.localizedDescription, privacy: .public)
            """)
        }
    }

    private func fail(_ reason: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !link.isStopped else { return }
            link.stop(closeCode: .policyViolation)
            onFailure?(reason)
        }
    }

    /// What this client calls itself in `hello`. The shared codec deliberately
    /// does not supply one — claiming to be a particular client is the one thing
    /// a shared codec must not do.
    private static let clientBanner: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        return "termio-ios/\(version as? String ?? "dev")"
    }()
}
