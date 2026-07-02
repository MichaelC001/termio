import Foundation
import TermioShared

/// Receives the live project/session roster from the Mac companion server over
/// a WebSocket, so the home tree shows the same list the desktop sidebar does.
/// Step 1 is read-only; opening a session's PTY over the same link comes later.
final class CompanionClient: NSObject {
    private let url: URL
    private var task: URLSessionWebSocketTask?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    /// Latest roster, delivered on the main queue.
    var onRoster: (([RosterProject]) -> Void)?
    /// `true` once connected, `false` on drop — delivered on the main queue.
    var onConnected: ((Bool) -> Void)?

    init(url: URL) {
        self.url = url
    }

    func start() {
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receive()
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
                if case .string(let text) = message, let roster = CompanionRoster.decode(text) {
                    DispatchQueue.main.async { self.onRoster?(roster.projects) }
                }
                receive()
            case .failure:
                DispatchQueue.main.async { self.onConnected?(false) }
            }
        }
    }
}

extension CompanionClient: URLSessionWebSocketDelegate {
    func urlSession(_: URLSession, webSocketTask _: URLSessionWebSocketTask, didOpenWithProtocol _: String?) {
        DispatchQueue.main.async { self.onConnected?(true) }
    }

    func urlSession(_: URLSession, webSocketTask _: URLSessionWebSocketTask,
                    didCloseWith _: URLSessionWebSocketTask.CloseCode, reason _: Data?) {
        DispatchQueue.main.async { self.onConnected?(false) }
    }
}
