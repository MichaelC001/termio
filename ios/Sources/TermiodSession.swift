import Foundation
import TermioShared

/// `DeviceSession` over the termiod Session Protocol: one attach channel to a
/// PTY on the device, carrying keystrokes out and its bytes back.
///
/// Everything the companion transport does over a Mac's relay, this does one hop
/// earlier — with three differences the protocol makes possible:
///
/// - **A reattach repaints from a snapshot, not a replay.** The daemon's
///   authoritative VT hands over the *current* screen (`S`) and live bytes
///   resume on top, instead of a torrent of historical escapes that mangles an
///   idle TUI. That is the reattach story, and the phone reattaches every time
///   it unlocks.
/// - **The grid is arbitrated.** §C.5 makes the PTY's size a host-side barrier
///   owned by one writer, so `E resized` is the authoritative answer and this
///   client honours it rather than assuming its own viewport won.
/// - **Input is gated on a token, not on auth.** Many clients may watch one
///   session and exactly one may type into it.
final class TermiodSession: DeviceSession {
    var onOutput: ((Data) -> Void)?
    var onState: ((DeviceSessionState) -> Void)?

    /// How long the grid must hold still before a size goes to the device. Every
    /// distinct size is a host-side barrier — the session quiesces, resizes, and
    /// pushes a fresh keyframe to every attachment — so a settling keyboard
    /// animation must not become a burst of full repaints.
    private static let resizeCoalescingInterval = DispatchTimeInterval.milliseconds(50)

    private let sessionName: String
    private let channel: TermiodChannel
    /// Everything below is touched only on `queue`, which is also the channel's
    /// delegate queue — so a frame's arrival and this state are already serial
    /// and PTY bytes never wait behind UI work.
    private let queue = DispatchQueue(label: "sh.termio.mobile.termiod-session")
    private var attached = false
    private var isWriter = false
    private var claimingWriter = false
    /// Keystrokes that arrived before the attach landed. The device would refuse
    /// them and the person would have to retype, so they wait.
    private var pendingInput = Data()
    /// What this surface is laid out at, and what the PTY actually is. They
    /// differ while a resize is in flight, and while another client owns size.
    private var desiredGrid = TerminalGrid(rows: 0, cols: 0)
    private var authoritativeGrid: TerminalGrid?
    private var resizeGeneration: UInt64 = 0
    /// A reconnect re-attaches rather than opening a second session, and the
    /// snapshot is what repaints the screen — so the reader must not be told the
    /// old link's screen is still valid.
    private var everAttached = false

    init(endpoint: DeviceEndpoint, sessionName: String) {
        self.sessionName = sessionName
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.underlyingQueue = self.queue
        channel = TermiodChannel(
            endpoint: endpoint, name: "session", role: "attach",
            capabilities: Termiod.attachCapabilities,
            delegateQueue: queue, pingRunLoopMode: .common
        )
        channel.onReady = { [weak self] _ in self?.sendAttach() }
        // An attach channel carries one attachment and nothing else, so there is
        // never a second request for a reply to be confused with — the `re` is
        // real but has nothing to demultiplex.
        channel.onControl = { [weak self] reply in self?.receive(reply.control) }
        channel.onEvent = { [weak self] event in self?.receive(event) }
        channel.onData = { [weak self] data in self?.onOutput?(data) }
        channel.onSnapshot = { [weak self] payload in self?.repaint(payload) }
        channel.onLinkState = { [weak self] up in
            guard let self, !up else { return }
            // The socket is gone, so nothing about the old attachment holds:
            // the next `attached` reply is what says so again.
            self.queue.async { [weak self] in
                self?.attached = false
                self?.isWriter = false
                self?.claimingWriter = false
            }
            notify(.reconnecting)
        }
        channel.onFailure = { [weak self] reason in self?.notify(.failed(reason)) }
    }

    func start() {
        notify(.connecting)
        channel.start()
    }

    func stop() {
        // Leave the stream without killing the session — the whole reason it
        // lives in a daemon. Sent straight through rather than hopping to the
        // frame queue first: this runs from a view controller's `deinit`, where
        // capturing self into a later block is not allowed, and a detach on a
        // channel that never attached is a no-op the device ignores.
        if let payload = try? Termiod.detachPayload() {
            channel.send(kind: .control, payload: payload)
        }
        channel.stop()
    }

