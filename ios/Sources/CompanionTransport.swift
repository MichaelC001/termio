import Foundation
import TermioShared
import UIKit

/// v1 companion transport: a WebSocket to the Mac companion server (directly on
/// LAN, or via a tunnel URL). Binary frames are raw PTY bytes; text frames are
/// `CompanionControl` JSON. Same byte-source shape as `SSHTerminalClient`, so
/// `TerminalViewController` bridges it to `InMemoryTerminalSession` the same way.
///
/// The link self-heals: any socket drop (Mac app rebuild, phone sleep, network
/// blip) schedules a backoff reconnect and re-attaches, and the server replays
/// its ring buffer on attach so the screen repaints. Only a server-sent `exit`
/// (the session ended) or `error` (the session no longer exists — e.g. the Mac
/// app restarted) ends the loop.
///
/// E2E encryption (CryptoKit) wraps the payloads in the next pass; the PoC
/// proves the transport + PTY bridge first.
final class CompanionTransport: NSObject {
    enum State {
        case connecting
        case connected
        /// The socket dropped; a reconnect is scheduled. Not fatal.
        case reconnecting
        /// The server rejected us (e.g. the session died with a Mac restart). Fatal.
        case failed(String)
        /// The session exited on the Mac. Fatal.
        case closed
    }

    private let url: URL
    /// Roster session id to bridge; sent as an `attach` control the moment the
    /// socket opens. nil connects to a server that streams without attach
    /// (the standalone companion PoC).
    private let attachSessionID: String?
    private var task: URLSessionWebSocketTask?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    // Reconnect state, all touched on the main queue.
    private var stopped = true
    private var isConnected = false
    private var attempts = 0
    private var foregroundObserver: NSObjectProtocol?
    /// Only touched on the delegate queue (see `didOpen`).
    private var everConnected = false
    /// Last grid the terminal reported, re-sent on every (re)connect and on
    /// foreground: the first resize often fires before the socket exists and
    /// would be silently lost, a reconnect never re-fires it (the view's size
    /// didn't change), and each report claims the PTY's winsize for this
    /// device (the Mac may have taken it back while the app was away).
    private var gridCols = 0
    private var gridRows = 0
    private let gridLock = NSLock()

    /// Remote PTY bytes for the terminal. Fired on a URLSession queue.
    var onOutput: ((Data) -> Void)?
    /// State transitions, delivered on the main queue.
    var onState: ((State) -> Void)?

    init(url: URL, attachSessionID: String? = nil) {
        self.url = url
        self.attachSessionID = attachSessionID
    }

    deinit {
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func start() {
        stopped = false
        attempts = 0
        notify(.connecting)
        connect()
        if foregroundObserver == nil {
            foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self, !stopped else { return }
                if isConnected {
                    // The link survived the background trip; coming back to
                    // the app is still a claim — the Mac may have taken the
                    // winsize while we were away.
                    reassertGrid()
                } else {
                    // Skip any pending backoff — the user is looking at the
                    // screen now.
                    attempts = 0
                    connect()
                }
            }
        }
    }

    func send(_ data: Data) {
        task?.send(.data(data)) { _ in }
    }

    func resize(cols: Int, rows: Int) {
        gridLock.lock()
        gridCols = cols
        gridRows = rows
        gridLock.unlock()
        sendGrid()
    }

    /// Re-claims the PTY's winsize for this device — called when the user
    /// comes back to this screen (re-opening a parked session).
    func reassertGrid() {
        sendGrid()
    }

    private func sendGrid() {
        gridLock.lock()
        let cols = gridCols
        let rows = gridRows
        gridLock.unlock()
        guard cols > 0, rows > 0 else { return }
        let control = CompanionControl.resize(cols: cols, rows: rows).encoded()
        task?.send(.string(control)) { _ in }
    }

    func stop() {
        stopped = true
        isConnected = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
            foregroundObserver = nil
        }
    }

    private func connect() {
        guard !stopped else { return }
        task?.cancel(with: .goingAway, reason: nil)
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receive(on: task)
    }

    /// The socket died mid-session. Keep trying — the usual cause is the Mac
    /// app rebuilding, and re-attach is idempotent (the server replays the
    /// session's ring buffer to a fresh attach).
    private func dropped(_ task: URLSessionWebSocketTask) {
        DispatchQueue.main.async { [weak self] in
            // A superseded task's death is not a drop of the current link.
            guard let self, task === self.task, !stopped else { return }
            isConnected = false
            notify(.reconnecting)
            attempts += 1
            // Fast cadence with jitter: failed LAN connects are cheap, and the
            // win is noticing quickly when the Mac is back.
            let delay = min(0.5 * pow(2.0, Double(attempts - 1)), 5) * .random(in: 0.8...1.2)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !stopped, !isConnected else { return }
                connect()
            }
        }
    }

    /// A fatal control arrived — the session itself is over, stop reconnecting.
    private func finish(_ state: State) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !stopped else { return }
            stopped = true
            isConnected = false
            notify(state)
        }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .data(let data):
                    onOutput?(data)
                case .string(let text):
                    switch CompanionControl.decode(text) {
                    case .exit:
                        finish(.closed)
                    case .error(let message):
                        finish(.failed(message))
                    default:
                        break // roster frames and echoes are not for this link
                    }
                @unknown default:
                    break
                }
                receive(on: task)
            case .failure:
                dropped(task)
            }
        }
    }

    private func notify(_ state: State) {
        DispatchQueue.main.async { [onState] in onState?(state) }
    }
}

extension CompanionTransport: URLSessionWebSocketDelegate {
    func urlSession(_: URLSession, webSocketTask task: URLSessionWebSocketTask,
                    didOpenWithProtocol _: String?) {
        // On a REconnect the terminal still shows the dead link's screen; a
        // full reset (RIS) ahead of the server's ring-buffer replay keeps the
        // two byte streams from interleaving into garbage. Emitted here on the
        // serial delegate queue so it precedes the replayed bytes.
        if everConnected {
            onOutput?(Data("\u{1B}c".utf8))
        }
        everConnected = true
        if let attachSessionID {
            let attach = CompanionControl.attach(sessionID: attachSessionID).encoded()
            task.send(.string(attach)) { _ in }
        }
        // The grid must follow the attach on every connect — the server's
        // repaint of the freshly wiped screen is driven by this claim.
        sendGrid()
        DispatchQueue.main.async { [weak self] in
            guard let self, task === self.task, !stopped else { return }
            isConnected = true
            attempts = 0
            notify(.connected)
        }
    }

    func urlSession(_: URLSession, webSocketTask task: URLSessionWebSocketTask,
                    didCloseWith _: URLSessionWebSocketTask.CloseCode, reason _: Data?) {
        dropped(task)
    }
}
