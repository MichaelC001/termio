import Darwin
import Foundation

/// A PTY that termio owns, running one child process (an agent command or a
/// login shell). Replaces libghostty's `.exec` backend so termio holds the byte
/// stream itself: PTY output fans out to every attached sink (the local surface,
/// and — later — a phone), and input from any of them is written back.
///
/// The child is spawned as a session leader with the slave as its controlling
/// terminal (`POSIX_SPAWN_SETSID` + opening the pts inside the child), so job
/// control and signals (Ctrl-C → SIGINT to the foreground group) work exactly
/// as under a real terminal.
final class PTYProcess: @unchecked Sendable {
    /// How much recent raw output is kept for replay to late-attaching sinks
    /// (a phone connecting mid-session). Bounded so an long-lived chatty agent
    /// can't grow memory without limit.
    private static let replayCapacity = 1 << 20 // 1 MB

    private struct Sink {
        /// Serial queue the handler is dispatched on; nil = called inline on
        /// the read pump (only for cheap, never-blocking consumers like the
        /// local surface — a networked consumer MUST bring its own queue so a
        /// slow send can't stall the local terminal).
        let queue: DispatchQueue?
        let handler: (Data) -> Void
    }

    private let masterFD: Int32
    private(set) var pid: pid_t = -1
    private var readSource: DispatchSourceRead?
    private var sinks: [UUID: Sink] = [:]
    private var replayBuffer = Data()
    private var lastCols: Int
    private var lastRows: Int
    private var exitObservers: [(Int32) -> Void] = []
    private var terminated = false
    private let lock = NSLock()

    /// Fired (on the main queue) when the child exits.
    var onExit: ((Int32) -> Void)?

    /// Spawns `argv` in `cwd` with `env` overrides at an initial `cols`×`rows`.
    /// Returns nil if the PTY or the process could not be created.
    init?(argv: [String], cwd: String, env: [String: String], cols: Int, rows: Int) {
        lastCols = cols
        lastRows = rows
        var master: Int32 = 0
        var slave: Int32 = 0
        var win = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        var nameBuf = [CChar](repeating: 0, count: 128)
        guard openpty(&master, &slave, &nameBuf, nil, &win) == 0 else {
            NSLog("[pty] openpty failed")
            return nil
        }
        masterFD = master
        let slavePath = String(cString: nameBuf)

        // Build the child's file actions and attributes: new session, and open
        // the pts as fd 0 inside the child (as session leader, no O_NOCTTY →
        // it becomes the controlling terminal), then dup onto stdout/stderr.
        var fileActions = posix_spawn_file_actions_t(nil as OpaquePointer?)
        posix_spawn_file_actions_init(&fileActions)
        // Run the child in the session's working directory.
        posix_spawn_file_actions_addchdir_np(&fileActions, cwd)
        posix_spawn_file_actions_addopen(&fileActions, 0, slavePath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&fileActions, 0, 1)
        posix_spawn_file_actions_adddup2(&fileActions, 0, 2)

        var attr = posix_spawnattr_t(nil as OpaquePointer?)
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

        // argv / envp as C string arrays.
        let argvC = argv.map { strdup($0) } + [nil]
        let envp = env.map { "\($0.key)=\($0.value)" }
        let envpC = envp.map { strdup($0) } + [nil]
        defer {
            argvC.forEach { free($0) }
            envpC.forEach { free($0) }
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attr)
        }

        var childPID: pid_t = 0
        let rc = posix_spawn(&childPID, argv[0], &fileActions, &attr, argvC, envpC)
        close(slave)
        guard rc == 0 else {
            NSLog("[pty] posix_spawn failed rc=\(rc)")
            close(master)
            return nil
        }
        pid = childPID

        // Reap the child asynchronously to fire onExit + observers.
        DispatchQueue.global().async { [weak self] in
            var status: Int32 = 0
            waitpid(childPID, &status, 0)
            let code = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
            DispatchQueue.main.async {
                guard let self else { return }
                self.onExit?(Int32(code))
                self.lock.lock()
                let observers = self.exitObservers
                self.lock.unlock()
                for observer in observers { observer(Int32(code)) }
            }
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: .global())
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 65536)
            let n = read(masterFD, &buffer, buffer.count)
            if n > 0 {
                let data = Data(buffer[0 ..< n])
                lock.lock()
                replayBuffer.append(data)
                if replayBuffer.count > Self.replayCapacity {
                    replayBuffer.removeFirst(replayBuffer.count - Self.replayCapacity)
                }
                let current = Array(sinks.values)
                lock.unlock()
                for sink in current {
                    if let queue = sink.queue {
                        queue.async { sink.handler(data) }
                    } else {
                        sink.handler(data)
                    }
                }
            } else if n <= 0 {
                self.readSource?.cancel()
            }
        }
        source.resume()
        readSource = source
    }

    /// Register an output sink; returns a token to remove it later.
    ///
    /// - Parameters:
    ///   - queue: a **serial** queue the handler runs on. Pass nil only for
    ///     cheap in-process consumers (the local surface); anything that can
    ///     block (network) must bring a queue so it never stalls the read pump.
    ///   - replayingBuffer: when true, the recent-output ring buffer is
    ///     delivered to this sink first, so a late-attaching client paints the
    ///     current screen instead of joining blind. Enqueued under the same
    ///     lock as live delivery, so replay/live ordering is preserved.
    @discardableResult
    func addSink(
        on queue: DispatchQueue? = nil,
        replayingBuffer: Bool = false,
        _ handler: @escaping (Data) -> Void
    ) -> UUID {
        let id = UUID()
        lock.lock()
        if replayingBuffer, !replayBuffer.isEmpty {
            let replay = replayBuffer
            if let queue {
                queue.async { handler(replay) }
            } else {
                handler(replay)
            }
        }
        sinks[id] = Sink(queue: queue, handler: handler)
        lock.unlock()
        return id
    }

    func removeSink(_ id: UUID) {
        lock.lock()
        sinks[id] = nil
        lock.unlock()
    }

    /// Observe child exit (in addition to `onExit`, which the store owns).
    /// Fired on the main queue.
    func addExitObserver(_ observer: @escaping (Int32) -> Void) {
        lock.lock()
        exitObservers.append(observer)
        lock.unlock()
    }

    func write(_ data: Data) {
        data.withUnsafeBytes { raw in
            _ = Darwin.write(masterFD, raw.baseAddress, raw.count)
        }
    }

    func resize(cols: Int, rows: Int) {
        lock.lock()
        lastCols = cols
        lastRows = rows
        lock.unlock()
        var win = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, TIOCSWINSZ, &win)
    }

    /// Force a full-screen repaint from TUI apps by delivering a spurious
    /// SIGWINCH (shrink one row, restore). Used after a replay or after a
    /// slow client dropped frames, so the child redraws its current state.
    func jiggleResize() {
        lock.lock()
        let cols = lastCols
        let rows = lastRows
        lock.unlock()
        var shrunk = winsize(ws_row: UInt16(max(rows - 1, 1)), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, TIOCSWINSZ, &shrunk)
        // A beat between the two so the child observes both changes. The
        // terminated check keeps the delayed ioctl off a recycled fd number.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let dead = self.terminated
            self.lock.unlock()
            guard !dead else { return }
            var win = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(self.masterFD, TIOCSWINSZ, &win)
        }
    }

    func terminate() {
        lock.lock()
        terminated = true
        lock.unlock()
        readSource?.cancel()
        if pid > 0 { kill(pid, SIGTERM) }
        close(masterFD)
    }
}
