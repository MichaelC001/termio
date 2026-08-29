import Darwin
import Foundation
import TermioShared

/// One long-lived, multiplexed control channel per device, shared by every
/// request the files plane makes.
///
/// `withControlChannel` opens a pipe, shakes hands, asks one question and hangs
/// up. On the local socket that is free. On the SSH road it is not: the pipe is
/// `ssh <host> termiod stdio`, so every folder expand, every file open and every
/// search pays an SSH channel open, a remote `termiod` exec and a hello round
/// trip before it asks anything. Measured against a VPS at 8 ms round trip, that
/// setup is **32 ms median and 260 ms at p90** — four times the cost of the
/// question itself, with a tail an order of magnitude worse.
///
/// `TermiodDirectoryLister` already reached this conclusion for the folder
/// picker and holds its own channel open. This is that idea generalised, so the
/// tree, the file reader and the search share one connection instead of each
/// growing a private copy — and the picker is now one of its callers rather than
/// an exception to it.
///
/// **Nothing on the host changes.** The daemon already stamps every reply with
/// `re` — the `seq` of the request that caused it — and already `tokio::spawn`s
/// each `fs_list`/`fs_read`, so replies may legitimately arrive out of order and
/// have always been routable. This side simply started reading the field. One
/// protocol, one version, no new op.
///
/// The invariants this holds to:
///
/// - **Never behind an attachment.** A pooled channel is its own connection,
///   keyed by route and capability set, and never a session's attach channel —
///   a directory listing can no more queue behind PTY bytes than PTY bytes can
///   queue behind a listing (§A).
/// - **Never serialised within itself.** Requests are demultiplexed by `re`, so
///   a slow `git grep` does not hold up the folder expand behind it. Only the
///   frame writes are serialised, which is what keeps frames whole.
/// - **System OpenSSH stays the trust plane.** The pool holds a pipe that
///   `Transport.open` produced; it knows nothing about keys, hosts or crypto.
extension Termiod {
    /// Where the reader thread leaves frames for one in-flight request, and the
    /// only object it and the requesting thread share.
    ///
    /// Deliberately dumb: the reader never runs a caller's code, it only appends
    /// and signals. A demultiplexer that called into consumers would let one
    /// slow consumer stall every other request on the channel — the same
    /// head-of-line coupling this whole file exists to remove.
    final class RequestInbox: @unchecked Sendable {
        private let condition = NSCondition()
        private var frames: [(kind: FrameKind, payload: Data)] = []
        private var failure: Error?
        private var deliveredAny = false

        /// Whether the host has already said anything about this request. A
        /// request that has seen part of its answer must never be replayed on a
        /// fresh channel: half a file plus a whole file is not a file.
        var hasDelivered: Bool {
            condition.lock()
            defer { condition.unlock() }
            return deliveredAny
        }

        func deliver(kind: FrameKind, payload: Data) {
            condition.lock()
            frames.append((kind, payload))
            deliveredAny = true
            condition.signal()
            condition.unlock()
        }

        /// Ends every wait on this inbox. Called when the channel dies, so a
        /// request never outlives the connection it was asked on.
        func fail(_ error: Error) {
            condition.lock()
            if failure == nil { failure = error }
            condition.broadcast()
            condition.unlock()
        }

        /// The next frame for this request, or `timedOut` after `seconds` of the
        /// host saying nothing *about this request*. Per-request rather than
        /// per-connection: on a shared channel another caller's traffic is not
        /// evidence that this one is being answered.
        /// How long a single `wait` may sleep before the monotonic deadline is
        /// re-tested. `NSCondition` can only be given a wall-clock `Date`, and a
        /// wall clock steps — NTP, a laptop waking, the user changing the date.
        /// A backward step makes that `Date` further away than it was, so a
        /// single long wait would sleep past a deadline that has already passed.
        /// Slicing bounds the overshoot to one slice no matter how far the clock
        /// jumps, while the bound itself stays on `ContinuousClock`.
        private static let waitSlice = 0.25

