import Foundation
import TermioShared
import UIKit

/// Receives the live project/session roster from the Mac companion server over
/// a WebSocket, so the home tree shows the same list the desktop sidebar does.
/// The link self-heals: any drop (Mac app restart, phone sleep, network blip)
/// schedules a backoff reconnect, and returning to the foreground retries at
/// once — a fresh connect repaints immediately because the server pushes the
/// full roster on accept.
final class CompanionClient: NSObject {
    private let url: URL
    private var task: URLSessionWebSocketTask?
    // Main-queue delegate so all state and callbacks stay on one queue.
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    private var stopped = true
    private var isConnected = false
    private var attempts = 0
    private var foregroundObserver: NSObjectProtocol?

    /// Latest roster, delivered on the main queue.
    var onRoster: (([RosterProject]) -> Void)?
    /// `true` once connected, `false` on drop — delivered on the main queue.
    var onConnected: ((Bool) -> Void)?

    init(url: URL) {
        self.url = url
    }

    deinit {
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func start() {
        stopped = false
        attempts = 0
        connect()
        if foregroundObserver == nil {
            foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                // Skip any pending backoff — the socket rarely survives a trip
                // to the background, and the user is looking at the list now.
                guard let self, !stopped, !isConnected else { return }
                attempts = 0
                connect()
            }
        }
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

    private func scheduleReconnect() {
        guard !stopped else { return }
        attempts += 1
        let delay = min(pow(2.0, Double(attempts - 1)), 15) // 1s, 2s, 4s … 15s
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !stopped, !isConnected else { return }
            connect()
        }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message, let roster = CompanionRoster.decode(text) {
                    onRoster?(roster.projects)
                }
                receive(on: task)
            case .failure:
                // A superseded task's death is not a drop of the current link.
                guard task === self.task else { return }
                isConnected = false
                onConnected?(false)
                scheduleReconnect()
            }
        }
    }
}

extension CompanionClient: URLSessionWebSocketDelegate {
    func urlSession(_: URLSession, webSocketTask task: URLSessionWebSocketTask, didOpenWithProtocol _: String?) {
        guard task === self.task else { return }
        isConnected = true
        attempts = 0
        onConnected?(true)
    }

    func urlSession(_: URLSession, webSocketTask task: URLSessionWebSocketTask,
                    didCloseWith _: URLSessionWebSocketTask.CloseCode, reason _: Data?) {
        guard task === self.task else { return }
        isConnected = false
        onConnected?(false)
    }
}