    func send(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [self] in
            guard attached else {
                pendingInput.append(data)
                return
            }
            write(data)
        }
    }

    func resize(columns: Int, rows: Int) {
        queue.async { [self] in
            let grid = TerminalGrid(rows: UInt16(clamping: rows), cols: UInt16(clamping: columns))
            desiredGrid = grid
            guard attached, isWriter, grid.rows > 0, grid.cols > 0 else { return }
            // A size the PTY already has would cost every attachment a barrier
            // repaint for nothing.
            guard authoritativeGrid != grid else { return }
            scheduleResize()
        }
    }

    func reassertGrid() {
        queue.async { [self] in
            guard attached, isWriter, desiredGrid.rows > 0, desiredGrid.cols > 0 else { return }
            // Deliberately past the "already this size" check `resize` applies.
            // libghostty drops an unchanged viewport at two layers, so on a cold
            // attach no resize ever fires and the screen stays blank under a
            // correct title; this is the call that has to put an `R` on the wire
            // regardless, and the fresh keyframe behind it is the repaint.
            sendResize(desiredGrid)
        }
    }

    // MARK: - Attach

    private func sendAttach() {
        do {
            let grid = desiredGrid
            channel.send(kind: .control, payload: try Termiod.attachPayload(
                target: sessionName,
                // Never `create_if_missing`: a screen opens on a session that
                // already exists, and spawning one here would turn "that session
                // is gone" into a second, empty shell.
                specification: nil,
                // The surface normally reports its grid before the socket is
                // open; 24×80 stands in when it has not laid out yet, and the
                // first `R` corrects it.
                rows: grid.rows > 0 ? grid.rows : 24,
                cols: grid.cols > 0 ? grid.cols : 80
            ))
        } catch {
            Log.device.error("""
            encoding attach for \(self.sessionName, privacy: .public) failed: \
            \(error.localizedDescription, privacy: .public)
            """)
            notify(.failed(localized("Termio couldn't attach to that session.")))
        }
    }

    private func receive(_ control: Termiod.IncomingControl) {
        switch control {
        case .attached(let payload):
            attached = true
            everAttached = true
            isWriter = payload.writer
            // The reply reports the session's size *before* this attach is
            // applied; the device then resizes to what a writer asked for and
            // announces it. Seeding from here is what lets an observer know the
            // grid its bytes are wrapped at.
            authoritativeGrid = TerminalGrid(rows: payload.rows, cols: payload.cols)
            if !pendingInput.isEmpty {
                let buffered = pendingInput
                pendingInput.removeAll(keepingCapacity: false)
                write(buffered)
            }
            notify(.connected)
        case .exited:
            attached = false
            notify(.closed)
        case .resizeClaim(let claim):
            applyWriter(claim.writer)
        case .error(let failure):
            // A refused claim answers here rather than with `writer_changed`,
            // and the flag has to clear either way: left set, one refusal would
            // mute this attachment for the rest of its life.
            claimingWriter = false
            guard !everAttached else {
                Log.device.error("""
                device refused a request on \(self.sessionName, privacy: .public): \
                \(failure.message, privacy: .public)
                """)
                return
            }
            // Refused before ever attaching: the session is not there, which is
            // fatal for this screen rather than something to retry into.
            notify(.failed(failure.message))
        default:
            break
        }
    }

    private func receive(_ event: Termiod.IncomingEvent) {
        switch event {
        case .writerChanged(let change):
            applyWriter(change.writer)
        case .resized(let size):
            applyAuthoritativeGrid(TerminalGrid(rows: size.rows, cols: size.cols))
        case .sessionExited:
            attached = false
            notify(.closed)
        default:
            break
        }
    }

    /// Repaints from the device's authoritative VT. Emitted straight through
    /// `onOutput`, on the same serial queue the live `D` frames arrive on, which
    /// is what preserves snapshot-before-bytes with no hold-back buffer.
    private func repaint(_ payload: Data) {
        guard let keyframe = TermiodSnapshot.decode(payload) else {
            Log.device.error("""
            undecodable snapshot on \(self.sessionName, privacy: .public)
            """)
            return
        }
        // A keyframe is a formatted repaint, wrapped rows and all, laid out for
        // the grid the device's VT held when it was taken. Painted into a
        // narrower surface every wrapped row shifts, and a TUI that redraws
        // incrementally never repairs it. Only a writer may drop one: this
        // client is then the one moving the PTY, so the barrier at the far end
        // of its own resize will push another at the right size.
        let payloadGrid = TerminalGrid(
            rows: UInt16(clamping: keyframe.rows), cols: UInt16(clamping: keyframe.cols))
        if isWriter, desiredGrid.rows > 0, payloadGrid != desiredGrid {
            Log.device.info("""
            skipping \(payloadGrid.cols, privacy: .public)x\(payloadGrid.rows, privacy: .public) \
            keyframe on \(self.sessionName, privacy: .public); this surface is \
            \(self.desiredGrid.cols, privacy: .public)x\(self.desiredGrid.rows, privacy: .public)
            """)
            return
        }
        onOutput?(TermiodSnapshot.render(keyframe))
    }

    // MARK: - Write token

    /// Typing claims the token, which is the same rule every other termio client
    /// follows: size and writes go to the device whose user is at the keyboard.
    /// Attaching does not claim it — a phone merely looking at a session must
    /// not mute the window that opened it and pull the PTY to its own width.
    ///
    /// Ordering is safe: frames on one connection are processed in order, so the
    /// claim resolves before the input queued behind it is tested against it.
    private func write(_ data: Data) {
        if !isWriter, !claimingWriter {
            claimingWriter = true
            if let payload = try? Termiod.claimWriterPayload() {
                channel.send(kind: .control, payload: payload)
            }
        }
        var offset = 0
        while offset < data.count {
            let end = min(offset + Termiod.maximumDataFrameSize, data.count)
            channel.send(kind: .data, payload: data.subdata(in: offset ..< end))
            offset = end
        }
    }

    /// The device names the writer by client id, so this is the one comparison
    /// that tells this connection whether its `D` and `R` frames are honoured.
    private func applyWriter(_ writer: String?) {
        claimingWriter = false
        let mine = writer != nil && writer == channel.clientID
        guard mine != isWriter else { return }
        isWriter = mine
        Log.device.info("""
        write token on \(self.sessionName, privacy: .public) \
        \(mine ? "claimed" : "lost", privacy: .public)
        """)
        // A client that was demoted stopped sending resizes, so the PTY can be
        // any size by the time the token comes back.
        guard mine, desiredGrid.rows > 0 else { return }
        sendResize(desiredGrid)
    }

    /// §C.5: the PTY has one size and every client parses at it. A writer
    /// answers a divergence by putting its own size back; an observer can only
    /// record it, because nothing it sends would be honoured.
    private func applyAuthoritativeGrid(_ grid: TerminalGrid) {
        guard authoritativeGrid != grid else { return }
        authoritativeGrid = grid
        guard grid != desiredGrid, desiredGrid.rows > 0 else { return }
        Log.device.info("""
        \(self.sessionName, privacy: .public) PTY is now \
        \(grid.cols, privacy: .public)x\(grid.rows, privacy: .public); this client renders \
        \(self.desiredGrid.cols, privacy: .public)x\(self.desiredGrid.rows, privacy: .public)
        """)
        guard isWriter else { return }
        sendResize(desiredGrid)
    }

    /// Sends `desiredGrid` once the surface stops moving. Generation-stamped
    /// rather than debounced with a cancellable item because the size is re-read
    /// at fire time: the last scheduled send is the only one that writes, and it
    /// writes whatever the grid settled at.
    private func scheduleResize() {
        resizeGeneration &+= 1
        let generation = resizeGeneration
        queue.asyncAfter(deadline: .now() + Self.resizeCoalescingInterval) { [self] in
            guard attached, isWriter, generation == resizeGeneration else { return }
            sendResize(desiredGrid)
        }
    }

    private func sendResize(_ grid: TerminalGrid) {
        channel.send(kind: .resize, payload: Termiod.resizePayload(grid.rows, grid.cols))
    }

    private func notify(_ state: DeviceSessionState) {
        DispatchQueue.main.async { [onState] in onState?(state) }
    }
}
