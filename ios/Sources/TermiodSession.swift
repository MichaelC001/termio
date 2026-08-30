import Foundation
import TermioShared

/// `DeviceSession` over the termiod Session Protocol: one attach channel to a
/// PTY on the device, carrying keystrokes out and its bytes back.
///
/// Everything the companion transport does over a Mac's relay, this does one hop
/// earlier, with three differences the protocol makes possible:
///
/// - **A reattach repaints from a snapshot, not a replay.** The daemon's VT
///   hands over the *current* screen (`S`) and live bytes resume on top, rather
///   than a torrent of historical escapes that mangles an idle TUI. The phone
///   reattaches every time it unlocks.
/// - **The grid is arbitrated.** The PTY's size is a host-side barrier owned by
///   one writer, so `E resized` is authoritative and this client honours it
///   rather than assuming its own viewport won.
/// - **Input is gated on a token.** Many clients may watch one session and
///   exactly one may type into it.
final class TermiodSession: DeviceSession {
    var onOutput: ((Data) -> Void)?
    var onState: ((DeviceSessionState) -> Void)?
    var onSharedGrid: ((TerminalGrid, Bool) -> Void)?

    /// How long the grid must hold still before a size goes to the device. Every
    /// distinct size is a host-side barrier — quiesce, resize, fresh keyframe to
    /// every attachment — so a settling keyboard animation must not become a
    /// burst of full repaints.
    private static let resizeCoalescingInterval = DispatchTimeInterval.milliseconds(50)

    private let sessionName: String
    private let channel: TermiodChannel
    /// The state below is touched only here, and this is the channel's delegate
    /// queue, so PTY bytes never wait behind UI work.
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
    /// An observer whose surface is not yet at the shared grid. The keyframe
    /// that announced the grid was parsed at the old one, and the surface is
    /// re-laid-out only after `onSharedGrid` reaches the screen — so the first
    /// `resize` that lands *on* the shared grid asks the device for a fresh
    /// keyframe, and that one paints right.
    private var observerRepaintPending = false
    private var resizeGeneration: UInt64 = 0
    /// Whether this screen ever had a session, which is what separates "the
    /// device refused a request" from "that session is not there".
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
        // Detach without killing the session — the whole reason it lives in a
        // daemon. Sent straight through rather than by hopping to the frame
        // queue: this runs from a view controller's `deinit`, where capturing
        // self into a later block is not allowed.
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

    /// The surface's own answer to a host query. The host asked its terminal
    /// one question and the writer's surface is that terminal, so this goes
    /// through only while this phone holds the token — an observer's answer
    /// would arrive late and land in the agent's input line as text — and it
    /// never claims: a probe is not the person showing up.
    func sendDeviceReport(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [self] in
            guard attached, isWriter else { return }
            sendData(data)
        }
    }

    func resize(columns: Int, rows: Int) {
        queue.async { [self] in
            let grid = TerminalGrid(rows: UInt16(clamping: rows), cols: UInt16(clamping: columns))
            desiredGrid = grid
            guard attached, grid.rows > 0, grid.cols > 0 else { return }
            // An observer cannot move the PTY; arriving at the shared grid is
            // the one moment it needs something from the device: a keyframe it
            // can finally paint. Leaving the grid — a pinch reports the old
            // frame at new cell metrics before the layout puts it back — arms
            // the next arrival, so the bytes parsed in between are repainted too.
            guard isWriter else {
                if authoritativeGrid != grid {
                    observerRepaintPending = true
                } else if observerRepaintPending {
                    observerRepaintPending = false
                    if let payload = try? Termiod.requestSnapshotPayload() {
                        channel.send(kind: .control, payload: payload)
                    }
                }
                return
            }
            // A size the PTY already has would cost every attachment a barrier
            // repaint for nothing.
            guard authoritativeGrid != grid else { return }
            scheduleResize()
        }
    }

    func reassertGrid() {
        queue.async { [self] in
            guard attached, isWriter, desiredGrid.rows > 0, desiredGrid.cols > 0 else { return }
            // The same check `resize` applies, on purpose. This used to put an
            // `R` on the wire regardless, hoping the barrier's keyframe would
            // repaint a blank screen — but the device ignores a size the PTY
            // already has (no SIGWINCH, no barrier), so that `R` repainted
            // nothing, and one that did change the size repainted every other
            // attachment. The attach snapshot is what paints a cold screen.
            guard authoritativeGrid != desiredGrid else { return }
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
            observerRepaintPending = !isWriter && authoritativeGrid != desiredGrid
            publishSharedGrid()
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
        sendData(data)
    }

    private func sendData(_ data: Data) {
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
        observerRepaintPending = !mine && authoritativeGrid != desiredGrid
        publishSharedGrid()
        // A client that was demoted stopped sending resizes, so the PTY can be
        // any size by the time the token comes back.
        guard mine, desiredGrid.rows > 0 else { return }
        sendResize(desiredGrid)
    }

    /// §C.5: the PTY has one size and every client parses at it. A writer
    /// answers a divergence by putting its own size back; an observer lays its
    /// surface out at the shared grid instead (`onSharedGrid`), because nothing
    /// it sends would be honoured.
    private func applyAuthoritativeGrid(_ grid: TerminalGrid) {
        guard authoritativeGrid != grid else { return }
        authoritativeGrid = grid
        if !isWriter { observerRepaintPending = grid != desiredGrid }
        publishSharedGrid()
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

    private func publishSharedGrid() {
        guard let grid = authoritativeGrid else { return }
        let writer = isWriter
        DispatchQueue.main.async { [onSharedGrid] in onSharedGrid?(grid, writer) }
    }

    private func notify(_ state: DeviceSessionState) {
        DispatchQueue.main.async { [onState] in onState?(state) }
    }
}
