import Foundation
import TermioShared

/// v1 companion transport: a WebSocket to the Mac companion server (directly on
/// LAN, or via a tunnel URL). Binary frames are raw PTY bytes; text frames are
/// `CompanionControl` JSON. Same byte-source shape as `SSHTerminalClient`, so
/// `TerminalViewController` bridges it to `InMemoryTerminalSession` the same way.
///
/// E2E encryption (CryptoKit) wraps the payloads in the next pass; the PoC
/// proves the transport + PTY bridge first.
final class CompanionTransport: NSObject {
    enum State {
        case connecting
        case connected
        case failed(String)
        case closed
    }

    private let url: URL
    /// Roster session id to bridge; sent as an `attach` control the moment the
    /// socket opens. nil connects to a server that streams without attach
    /// (the standalone companion PoC).
    private let attachSessionID: String?
    private var task: URLSessionWebSocketTask?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    /// Remote PTY bytes for the terminal. Fired on a URLSession queue.
    var onOutput: ((Data) -> Void)?
    /// State transitions, delivered on the main queue.
    var onState: ((State) -> Void)?

    init(url: URL, attachSessionID: String? = nil) {
        self.url = url
        self.attachSessionID = attachSessionID
    }

    func start() {
        notify(.connecting)
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receive()
    }

    func send(_ data: Data) {
        task?.send(.data(data)) { _ in }
    }

    func resize(cols: Int, rows: Int) {
        let control = CompanionControl.resize(cols: cols, rows: rows).encoded()
        task?.send(.string(control)) { _ in }
    }

    func stop() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .data(let data):
                    onOutput?(data)
                case .string(let text):
                    switch CompanionControl.decode(text) {
                    case .exit:
                        notify(.closed)
                    case .error(let message):
                        notify(.failed(message))
                    default:
                        break // roster frames and echoes are not for this link
                    }
                @unknown default:
                    break
                }
                receive()
            case .failure(let error):
                notify(.failed(error.localizedDescription))
            }
        }
    }

    private func notify(_ state: State) {
        DispatchQueue.main.async { [onState] in onState?(state) }
    }
}

extension CompanionTransport: URLSessionWebSocketDelegate {
    func urlSession(_: URLSession, webSocketTask _: URLSessionWebSocketTask,
                    didOpenWithProtocol _: String?) {
        if let attachSessionID {
            let attach = CompanionControl.attach(sessionID: attachSessionID).encoded()
            task?.send(.string(attach)) { _ in }
        }
        notify(.connected)
    }

    func urlSession(_: URLSession, webSocketTask _: URLSessionWebSocketTask,
                    didCloseWith _: URLSessionWebSocketTask.CloseCode, reason _: Data?) {
        notify(.closed)
    }
}
