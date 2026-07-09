import Darwin
import Foundation

/// A PTY that termio owns, running one child process (an agent command or a
/// login shell). Replaces libghostty's `.exec` backend so termio holds the byte
/// stream itself: PTY output fans out to every attached sink (the local surface,
/// and — later — a phone), and input from any of them is written back.
///
/// The child is spawned via `forkpty` — the shape every terminal uses
/// (node-pty, iTerm2, kitty): the child does `setsid` + `TIOCSCTTY`
/// explicitly, so the pts is a fully-wired controlling terminal and job
/// control and signals (Ctrl-C → SIGINT, SIGWINCH on resize) work exactly
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
    /// Pending coalesced host SIGWINCH (see `resizeFromHost`). Lock-guarded.
    private var hostApplyWork: DispatchWorkItem?
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
        var win = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)

        // Spawn with `forkpty`, NOT posix_spawn. The old shape —
        // `POSIX_SPAWN_SETSID` plus opening the pts in the child's file
        // actions — produced a controlling terminal that *looked* wired
        // (`/dev/tty` resolved, shell WINCH traps fired) but under which
        // Claude Code's resize detection never triggered: the TUI simply
        // never repainted on a window resize, in termio or in a minimal
        // repro harness (docs/bug/terminal-resize-no-reflow-HANDOFF.md).
        // `forkpty` runs `setsid` + `TIOCSCTTY` explicitly in the child —
        // the login_tty shape under which the same agent binary reflows
        // correctly. Everything between fork and exec must be
        // async-signal-safe, so the argv/env C arrays are built up front
        // and the child only calls chdir + execve + _exit.
        let pathC = strdup(argv[0])
        let argvC: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        let envpC: [UnsafeMutablePointer<CChar>?] =
            env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let cwdC = strdup(cwd)
        var master: Int32 = -1
        var childPID: pid_t = -1
        argvC.withUnsafeBufferPointer { argvBuffer in
            envpC.withUnsafeBufferPointer { envpBuffer in
                childPID = forkpty(&master, nil, nil, &win)
                if childPID == 0 {
                    if let cwdC { _ = chdir(cwdC) }
                    if let pathC {
                        _ = execve(pathC, argvBuffer.baseAddress, envpBuffer.baseAddress)
                    }
                    _exit(127)
                }
            }
        }
        argvC.forEach { free($0) }
        envpC.forEach { free($0) }
        free(pathC)
        free(cwdC)
        guard childPID > 0 else {
            Log.pty.error("forkpty failed errno=\(errno, privacy: .public)")
            if master >= 0 { close(master) }
            return nil
        }
        masterFD = master
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
            } else if n == 0 || (errno != EINTR && errno != EAGAIN) {
                // EOF (the child and every slave fd are gone) or a hard read
                // error ends the pump for good; a transient EINTR/EAGAIN just
                // waits for the next readability event. Cancelling fires the
                // cancel handler below — the one place the master fd is closed.
                if n < 0 {
                    Log.pty.error("pty read failed errno=\(errno, privacy: .public)")
                }
                self.markTerminated()
                self.readSource?.cancel()
            }
        }
        // Dispatch's documented pattern: release the fd in the cancellation
        // handler, which runs exactly once after the source can no longer
        // fire — whether the pump ended itself (EOF above), `terminate()`
        // cancelled it, or deinit did. Captures the fd by value so the close
        // still happens if the handler runs after this object is gone.
        source.setCancelHandler { [masterFD] in
            close(masterFD)
        }
        source.resume()
        readSource = source
    }

    deinit {
        // Cancelling is idempotent; without this, dropping the last reference
        // before the EOF event fires would strand the master fd open forever.
        readSource?.cancel()
    }

    /// Marks the PTY dead so late writers and resizers become no-ops instead
    /// of touching a closed (and possibly recycled) file descriptor.
    private func markTerminated() {
        lock.lock()
        terminated = true
        lock.unlock()
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
        lock.lock()
        let dead = terminated
        lock.unlock()
        guard !dead else { return }
        data.withUnsafeBytes { raw in
            guard var cursor = raw.baseAddress else { return }
            // A single write(2) may accept fewer bytes than offered (a large
            // paste against a full kernel buffer), so loop until drained.
            var remaining = raw.count
            while remaining > 0 {
                let written = Darwin.write(masterFD, cursor, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    Log.pty.error("pty write failed errno=\(errno, privacy: .public)")
                    return
                }
                cursor += written
                remaining -= written
            }
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
        // Coalesce the burst of *distinct* grid sizes a Mac layout pass emits
        // (window open, split-view settle, live drag) into a single SIGWINCH once
        // the size stops changing. Applying each intermediate size makes zsh redraw
        // its prompt per step, and ghostty reflowing the previous PROMPT_SP line
        // strands its `%` end-of-line mark — the stack of stray `%` at startup. The
        // size is recorded above regardless, so a companion claim still restores the
        // true host grid; typing (`claimHostOwnership`) snaps immediately.
        hostApplyWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applyPendingHostSize() }
        hostApplyWork = work
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    /// Applies the latest recorded host grid after the coalescing delay, unless the
    /// process died or a companion took ownership in the meantime.
    private func applyPendingHostSize() {
        lock.lock()
        guard !terminated, sizeOwner == .host else {
            lock.unlock()
            return
        }
        applyWindowSizeAndUnlock(cols: hostCols, rows: hostRows)
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
        guard !terminated, cols != lastCols || rows != lastRows else {
            lock.unlock()
            return false
        }
        lastCols = cols
        lastRows = rows
        let observers = Array(resizeObservers.values)
        lock.unlock()
        var win = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        if ioctl(masterFD, TIOCSWINSZ, &win) != 0 {
            Log.pty.error("TIOCSWINSZ failed errno=\(errno, privacy: .public)")
        }
        for observer in observers { observer(cols, rows) }
        return true
    }

    /// Force a full-screen repaint from TUI apps by delivering a spurious
    /// SIGWINCH (shrink one row, restore). Used after a replay or after a
    /// slow client dropped frames, so the child redraws its current state.
    func jiggleResize() {
        lock.lock()
        let dead = terminated
        let cols = lastCols
        let rows = lastRows
        lock.unlock()
        guard !dead else { return }
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
        // The read source's cancel handler owns closing the master fd; closing
        // it here as well would double-close (and could hit a recycled fd).
        readSource?.cancel()
        if pid > 0 { kill(pid, SIGTERM) }
    }
}