        func next(timeoutSeconds: Int, operation: String) throws
            -> (kind: FrameKind, payload: Data) {
            condition.lock()
            defer { condition.unlock() }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(timeoutSeconds))
            while true {
                if !frames.isEmpty { return frames.removeFirst() }
                if let failure { throw failure }
                let remaining = clock.now.duration(to: deadline)
                guard remaining > .zero else {
                    throw TermiodClientError.timedOut(operation)
                }
                let components = remaining.components
                let seconds = Double(components.seconds)
                    + Double(components.attoseconds) / 1e18
                // A spurious wakeup, or a slice expiring early, just re-tests
                // the loop above; only `deadline` decides when to give up.
                _ = condition.wait(
                    until: Date().addingTimeInterval(min(seconds, Self.waitSlice)))
            }
        }
    }

    /// What a channel tells a resource subscriber about. Two signals rather
    /// than one, because a subscription's two failure modes are different
    /// answers: a batch is progress, and a close means the cursor this watch
    /// was counting from is on a connection that no longer exists.
    enum ChannelSignal: Sendable {
        /// An event the host addressed to no request — an `fs_changed` batch.
        case event(IncomingEvent)
        /// The connection is gone. Whatever was subscribed on it is not any
        /// more, and a subscriber must re-subscribe (and, since batches were
        /// missed while it was down, re-read what it holds).
        case closed
    }

    typealias ChannelObserver = @Sendable (ChannelSignal) -> Void

    /// One request's handle on a pooled channel: its `seq`, its inbox, and the
    /// write side of the connection it was registered on.
    final class ChannelCall {
        /// The id every frame of this request's answer is stamped with.
        let seq: UInt64
        /// Whether the channel this call went out on was already carrying
        /// traffic when the request was registered. A channel that was reused
        /// may have died quietly since — reaped by `ControlPersist`, dropped by
        /// a sleeping laptop — and that is the one failure worth retrying rather
        /// than showing.
        let wasReused: Bool
        fileprivate let channel: PooledChannel
        fileprivate let inbox: RequestInbox
        /// Whether abandoning this request obliges the client to tell the host to
        /// stop. Its own lock because `finish()` may run on a different thread
        /// from the one that armed it.
        private let cancelLock = NSLock()
        private var owesCancelLocked = false

        fileprivate init(
            seq: UInt64, wasReused: Bool, channel: PooledChannel, inbox: RequestInbox
        ) {
            self.seq = seq
            self.wasReused = wasReused
            self.channel = channel
            self.inbox = inbox
        }

        /// Declares this request cancellable, from the moment it is on the wire
        /// until the host's terminal reply lands.
        ///
        /// Only streaming requests need it, and for a sharp reason. A `git grep`
        /// keeps running on the device until something stops it, and until this
        /// change the thing that stopped it was the connection closing — the
        /// host's `run_search` watches `out.closed()` for exactly that. Pooling
        /// removed that signal: the channel outlives the request now, so a search
        /// the client gave up on would keep walking the checkout and streaming
        /// frames into an inbox that no longer exists. The protocol's own
        /// `cancel` is what replaces it.
        func cancelIfAbandoned() {
            cancelLock.lock()
            owesCancelLocked = true
            cancelLock.unlock()
        }

        /// The host said its last word on this request — a terminal reply, or a
        /// refusal it has already cleaned up behind. Nothing left to cancel.
        func completed() {
            cancelLock.lock()
            owesCancelLocked = false
            cancelLock.unlock()
        }

        /// Whether this call ever heard anything back — what decides if a lost
        /// connection may be retried.
        var hasDelivered: Bool { inbox.hasDelivered }

        func send(kind: FrameKind = .control, payload: Data) throws {
            try channel.write(kind: kind, payload: payload)
        }

        func next(timeoutSeconds: Int, operation: String) throws
            -> (kind: FrameKind, payload: Data) {
            try inbox.next(timeoutSeconds: timeoutSeconds, operation: operation)
        }

        /// Unregisters the inbox, and tells the host to stop first if this
        /// request is being walked away from mid-stream. Must be called however
        /// the request ends, or the channel accumulates inboxes nothing will
        /// ever read — and, now, the device keeps working on questions nobody
        /// is listening to.
        ///
        /// The cancel goes out before the inbox is dropped so the ordering reads
        /// the way it happens: still a live request, then stopped, then gone. A
        /// write that fails is ignored on purpose — the channel being dead is
        /// the one case the host still notices on its own.
        func finish() {
            cancelLock.lock()
            let owed = owesCancelLocked
            owesCancelLocked = false
            cancelLock.unlock()
            if owed {
                try? channel.write(
                    kind: .control,
                    payload: encodeControl(CancelOperation(
                        request: seq, seq: channel.nextRequestID())))
            }
            channel.release(seq)
        }
    }

    /// One live connection to a device, with a reader thread demultiplexing its
    /// frames onto the requests in flight.
    final class PooledChannel: @unchecked Sendable {
        let route: TermiodRoute
        let capabilities: Set<String>
        /// The account's home directory on that machine, from the handshake.
        let home: String

        private let transport: Transport
        /// Frames must not interleave on the wire, so writes are serialised —
        /// and only writes. Nothing waits for a reply under this lock.
        private let writeLock = NSLock()
        private let stateLock = NSLock()
        private var inboxes: [UInt64: RequestInbox] = [:]
        /// Sinks for frames that answer no request — today the `fs:` plane's
        /// batches (§C.10). A request's answer goes to its inbox and dies with
        /// it; a resource's batches belong to the *channel* and outlive every
        /// request on it, which is why they need a second delivery path rather
        /// than a long-lived fake request.
        private var eventObservers: [UUID: ChannelObserver] = [:]
        private var nextSeq: UInt64 = 1
        private var dead = false
        private var lastUsed = ContinuousClock.now
        /// Set once a request has been registered on this channel, so the first
        /// caller — the one that paid for the connection — can tell a genuine
        /// failure from a corpse it inherited.
        private var used = false

        var isDead: Bool {
            stateLock.lock()
            defer { stateLock.unlock() }
            return dead
        }

        fileprivate var idleDuration: Duration {
            stateLock.lock()
            defer { stateLock.unlock() }
            return inboxes.isEmpty ? lastUsed.duration(to: .now) : .zero
        }

        fileprivate init(route: TermiodRoute, caps: [String]) throws {
            let transport = try Transport.open(route)
            do {
                // The handshake is the last thing read inline: from here on the
                // reader thread owns the descriptor, and two readers on one pipe
                // would tear frames in half.
                let handshake = try performHello(transport, role: "control", caps: caps)
                self.transport = transport
                self.route = route
                self.capabilities = handshake.capabilities
                self.home = handshake.home
            } catch {
                transport.close()
                throw error
            }
            startReader()
        }

        /// Registers a request and hands back its id. `nil` once the channel is
        /// dead, which tells the caller to open a fresh one rather than wait on
        /// a pipe nobody is reading.
        fileprivate func begin() -> ChannelCall? {
            stateLock.lock()
            defer { stateLock.unlock() }
            guard !dead else { return nil }
            let seq = nextSeq
            nextSeq &+= 1
            let inbox = RequestInbox()
            inboxes[seq] = inbox
            let reused = used
            used = true
            return ChannelCall(seq: seq, wasReused: reused, channel: self, inbox: inbox)
        }

        /// An id for a frame that wants no answer — the `seq` on a `cancel`. Off
        /// the same counter as a real request so nothing on the wire ever
        /// collides; no inbox, so the host's `ok` is simply dropped.
        fileprivate func nextRequestID() -> UInt64 {
            stateLock.lock()
            defer { stateLock.unlock() }
            let seq = nextSeq
            nextSeq &+= 1
            return seq
        }

        /// Starts delivering unaddressed events to `handler`, until the
        /// returned token is passed back to `removeObserver`. Runs on the reader
        /// thread: a handler must hand off and return, never block, or it stalls
        /// every request sharing this channel.
        ///
        /// Registering on a channel that is already dead still succeeds and
        /// immediately reports `.closed`, so a caller cannot lose the race
        /// between "is it alive" and "start listening" and end up subscribed to
        /// a corpse in silence.
        func addObserver(_ handler: @escaping ChannelObserver) -> UUID {
            let token = UUID()
            stateLock.lock()
            let alreadyDead = dead
            if !alreadyDead { eventObservers[token] = handler }
            stateLock.unlock()
            if alreadyDead { handler(.closed) }
            return token
        }

        func removeObserver(_ token: UUID) {
            stateLock.lock()
            eventObservers.removeValue(forKey: token)
            stateLock.unlock()
        }

        /// Sends one control frame that wants no answer, stamped with an id off
        /// the same counter so nothing on the wire collides. No inbox, so the
        /// host's `ok` is dropped — which is the whole shape of a teardown
        /// message: it is worth sending on the connection that carries the
        /// state, and worth nothing at all on a fresh one.
        func post(_ build: (UInt64) throws -> Data) throws {
            try write(kind: .control, payload: build(nextRequestID()))
        }

        fileprivate func release(_ seq: UInt64) {
            stateLock.lock()
            inboxes.removeValue(forKey: seq)
            lastUsed = .now
            stateLock.unlock()
        }

        /// Writes one frame, or refuses if the channel died first.
        ///
        /// The liveness check is inside the write lock, not before it. A shared
        /// channel has several threads writing and any of them may be the one
        /// that finds the pipe gone, so "is it alive" and "write to it" have to
        /// be one step: a descriptor closed between the two could have been
        /// reused by then, and this would be writing frames into somebody else's
        /// file. `close` takes the same lock, so a write already underway
        /// finishes before the descriptor goes.
        fileprivate func write(kind: FrameKind, payload: Data) throws {
            writeLock.lock()
            defer { writeLock.unlock() }
            guard !isDead else { throw TermiodClientError.connectionClosed }
            try writeFrame(transport.writeDescriptor, kind: kind, payload: payload)
        }

        /// Ends the connection and every request riding it. Idempotent.
        fileprivate func close(_ reason: Error = TermiodClientError.connectionClosed) {
            stateLock.lock()
            if dead {
                stateLock.unlock()
                return
            }
            dead = true
            let pending = inboxes
            inboxes.removeAll()
            let observers = eventObservers
            eventObservers.removeAll()
            stateLock.unlock()
            // `dead` is set before this lock is taken, so no further write can
            // start; taking it waits out the one that may already be running.
            // Released first, so the two locks are never held together in one
            // order here and the other in `write`.
            writeLock.lock()
            writeLock.unlock()
            transport.close()
            for inbox in pending.values { inbox.fail(reason) }
            // After the inboxes, so a watch that re-subscribes on `.closed`
            // cannot land on this same corpse: `dead` is already set, so its
            // request for a channel opens a fresh one.
            for observer in observers.values { observer(.closed) }
        }

        /// Dedicated blocking-read thread, the same shape a session link uses:
        /// the frame stream has no natural dispatch-source form once a payload
        /// spans several reads.
        private func startReader() {
            let thread = Thread { [self] in
                while true {
                    let frame: (kind: FrameKind, payload: Data)
                    do {
                        frame = try readFrame(transport.readDescriptor)
                    } catch {
                        close(error)
                        return
                    }
                    guard let seq = Self.requestID(of: frame) else {
                        deliverUnaddressed(frame)
                        continue
                    }
                    stateLock.lock()
                    let inbox = inboxes[seq]
                    stateLock.unlock()
                    // A frame for a request nobody is waiting on is dropped, not
                    // an error: a search the user moved on from keeps streaming
                    // until the host notices, and that is not a protocol fault.
                    inbox?.deliver(kind: frame.kind, payload: frame.payload)
                }
            }
            thread.name = "sh.termio.termiod.pool"
            thread.stackSize = 512 * 1024
            thread.start()
        }

        /// Hands an event addressed to no request to whoever is listening for
        /// one. Decoded once here rather than per observer, and skipped entirely
        /// when nobody is listening — which is every channel that is not
        /// carrying a resource subscription.
        private func deliverUnaddressed(_ frame: (kind: FrameKind, payload: Data)) {
            guard frame.kind == .event else { return }
            stateLock.lock()
            let observers = eventObservers
            stateLock.unlock()
            guard !observers.isEmpty else { return }
            guard let event = try? decodeEvent(frame.payload) else { return }
            for observer in observers.values { observer(.event(event)) }
        }

        /// Which request a frame answers, or `nil` for one that answers nobody.
        ///
        /// Three shapes, because the protocol has three: a control reply carries
        /// `re`, an `F` chunk carries the same id in its binary header, and a
        /// `search_results` event carries it as `request` — the one event
        /// addressed to a request rather than to a session.
        private static func requestID(of frame: (kind: FrameKind, payload: Data)) -> UInt64? {
            switch frame.kind {
            case .control:
                return responseID(of: frame.payload)
            case .file:
                return (try? decodeFileChunk(frame.payload))?.request
            case .event:
                guard case .searchResults(let payload) = try? decodeEvent(frame.payload) else {
                    return nil
                }
                return payload.request
            default:
                return nil
            }
        }
    }

    /// The channels themselves, keyed by the device they reach and what they
    /// negotiated.
    ///
    /// Keyed by capability set as well as route because capabilities are settled
    /// at the handshake: a channel that negotiated `files` cannot answer a `git`
    /// request, and handing it one would hang on a reply the daemon will never
    /// send.
    enum ControlPool {
        private struct Key: Hashable {
            let route: TermiodRoute
            let capabilities: [String]
        }

        /// How long a channel may sit unused before it is hung up.
        ///
        /// A pooled channel is a live SSH connection and a remote process. It is
        /// worth holding through a browsing session — clicks come seconds apart —
        /// and not worth holding for a pane nobody has looked at since lunch.
        /// Paying 32 ms again after two idle minutes is the right trade; holding
        /// a process on someone's VPS indefinitely is not.
        ///
        /// A pane that is *on screen* is the case this clock gets wrong, and
        /// `pin` is the exemption for it (see `ChannelPin`).
        static let idleTimeout = Duration.seconds(120)

        private static let lock = NSLock()
        /// `nonisolated(unsafe)` because every access goes through `lock` — the
        /// lock is what makes this safe and the compiler cannot see that.
        nonisolated(unsafe) private static var channels: [Key: PooledChannel] = [:]
        nonisolated(unsafe) private static var reaper: DispatchSourceTimer?
        /// How many pins each key is holding. A count rather than a flag: two
        /// panes on one device must not have the first one closed to unpin the
        /// second's connection.
        nonisolated(unsafe) private static var pins: [Key: Int] = [:]

        /// A channel to `route`, opening one if none is live. Blocking; call it
        /// off the main thread.
        ///
        /// - Parameter discarding: a channel this caller just found dead, hung up
        ///   and removed before opening its replacement.
        static func channel(
            route: TermiodRoute, caps: [String], discarding stale: PooledChannel? = nil
        ) throws -> PooledChannel {
            let key = Key(route: route, capabilities: caps.sorted())
            if let stale {
                stale.close()
                lock.lock()
                if channels[key] === stale { channels.removeValue(forKey: key) }
                lock.unlock()
            }
            lock.lock()
            let existing = channels[key]
            lock.unlock()
            if let existing, !existing.isDead { return existing }

            // Opened outside the lock: this forks `ssh` and waits on a network
            // round trip, and no lock in this app may be held across either. A
            // rare duplicate open loses the race below and is hung up.
            let opened = try PooledChannel(route: route, caps: caps)
            lock.lock()
            if let winner = channels[key], !winner.isDead {
                lock.unlock()
                opened.close()
                return winner
            }
            channels[key] = opened
            lock.unlock()
            startReaperIfNeeded()
            return opened
        }

        /// Holds the channel to `route` open, and re-opens it in the background
        /// when it dies, for as long as the returned pin is retained.
        ///
        /// The idle clock above is written for a pane nobody is looking at. A
        /// pane that is **on screen** is the opposite case: its next click is
        /// seconds away, and making that click pay the 32 ms median / 260 ms p90
        /// of an SSH channel open plus a remote `termiod` exec is the difference
        /// between a file tree that answers and one that thinks. VS Code Remote
        /// never pays it after the first connect — its server is one process held
        /// for the window's lifetime — and this is the same bargain, scoped to a
        /// visible pane so an unwatched device still gets hung up.
        ///
        /// The re-open is what makes it a *warm* connection rather than merely an
        /// unreaped one: `ControlPersist` expiring, a laptop waking or a VPS
        /// rebooting all leave a corpse behind, and finding that out on the user's
        /// first click costs exactly what the pin exists to avoid. It only ever
        /// runs when there is no live channel, so the steady state is free.
        static func pin(route: TermiodRoute, caps: [String]) -> ChannelPin {
            ChannelPin(route: route, caps: caps)
        }

        /// A pin's claim on one key, released when it deinits.
        ///
        /// `@unchecked Sendable` on the same terms as `PooledChannel`: the timer
        /// fires on a utility queue, and the backoff state it touches is behind
        /// `backoffLock`.
        final class ChannelPin: @unchecked Sendable {
            private let key: Key
            private let route: TermiodRoute
            private let caps: [String]
            private let timer: DispatchSourceTimer
            private let backoffLock = NSLock()
            /// Consecutive failed re-opens, which push the next attempt out. A
            /// device that is off does not want a fresh `ssh` every 20 seconds
            /// for as long as its pane is open.
            private var failures = 0
            private var nextAttempt = ContinuousClock.now

            /// Slower than the reaper: this is insurance against a connection
            /// that died between clicks, not a heartbeat the protocol needs.
            static let interval = Duration.seconds(20)
            static let backoffCeiling = Duration.seconds(300)

            fileprivate init(route: TermiodRoute, caps: [String]) {
                self.key = Key(route: route, capabilities: caps.sorted())
                self.route = route
                self.caps = caps
                self.timer = DispatchSource.makeTimerSource(
                    queue: DispatchQueue.global(qos: .utility))
                ControlPool.retain(key)
                let seconds = Double(ChannelPin.interval.components.seconds)
                timer.schedule(deadline: .now() + seconds, repeating: seconds)
                timer.setEventHandler { [weak self] in self?.warm() }
                timer.resume()
            }

            deinit {
                timer.cancel()
                ControlPool.release(key)
            }

            /// Re-opens the channel if it is gone. Runs on a utility queue, and
            /// never on the click path — by the time a click asks, this has
            /// already paid for it.
            private func warm() {
                if ControlPool.hasLiveChannel(key) {
                    backoffLock.withLock { failures = 0 }
                    return
                }
                let due = backoffLock.withLock { ContinuousClock.now >= nextAttempt }
                guard due else { return }
                do {
                    _ = try ControlPool.channel(route: route, caps: caps)
                    backoffLock.withLock { failures = 0 }
                } catch {
                    let attempt = backoffLock.withLock { () -> Int in
                        failures += 1
                        let backoff = min(
                            ChannelPin.interval * Double(1 << min(failures, 4)),
                            ChannelPin.backoffCeiling)
                        nextAttempt = .now.advanced(by: backoff)
                        return failures
                    }
                    Log.termiod.debug("""
                    warming \(self.route.description, privacy: .public) failed \
                    (\(attempt, privacy: .public)): \
                    \(String(describing: error), privacy: .public)
                    """)
                }
            }
        }

        private static func retain(_ key: Key) {
            lock.lock()
            pins[key, default: 0] += 1
            lock.unlock()
        }

        private static func release(_ key: Key) {
            lock.lock()
            if let count = pins[key] {
                if count <= 1 { pins.removeValue(forKey: key) } else { pins[key] = count - 1 }
            }
            lock.unlock()
        }

        private static func hasLiveChannel(_ key: Key) -> Bool {
            lock.lock()
            let channel = channels[key]
            lock.unlock()
            guard let channel else { return false }
            return !channel.isDead
        }

        /// Hangs up every channel to `route`, or the whole pool when `route` is
        /// nil, so the next request opens fresh rather than waiting on a pipe
        /// whose far end is gone.
        ///
        /// Nothing in the app calls this, and the comment should say so rather
        /// than imply a caller: machines come from `~/.ssh/config` and are never
        /// forgotten, so there is no moment where a device goes away for good. A
        /// channel to one that stopped answering dies on its own read and is
        /// reaped. What does need this is a test, which must not hand the next
        /// test a channel pointed at a daemon it is about to kill — a
        /// process-wide pool with no way to empty it can only be tested once.
        static func closeAll(route: TermiodRoute? = nil) {
            lock.lock()
            let closing = channels.filter { route == nil || $0.key.route == route }
            for key in closing.keys { channels.removeValue(forKey: key) }
            lock.unlock()
            for channel in closing.values { channel.close() }
        }

        /// Hangs up channels nobody has used in `idleTimeout`, and stops itself
        /// once the pool is empty — a timer that ticks forever for a feature
        /// nobody is using is its own small leak.
        private static func startReaperIfNeeded() {
            lock.lock()
            defer { lock.unlock() }
            guard reaper == nil else { return }
            let timer = DispatchSource.makeTimerSource(
                queue: DispatchQueue.global(qos: .utility))
            timer.schedule(deadline: .now() + 30, repeating: 30)
            timer.setEventHandler { reap(idleTimeout: idleTimeout) }
            reaper = timer
            timer.resume()
        }

        /// - Parameter idleTimeout: how long unused is too long. A parameter only
        ///   so a test can hand it a threshold every idle channel is already past
        ///   — the pin's whole effect is what this method does *not* hang up, and
        ///   waiting two minutes to see it is not a test.
        static func reap(idleTimeout: Duration) {
            lock.lock()
            var expired: [PooledChannel] = []
            // A pinned key is exempt from the idle clock but not from death: a
            // channel whose pipe is gone is removed here as it always was, and
            // the pin's own timer is what opens its replacement.
            for (key, channel) in channels
            where channel.isDead || (pins[key] == nil && channel.idleDuration > idleTimeout) {
                expired.append(channel)
                channels.removeValue(forKey: key)
            }
            let empty = channels.isEmpty
            if empty {
                reaper?.cancel()
                reaper = nil
            }
            lock.unlock()
            for channel in expired { channel.close() }
        }
    }

    /// Runs one request over the pooled channel for `route`, retrying once on a
    /// connection that was already open and turned out to be dead.
    ///
    /// The retry is the price of pooling. A one-shot channel could not be stale;
    /// a held one can be — `ControlPersist` reaps the master, a laptop sleeps,
    /// a VPS reboots — and discovering that on the user's first click after a
    /// break must cost a reconnect, not an error dialog. It is deliberately
    /// narrow: only a channel this caller *inherited*, and only while the host
    /// has said nothing at all about the request. Once a single frame of the
    /// answer has landed, replaying the request could duplicate or splice it.
    ///
    /// Blocking; call it off the main thread.
    static func withPooledRequest<Result>(
        route: TermiodRoute, caps: [String],
        _ body: (ChannelCall, PooledChannel) throws -> Result
    ) throws -> Result {
        var stale: PooledChannel?
        for attempt in 0 ... 1 {
            let channel = try ControlPool.channel(route: route, caps: caps, discarding: stale)
            guard let call = channel.begin() else {
                stale = channel
                continue
            }
            let reused = call.wasReused
            defer { call.finish() }
            do {
                return try body(call, channel)
            } catch {
                guard attempt == 0, reused, !call.hasDelivered, isConnectionLoss(error) else {
                    throw error
                }
                Log.termiod.info("""
                pooled \(caps.joined(separator: ","), privacy: .public) channel to \
                \(route.description, privacy: .public) was stale; reconnecting
                """)
                stale = channel
            }
        }
        throw TermiodClientError.connectionClosed
    }

    /// Whether a failure means "this pipe is gone" rather than "the host said
    /// no". Only the former is worth reconnecting for: a daemon that refused a
    /// path would refuse it again on a fresh connection.
    private static func isConnectionLoss(_ error: Error) -> Bool {
        switch error {
        case TermiodClientError.connectionClosed, TermiodClientError.malformedFrame:
            return true
        case TermiodClientError.timedOut:
            // A host that stopped answering mid-request is indistinguishable
            // from one whose pipe died, and on a reused channel the second is
            // far likelier. One reconnect settles which.
            return true
        default:
            return false
        }
    }
}
