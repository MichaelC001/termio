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
    /// Which device's grid the PTY is sized for. One PTY has one winsize and
    /// the child lays its output out for it, so two differently-sized viewers
    /// can't both fit — the size follows the device being used (tmux's
    /// newest-client rule): a companion claims by resizing (it reports its
    /// grid on attach, foreground, and layout) or typing; the host claims
    /// back by typing; a companion detach hands back.
    enum SizeOwner {
        case host
        case companion
    }

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

    /// DEC private modes a TUI sets once at startup (alternate screen, mouse
    /// reporting, bracketed paste, …). A late-attaching sink whose replay
    /// window no longer contains those set sequences would join believing the
    /// terminal is in its default state — its scroll gestures then move a
    /// nonexistent scrollback instead of being reported to the app as wheel
    /// events. The read pump tracks these so `addSink` can re-assert them.
    private static let trackedPrivateModes: Set<Int> = [
        25, 47, 1000, 1002, 1003, 1004, 1005, 1006, 1015, 1047, 1048, 1049, 2004, 2031,
    ]
    /// Modes that are ON in a fresh terminal; everything else defaults off.
    private static let defaultOnPrivateModes: Set<Int> = [25]
    /// Emission order: enter the alternate screen first so the cursor/mouse
    /// modes land in the screen the TUI is about to repaint into.
    private static let privateModeEmissionOrder = [
        1049, 1047, 47, 1048, 25, 1000, 1002, 1003, 1004, 1005, 1006, 1015, 2004, 2031,
    ]

    private enum ModeScanState {
        case idle
        case escape        // saw ESC
        case csi           // saw ESC [
        case privateParams // saw ESC [ ? — accumulating digits and semicolons
    }

    private let masterFD: Int32
    private(set) var pid: pid_t = -1
    private var readSource: DispatchSourceRead?
    private var sinks: [UUID: Sink] = [:]
    private var replayBuffer = Data()
    private var totalBytesRead = 0
    private var privateModeStates: [Int: (enabled: Bool, offset: Int)] = [:]
    private var modeScanState: ModeScanState = .idle
    private var modeScanParams: [Int] = []
    private var modeScanCurrent: Int?
    private var lastCols: Int
    private var lastRows: Int
    private var sizeOwner: SizeOwner = .host
    private var hostCols: Int
    private var hostRows: Int
    private var companionCols = 0
    private var companionRows = 0
    private var resizeObservers: [UUID: (Int, Int) -> Void] = [:]
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
        hostCols = cols
        hostRows = rows
        var master: Int32 = 0
        var slave: Int32 = 0
        var win = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        var nameBuf = [CChar](repeating: 0, count: 128)
        guard openpty(&master, &slave, &nameBuf, nil, &win) == 0 else {
            Log.pty.error("openpty failed")
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
            Log.pty.error("posix_spawn failed rc=\(rc, privacy: .public)")
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
                scanPrivateModesLocked(data)
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
    ///   - replayCap: when set, only the last `replayCap` bytes of the ring
    ///     buffer are replayed to this sink. The local surface passes nil (it
    ///     wants the full history); a memory-constrained network viewer (the
    ///     phone) caps it so the cold-attach reflow at its narrow grid can't
    ///     spike libghostty's allocator into its "non-functional" panic. Only
    ///     the leading bytes are dropped, so the worst case is a clipped top
    ///     line — and a mode change inside that dropped prefix isn't re-asserted,
    ///     which is why the cap is only used on the plain-shell path (alt-screen
    ///     TUIs skip the byte replay entirely and resync modes explicitly).
    @discardableResult
    func addSink(
        on queue: DispatchQueue? = nil,
        replayingBuffer: Bool = false,
        replayCap: Int? = nil,
        _ handler: @escaping (Data) -> Void
    ) -> UUID {
        let id = UUID()
        lock.lock()
        if replayingBuffer {
            // Replay first, then re-assert private modes whose set sequences
            // have already been evicted from the ring buffer — the client's
            // terminal must agree with the child about alternate screen and
            // mouse reporting, or its scroll input goes nowhere.
            var replay = replayCap.map { Data(replayBuffer.suffix($0)) } ?? replayBuffer
            replay.append(modeCatchUpPreambleLocked())
            if !replay.isEmpty {
                if let queue {
                    queue.async { handler(replay) }
                } else {
                    handler(replay)
                }
            }
        }
        sinks[id] = Sink(queue: queue, handler: handler)
        lock.unlock()
        return id
    }

    /// Byte-level scan for `ESC [ ? params h/l` (DECSET/DECRST), tolerant of
    /// sequences split across read chunks. Only tracked modes are recorded,
    /// along with the stream offset of their last change so the preamble can
    /// tell whether the replay window already carries the sequence.
    private func scanPrivateModesLocked(_ data: Data) {
        let chunkStart = totalBytesRead
        totalBytesRead += data.count
        for (index, byte) in data.enumerated() {
            switch modeScanState {
            case .idle:
                if byte == 0x1B { modeScanState = .escape }
            case .escape:
                modeScanState = byte == UInt8(ascii: "[") ? .csi : .idle
            case .csi:
                if byte == UInt8(ascii: "?") {
                    modeScanState = .privateParams
                    modeScanParams = []
                    modeScanCurrent = nil
                } else if byte == 0x1B {
                    modeScanState = .escape
                } else {
                    modeScanState = .idle
                }
            case .privateParams:
                switch byte {
                case UInt8(ascii: "0") ... UInt8(ascii: "9"):
                    modeScanCurrent = (modeScanCurrent ?? 0) * 10 + Int(byte - UInt8(ascii: "0"))
                case UInt8(ascii: ";"):
                    if let current = modeScanCurrent { modeScanParams.append(current) }
                    modeScanCurrent = nil
                case UInt8(ascii: "h"), UInt8(ascii: "l"):
                    if let current = modeScanCurrent { modeScanParams.append(current) }
                    let enabled = byte == UInt8(ascii: "h")
                    for mode in modeScanParams where Self.trackedPrivateModes.contains(mode) {
                        privateModeStates[mode] = (enabled, chunkStart + index)
                    }
                    modeScanState = .idle
                case 0x1B:
                    modeScanState = .escape
                default:
                    modeScanState = .idle
                }
            }
        }
    }

    /// DECSET/DECRST sequences a replay-attached sink still needs: modes whose
    /// current state deviates from a fresh terminal's defaults AND whose last
    /// change happened before the replay window (a change inside the window is
    /// already delivered by the replay itself).
    private func modeCatchUpPreambleLocked() -> Data {
        let windowStart = totalBytesRead - replayBuffer.count
        var preamble = ""
        for mode in Self.privateModeEmissionOrder {
            guard let state = privateModeStates[mode],
                  state.offset < windowStart,
                  state.enabled != Self.defaultOnPrivateModes.contains(mode)
            else { continue }
            preamble += "\u{1B}[?\(mode)\(state.enabled ? "h" : "l")"
        }
        return Data(preamble.utf8)
    }

    /// True when the child is currently drawing in the alternate screen — a
    /// full-screen TUI (Claude Code, vim). Such a session repaints its whole
    /// screen on the next SIGWINCH, so an attaching client needs only the
    /// current modes and a resize, never a raw byte replay laid out for the
    /// grid the buffer was captured at.
    var isAlternateScreenActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return [1049, 1047, 47].contains { privateModeStates[$0]?.enabled == true }
    }

    /// Every private mode that currently deviates from a fresh terminal's
    /// defaults, as the DECSET/DECRST sequences to re-assert it — for a client
    /// that attaches *without* a byte replay (an alt-screen TUI it will repaint
    /// from scratch) and so must be put into the alternate screen and mouse
    /// modes explicitly, since no replay carries those set sequences.
    func modeResyncPreamble() -> Data {
        lock.lock()
        defer { lock.unlock() }
        var preamble = ""
        for mode in Self.privateModeEmissionOrder {
            guard let state = privateModeStates[mode],
                  state.enabled != Self.defaultOnPrivateModes.contains(mode)
            else { continue }
            preamble += "\u{1B}[?\(mode)\(state.enabled ? "h" : "l")"
        }
        return Data(preamble.utf8)
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

    /// The Mac surface's grid changed. Applied only while the host owns the
    /// size — a layout pass on the Mac (window resize, inspector toggle) must
    /// not yank the width from a phone that is actively viewing. Recorded
    /// regardless, so a later host claim restores the surface's real size.
    func resizeFromHost(cols: Int, rows: Int) {
        lock.lock()
        hostCols = cols
        hostRows = rows
        guard sizeOwner == .host else {
            lock.unlock()
            return
        }
        applyWindowSizeAndUnlock(cols: cols, rows: rows)
    }

    /// A phone reported its grid; a companion resize always claims the size
    /// (the phone only reports it while actively viewing: attach, foreground,
    /// layout). Returns whether the applied winsize actually changed — an
    /// unchanged size delivers no SIGWINCH, so a caller that needs a repaint
    /// must jiggle.
    @discardableResult
    func resizeFromCompanion(cols: Int, rows: Int) -> Bool {
        lock.lock()
        companionCols = cols
        companionRows = rows
        sizeOwner = .companion
        return applyWindowSizeAndUnlock(cols: cols, rows: rows)
    }

    /// Host input reclaims the size — typing on the Mac means the user is
    /// there. Also the hand-back when the last companion detaches. A no-op
    /// while the host already owns it, so it is cheap on every keystroke.
    func claimHostOwnership() {
        lock.lock()
        guard sizeOwner != .host else {
            lock.unlock()
            return
        }
        sizeOwner = .host
        applyWindowSizeAndUnlock(cols: hostCols, rows: hostRows)
    }

    /// Companion input reclaims the size using the last grid the phone
    /// reported (nothing to apply if it never reported one — its resize
    /// control is about to arrive anyway).
    func claimCompanionOwnership() {
        lock.lock()
        guard sizeOwner != .companion else {
            lock.unlock()
            return
        }
        sizeOwner = .companion
        guard companionCols > 0, companionRows > 0 else {
            lock.unlock()
            return
        }
        applyWindowSizeAndUnlock(cols: companionCols, rows: companionRows)
    }

    /// Observe applied winsize changes from any side. Fired on the resizing
    /// thread — hop to your own queue before doing anything slow. A bridge
    /// uses this to wipe its client ahead of a repaint laid out for some
    /// other device's grid.
    func addResizeObserver(_ observer: @escaping (Int, Int) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        resizeObservers[id] = observer
        lock.unlock()
        return id
    }

    func removeResizeObserver(_ id: UUID) {
        lock.lock()
        resizeObservers[id] = nil
        lock.unlock()
    }

    /// Applies the winsize if it differs from the current one and notifies
    /// resize observers. Must be entered with `lock` held; always unlocks.
    @discardableResult
    private func applyWindowSizeAndUnlock(cols: Int, rows: Int) -> Bool {
        guard cols != lastCols || rows != lastRows else {
            lock.unlock()
            return false
        }
        lastCols = cols
        lastRows = rows
        let observers = Array(resizeObservers.values)
        lock.unlock()
        var win = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, TIOCSWINSZ, &win)
        for observer in observers { observer(cols, rows) }
        return true
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
        // A beat between the two so the child observes both changes. The size
        // is re-read at fire time: if a client resized during the beat (a
        // phone attaching does), its size must win, not the captured one.
        // The terminated check keeps the delayed ioctl off a recycled fd.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let dead = self.terminated
            let cols = self.lastCols
            let rows = self.lastRows
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
