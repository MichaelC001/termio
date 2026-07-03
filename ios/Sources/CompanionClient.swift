import Foundation
import Network
import TermioShared
import UIKit

/// Receives the live project/session roster from the Mac companion server over
/// a WebSocket, so the home tree shows the same list the desktop sidebar does.
/// The link self-heals: any drop (Mac app restart, phone sleep, network blip)
/// schedules a jittered backoff reconnect; returning to the foreground or the
/// network path coming back retries at once; and a periodic ping catches
/// half-open sockets that would otherwise never fail `receive`. A fresh
/// connect repaints immediately because the server pushes the full roster on
/// accept.
final class CompanionClient: NSObject {
    private let url: URL
    private var task: URLSessionWebSocketTask?
    // Main-queue delegate so all state and callbacks stay on one queue.
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    private var stopped = true
    private var isConnected = false
    private var attempts = 0
    private var foregroundObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    private var lastPathStatus: NWPath.Status?
    private var pingTimer: Timer?

    /// Latest roster, delivered on the main queue.
    var onRoster: (([RosterProject]) -> Void)?
    /// `true` once connected, `false` on drop — delivered on the main queue.
    var onConnected: ((Bool) -> Void)?
    /// A `start` we sent succeeded; the new session id is ready to attach.
    var onStarted: ((String) -> Void)?
    /// A directory listing arrived (reply to `.listFiles`).
    var onFileList: ((String, [WireFileEntry]) -> Void)?
    /// File contents arrived (reply to `.readFile`).
    var onFile: ((WireFile) -> Void)?
    /// A write we sent landed (reply to `.writeFile`): path + new mtime (ms).
    var onWritten: ((String, Int) -> Void)?
    /// An upload we sent landed (reply to `.upload`): absolute Mac path.
    var onUploaded: ((String) -> Void)?
    /// The server rejected a request (e.g. a failed `start`).
    var onError: ((String) -> Void)?

    /// Send a control message (e.g. `.start`) over the roster link.
    func send(_ control: CompanionControl) {
        task?.send(.string(control.encoded())) { _ in }
    }

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
        startPathMonitor()
        startPingTimer()
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
        pathMonitor?.cancel()
        pathMonitor = nil
        lastPathStatus = nil
        pingTimer?.invalidate()
        pingTimer = nil
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
            foregroundObserver = nil
        }
    }

    private func connect() {
        guard !stopped else { return }
        task?.cancel(with: .goingAway, reason: nil)
        let task = session.webSocketTask(with: url)
        // A `file` reply for a 1 MB source is ~1.4 MB of base64 JSON — past
        // the 1 MB default cap, which would kill the socket mid-read.
        task.maximumMessageSize = 8 << 20
        self.task = task
        task.resume()
        receive(on: task)
    }

    private func scheduleReconnect() {
        guard !stopped else { return }
        attempts += 1
        // Fast cadence with jitter, capped low: the usual outage is the Mac
        // app rebuilding, failed LAN connects are cheap, and the win is
        // noticing quickly when it's back.
        let delay = min(0.5 * pow(2.0, Double(attempts - 1)), 6) * .random(in: 0.8...1.2)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !stopped, !isConnected else { return }
            connect()
        }
    }

    /// Reconnect the instant the network path comes back (Wi-Fi rejoin, VPN
    /// toggle) instead of sitting out a scheduled backoff.
    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self, !stopped else { return }
            let cameUp = path.status == .satisfied
                && lastPathStatus != nil && lastPathStatus != .satisfied
            lastPathStatus = path.status
            guard cameUp, !isConnected else { return }
            attempts = 0
            connect()
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    /// A half-open socket (Mac slept, network switched under us) never fails
    /// `receive`; a periodic ping is what notices, and its failure forces the
    /// reconnect loop.
    private func startPingTimer() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self, !stopped, isConnected, let task else { return }
            task.sendPing { [weak self] error in
                guard error != nil else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, !stopped, task === self.task, isConnected else { return }
                    isConnected = false
                    onConnected?(false)
                    attempts = 0
                    connect()
                }
            }
        }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message {
                    if let roster = CompanionRoster.decode(text) {
                        onRoster?(roster.projects)
                    } else {
                        switch CompanionControl.decode(text) {
                        case .started(let sessionID): onStarted?(sessionID)
                        case .fileList(let path, let entries): onFileList?(path, entries)
                        case .file(let file): onFile?(file)
                        case .written(let path, let mtime): onWritten?(path, mtime)
                        case .uploaded(let path): onUploaded?(path)
                        case .error(let reason): onError?(reason)
                        default: break
                        }
                    }
                }
                receive(on: task)
            case .failure(let error):
                // A superseded task's death is not a drop of the current link.
                guard task === self.task else { return }
                NSLog("[companion] roster link dropped: %@", String(describing: error))
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
        NSLog("[companion] roster link connected to %@", url.absoluteString)
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
