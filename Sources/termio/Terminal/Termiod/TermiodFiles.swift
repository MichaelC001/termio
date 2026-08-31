import Foundation
import TermioShared

/// The files plane: reading a device's directories and files through `fs.*`.
///
/// A file tree answers "what is in this directory on that machine", which two
/// people watching from two machines expect to match — so the device owns it
/// (device architecture §4.1) and this is the client that asks. It replaces the
/// SFTP tree, which spoke a second protocol to a second server for the same
/// question.
///
/// Every verb here rides the **pooled** control channel for the device
/// (`TermiodControlPool.swift`): one connection per machine, many requests
/// multiplexed over it by `re`. Correctness does not depend on that — `fs.list`
/// canonicalises the root and confines every path under it
/// (`termiod/src/files.rs`), `fs.read` answers one `fs_file` header followed by
/// `F` chunks, and neither is a subscription — but latency does. A channel per
/// request meant `ssh <host> termiod stdio` per folder expand, which measured at
/// 32 ms median and 260 ms at p90 on a link whose round trip is 8 ms.
///
/// Live change notification is `ResourceWatch` below: the `fs:` resource
/// (§C.10), which the daemon has served since it grew a watcher and nothing
/// here subscribed to. It is what replaces re-listing the whole tree every time
/// the app takes focus — the update model VS Code and Zed both settled on, where
/// the host says what moved and the client re-reads only that.
extension Termiod {
    /// A live subscription to one host resource, held for as long as the object
    /// is retained.
    ///
    /// The `fs:` plane is the first consumer: one recursive watch per workspace
    /// on the device, batched behind a 0.3 s quiet window, delivered as the set
    /// of **directories** whose contents changed. A subscriber re-lists exactly
    /// those and nothing else.
    ///
    /// Two things make this survivable rather than merely live:
    ///
    /// - **The cursor.** Every batch carries a monotonic `seq`, and `fs_listed`
    ///   carries the cursor its listing was taken at. A reconnect re-subscribes
    ///   with `since`, so batches that landed while the link was down are
    ///   replayed rather than lost — and a batch the listing already reflects is
    ///   dropped rather than re-fetched.
    /// - **The reset.** When the host cannot replay from `since` (the ring aged
    ///   out) it answers `gap`, and a dropped connection means the same thing.
    ///   Both surface as `.reset`, whose only correct handling is to re-read what
    ///   is held. A watch that quietly resumed after a gap would show a tree that
    ///   is wrong in exactly the way nobody would notice.
    ///
    /// Routing, re-keying on the ack, and the last-subscriber accounting all
    /// live in `ResourceSubscription` and the channel's routing table, which is
    /// the same machinery the `git:` plane subscribes through. This class is
    /// what sits on top of it: the retry loop that keeps a subscription up, and
    /// the cursor that decides which batches are news.
    ///
    /// `@unchecked Sendable`: the state is behind `lock`, and every callback is
    /// raised off the caller's queue.
    final class ResourceWatch: @unchecked Sendable {
        enum Update: Sendable {
            /// The directories named have changed. `fullRescan` means the set is
            /// not authoritative and everything realized must be re-read.
            case batch(FsChangedPayload)
            /// The subscription could not be continued from where it left off.
            /// Whatever is held may be stale; re-read it.
            case reset
            /// The **first** subscribe of this watch's life has landed.
            ///
            /// Sent once, because it answers a question that can only be asked
            /// at the start: a listing taken before the daemon had any watch is
            /// stamped `seq == 0`, and anything that changed between that
            /// listing and this moment raised no batch anybody was subscribed
            /// for. No later event repairs it — the watch begins at a cursor
            /// already past the change. A caller holding such a listing has to
            /// re-read here.
            ///
            /// Later re-subscribes say `reset` instead: those have a `since` to
            /// replay from, and their failure to use it is what `gap` reports.
            case established
        }

        /// The capability the daemon must have granted. A device too old to
        /// serve it never gets a subscription, and its tree keeps the manual
        /// refresh it always had.
        static let capability = "resources"

        /// How long a failed subscribe waits before trying again, and the
        /// ceiling it backs off to. Slower than the channel pin's own warm-up:
        /// the pin is what re-opens the connection, and this only has to notice
        /// that it came back.
        static let retryInterval = Duration.seconds(5)
        static let retryCeiling = Duration.seconds(120)

        private let route: TermiodRoute
        private let caps: [String]
        private let resource: String
        private let onUpdate: @Sendable (Update) -> Void
        private let queue: DispatchQueue
        private let pin: ControlPool.ChannelPin

        private let lock = NSLock()
        /// Which subscribe attempt a callback belongs to. A subscription that is
        /// interrupted *while* its replacement is being armed must not tear the
        /// replacement down, and a batch from an attempt this watch has moved on
        /// from is not news.
        private var generation: UInt64 = 0
        /// The live subscription, or nil between attempts. Holding it is the
        /// interest: releasing it is what retires the watch on the device, and
        /// it is released with the last subscriber to that resource on this
        /// connection rather than with the first (`ResourceSubscription.cancel`).
        private var subscription: ResourceSubscription?
        /// The highest batch applied, replayed from on reconnect. `nil` until
        /// the first subscribe answers, which is what makes that first one ask
        /// for the cursor rather than a replay.
        private var cursor: UInt64?
        private var failures = 0
        private var stopped = false
        /// Whether a subscribe has ever landed, so `established` fires once.
        private var hasEstablished = false

        /// Subscribes, and keeps the subscription up. `onUpdate` is raised on an
        /// arbitrary queue and must hop wherever it needs to be.
        init(
            route: TermiodRoute, caps: [String], resource: String,
            onUpdate: @escaping @Sendable (Update) -> Void
        ) {
            self.route = route
            self.caps = caps
            self.resource = resource
            self.onUpdate = onUpdate
            self.queue = DispatchQueue(
                label: "sh.termio.termiod.watch", qos: .utility)
            self.pin = ControlPool.pin(route: route, caps: caps)
            queue.async { [weak self] in self?.connect() }
        }

        deinit {
            lock.lock()
            stopped = true
            let held = subscription
            subscription = nil
            lock.unlock()
            // Retires the interest, and tells the device only when this was the
            // last subscriber to the resource on the shared channel. Sending it
            // unconditionally is what used to take a second pane's watch down
            // with the first pane's close: the daemon tracks subscribers per
            // *connection* (`resource.rs`), and the pool gives two panes on one
            // machine one connection.
            held?.cancel()
        }

        /// Whether a subscription is up right now.
        ///
        /// False before the first subscribe lands, while a dropped one is being
        /// re-established, and forever on a daemon that never granted
        /// `resources`. A caller that had a reconcile of its own before this
        /// existed keeps it as the fallback for that last case: a watch that
        /// cannot run must not take the old behaviour down with it.
        var isSubscribed: Bool {
            lock.withLock { !stopped && subscription != nil }
        }

        /// The root the host is actually watching, canonicalised — the live
        /// subscription's resource id minus its `fs:` prefix. The tree needs it
        /// to translate a batch's paths back into its own spelling: the daemon
        /// reports changes under the real path, while every path the tree holds
        /// came from an `fs.list` reply, which echoes the path *as asked*. On a
        /// root reached through a symlink the two differ, and a tree comparing
        /// them literally would match nothing and never re-list.
        ///
        /// The re-key happens on the channel's reader thread before the ack is
        /// handed back, so this reads the device's own spelling from the moment
        /// the subscription is installed.
        var watchedRoot: String? {
            guard let resource = lock.withLock({ subscription?.resource }),
                  resource.hasPrefix("fs:")
            else { return nil }
            return String(resource.dropFirst("fs:".count))
        }

        /// Tells the watch which cursor a listing was taken at, so batches the
        /// listing already includes are not applied over it. Called by the tree
        /// after every `fs.list` it grafts.
        func noteListed(at seq: UInt64) {
            guard seq > 0 else { return }
            lock.lock()
            if cursor == nil || seq > cursor! { cursor = seq }
            lock.unlock()
        }

        /// One batch off the channel's routing table. The routing already
        /// guarantees it belongs to this resource; what is decided here is
        /// whether it is *news* — the listing that answered a previous batch may
        /// have been taken after this one was raised, and re-listing on it would
        /// ask the device a question it has already answered.
        private func receive(_ payload: Data, generation: UInt64) {
            guard let batch = try? decodeFsChanged(payload) else { return }
            let fresh: Bool = lock.withLock {
                guard !stopped, generation == self.generation else { return false }
                if let cursor, batch.seq <= cursor { return false }
                cursor = batch.seq
                return true
            }
            guard fresh else { return }
            onUpdate(.batch(batch))
        }

        /// The channel underneath died. The device keeps the resource and its
        /// replay ring for its linger window, so the next attempt resumes from
        /// the cursor rather than rebuilding — but batches raised while the link
        /// was down reach only as far back as that ring, so the caller is told
        /// to re-read regardless.
        private func interrupted(generation: UInt64) {
            let current: Bool = lock.withLock {
                guard !stopped, generation == self.generation else { return false }
                subscription = nil
                return true
            }
            guard current else { return }
            onUpdate(.reset)
            retry(after: TermiodClientError.connectionClosed, generation: generation)
        }

        private func connect() {
            lock.lock()
            guard !stopped else { lock.unlock(); return }
            // One failure can arm two recoveries: the interruption schedules a
            // retry, and `subscribeResource` retries a stale channel inside the
            // same call. Holding a live subscription means there is nothing to
            // reconnect.
            guard subscription == nil else { lock.unlock(); return }
            generation &+= 1
            let generation = self.generation
            let since = cursor
            lock.unlock()

            do {
                let (subscription, gap, _) = try subscribeResource(
                    route: route, caps: caps, resource: resource, since: since,
                    requiring: [Self.capability],
                    onEvent: { [weak self] payload in
                        self?.receive(payload, generation: generation)
                    },
                    onInterrupted: { [weak self] in
                        self?.interrupted(generation: generation)
                    })
                let first: Bool? = lock.withLock {
                    guard !stopped, generation == self.generation else { return nil }
                    self.subscription = subscription
                    failures = 0
                    defer { hasEstablished = true }
                    return !hasEstablished
                }
                guard let first else {
                    // Stopped, or superseded, while the handshake was in flight:
                    // the subscription must not outlive the interest that asked
                    // for it.
                    subscription.cancel()
                    return
                }
                // A first subscribe always reports a gap — there is nothing to
                // replay from. Reporting that as a reset would open every pane
                // with two full listings instead of one. What the caller does
                // need is to know the watch is armed, so a listing taken before
                // it can be reconsidered.
                if first {
                    onUpdate(.established)
                } else if gap {
                    onUpdate(.reset)
                }
            } catch {
                retry(after: error, generation: generation)
            }
        }

        private func retry(after error: Error, generation: UInt64) {
            let delay: Duration? = lock.withLock {
                guard !stopped, generation == self.generation else { return nil }
                // A device that cannot serve resources at all will never start,
                // so it is not worth a timer: the tree keeps its manual refresh.
                if case TermiodClientError.unsupportedCapability = error { return nil }
                failures += 1
                return min(
                    Self.retryInterval * Double(1 << min(failures, 5)),
                    Self.retryCeiling)
            }
            guard let delay else { return }
            Log.files.debug("""
            \(self.resource, privacy: .public) watch on \
            \(self.route.description, privacy: .public) retrying: \
            \(String(describing: error), privacy: .public)
            """)
            let seconds = Double(delay.components.seconds)
            queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.connect()
            }
        }
    }

    /// One `fs_changed` batch, as it arrives off the resource plane. Routed by
    /// resource id rather than by request, so it reaches a subscriber as raw
    /// payload and is decoded through the shared event table here — the same
    /// shape `decodeGitChanged` has on the git plane.
    static func decodeFsChanged(_ payload: Data) throws -> FsChangedPayload {
        guard case .fsChanged(let batch) = try decodeEvent(payload) else {
            throw TermiodClientError.malformedFrame
        }
        return batch
    }

    /// What one directory answered. `error` is the device's own message for a
    /// path that vanished or escaped the root; a batched request fails one path
    /// at a time rather than as a whole.
    struct DirectoryListing: Sendable {
        let path: String
        let entries: [FileEntry]
        let error: String?
    }

    /// A batch of listings and the `fs:` cursor they were taken at — what a
    /// subscriber needs to tell a batch it has already answered from one it has
    /// not. Zero when the device is running no watch, which reads as "nothing
    /// will invalidate this".
    struct DirectoryListings: Sendable {
        let listings: [DirectoryListing]
        let seq: UInt64
    }

    /// Reading a file for preview is capped at the same 1 MiB the daemon serves
    /// without a range (`files.rs` `READ_SOFT_CAP`) and the companion's own
    /// preview budget. Asking for more would be answered `truncated` anyway.
    static let filePreviewByteLimit = 1_024 * 1_024

    /// How long a search may go without the device saying anything before it is
    /// treated as unanswered.
    ///
    /// Deliberately far past any search a person would wait for. Silence is
    /// normal in the *middle* of a grep — the host streams a batch per fifty
    /// hits, so a query matching nothing says nothing at all until it finishes —
    /// and a cold, large, or network-backed checkout can spend a long time
    /// there. This bound is not "the search is slow", it is "the host is not
    /// coming back": the case it exists for answers in milliseconds or never.
    static let searchIdleTimeoutSeconds = 90

    /// A file as it was on the device: its bytes, and the version they were read
    /// at. The version travels with the bytes because a reader that may later
    /// write them back has to be able to say *what it read* — asking again at
    /// save time would answer about a file that may already have changed.
    struct DeviceFile: Sendable {
        let data: Data
        /// Whole seconds since the epoch, and 0 when the host did not say — no
        /// version, so a save carrying it can make no claim and asks for none.
        let mtime: UInt64
    }

    /// One `fs.search` hit: a path relative to the searched root, the 1-based
    /// line it was found on, and that line's text.
    struct SearchHit: Sendable {
        let path: String
        let line: Int
        /// The matching line, or the host's window of a long one.
        let text: String
        /// Where the query hit inside `text`, as byte ranges the host measured
        /// with the rule it searched by. Empty from a host too old to say.
        let spans: [Range<Int>]
        /// Whether `text` is a window cut out of a longer line.
        let isWindowed: Bool
        let before: [String]
        let after: [String]
    }

    /// What one search answered. `limitHit` means the device stopped at the
    /// requested cap and more hits exist — the pane says so rather than passing
    /// off a truncated set as the whole answer.
    struct SearchResult: Sendable {
        let hits: [SearchHit]
        let limitHit: Bool
    }

    /// Lists directories under `root` on the device `route` leads to. Paths are
    /// absolute on that machine — the daemon confines them under `root` and
    /// echoes each one back, so the caller can key its tree by the string it
    /// asked with.
    ///
    /// A directory larger than one page (`files.rs` `LIST_PAGE_SIZE`, 2,000
    /// entries) is served a page at a time, and this reads to the end of it: a
    /// tree that stopped at the first page would show 2,000 of a `node_modules`
    /// and say nothing about the rest, which is the one failure a file browser
    /// must not have. Pages are asked for in lockstep — the host's `next_page` is
    /// always the one after the page served, so every directory still going is at
    /// the same page — and only the directories that reported more are re-asked.
    ///
    /// Blocking; call it off the main thread (`DeviceFileProvider` does).
    static func listDirectories(
        route: TermiodRoute, root: String, paths: [String]
    ) throws -> DirectoryListings {
        try withFilesChannel(route: route) { call in
            var order: [String] = []
            var listings: [String: DirectoryListing] = [:]
            var wanted = paths
            var page: UInt64?
            var seq: UInt64 = 0
            var rounds = 0
            while !wanted.isEmpty {
                let listed = try requestFiles(call, operation: "fs.list") { requestSeq in
                    FsListOperation(root: root, paths: wanted, page: page, seq: requestSeq)
                } match: { control in
                    if case .fsListed(let payload) = control { return payload }
                    return nil
                }
                // The cursor of the *last* page read: a listing is only as fresh
                // as its final request, and claiming the first page's cursor for
                // the whole would drop batches raised while the rest was read.
                seq = listed.seq
                var more: [String] = []
                for listing in listed.listings {
                    let entries = listing.entries.map(FileEntry.init(wire:))
                    if var held = listings[listing.path] {
                        held = DirectoryListing(
                            path: held.path,
                            entries: held.entries + entries,
                            error: held.error ?? listing.error)
                        listings[listing.path] = held
                    } else {
                        order.append(listing.path)
                        listings[listing.path] = DirectoryListing(
                            path: listing.path, entries: entries, error: listing.error)
                    }
                    if listing.nextPage != nil { more.append(listing.path) }
                }
                rounds += 1
                guard rounds < listPageCeiling else {
                    // Never silently: a directory this large is either pathological
                    // or growing under the read, and a tree that quietly stopped
                    // would read as the whole answer.
                    Log.files.error("""
                    fs.list stopped after \(listPageCeiling, privacy: .public) pages \
                    with \(more.count, privacy: .public) directories still unfinished
                    """)
                    break
                }
                wanted = more
                page = (page ?? 0) + 1
            }
            return DirectoryListings(listings: order.compactMap { listings[$0] }, seq: seq)
        }
    }

    /// How many pages of one `fs.list` are read before giving up. 100 pages is
    /// 200,000 entries in a single directory — far past anything real, and a
    /// bound only so a directory being written faster than it is read cannot
    /// loop forever.
    static let listPageCeiling = 100

    /// Reads a whole file from the device, for preview. Throws
    /// `DeviceFileError.tooLarge` rather than returning a prefix: a preview of
    /// the first megabyte of a binary is worse than saying the file is too big.
    ///
    /// The request carries no range, so the daemon reports the file's true
    /// `size` and serves at most its own 1 MiB cap (`files.rs` `READ_SOFT_CAP`)
    /// with `truncated` set. Both are checked — the size against this caller's
    /// limit, the flag against the device's.
    ///
    /// Blocking; call it off the main thread.
    static func readFile(
        route: TermiodRoute, path: String, limit: Int = filePreviewByteLimit
    ) throws -> DeviceFile {
        try withFilesChannel(route: route) { call in
            let header = try requestFiles(call, operation: "fs.read") { seq in
                FsReadOperation(path: path, seq: seq)
            } match: { control in
                if case .fsFile(let payload) = control { return payload }
                return nil
            }
            if header.truncated || header.size > UInt64(max(0, limit)) {
                throw DeviceFileError.tooLarge
            }
            var data = Data(capacity: Int(clamping: header.length))
            // `length` is the served window; a zero-length file sends no `F`
            // frame at all, so the loop must be able to run zero times.
            while UInt64(data.count) < header.length {
                let frame = try call.next(
                    timeoutSeconds: requestIdleTimeoutSeconds, operation: "fs.read")
                switch frame.kind {
                case .file:
                    let chunk = try decodeFileChunk(frame.payload)
                    data.append(chunk.data)
                    if chunk.last {
                        return DeviceFile(data: data, mtime: header.mtime)
                    }
                case .control:
                    if case .error(let failure) = try decodeControl(frame.payload) {
                        throw TermiodClientError.requestFailed(failure.message)
                    }
                default:
                    continue
                }
            }
            return DeviceFile(data: data, mtime: header.mtime)
        }
    }

    /// Searches file contents under `root` on the device `route` leads to: the
    /// host runs `git grep` and streams `search_results` events, closing with one
    /// `fs_searched` reply (§C.12).
    ///
    /// Unlike `fs.list` this is a stream, so the hits are collected here and
    /// handed over whole — the pane renders one result set per query, and a
    /// channel that lives only for this request cannot outlive it anyway.
    ///
    /// Bounded by an idle deadline rather than an overall one: a grep that walks
    /// a large checkout for a rare string is slow *and* correct, so what is
    /// waited on is the device saying nothing at all. That bound is what keeps a
    /// daemon too old to know `fs_search` — which drops the op silently instead
    /// of refusing it — from parking this thread and its connection forever.
    ///
    /// Blocking; call it off the main thread (`DeviceFileProvider` does).
    ///
    /// - Parameter idleTimeoutSeconds: the silence bound, a parameter only so a
    ///   test can hold a stub host silent without waiting the real one out.
    static func searchContents(
        route: TermiodRoute, root: String, query: String, limit: Int,
        idleTimeoutSeconds: Int = searchIdleTimeoutSeconds
    ) throws -> SearchResult {
        // Nothing to ask for, and the host would answer one hit anyway: it
        // appends before it compares against the cap.
        guard limit > 0 else { return SearchResult(hits: [], limitHit: false) }
        return try withFilesChannel(route: route) { call in
            try call.send(payload: encodeControl(FsSearchOperation(
                root: root, query: query, limit: UInt64(limit), seq: call.seq)))
            // Armed the moment the request is on the wire: from here until the
            // host's terminal reply, every way out of this closure — the idle
            // bound, a lost pipe, a thrown decode — is a `git grep` still
            // walking a checkout on someone else's machine.
            call.cancelIfAbandoned()
            var hits: [SearchHit] = []
            while true {
                let frame = try call.next(
                    timeoutSeconds: idleTimeoutSeconds, operation: "fs.search")
                switch frame.kind {
                case .event:
                    guard case .searchResults(let payload) = try decodeEvent(frame.payload)
                    else { continue }
                    hits.append(contentsOf: payload.matches.map { match in
                        SearchHit(
                            path: match.path,
                            line: Int(clamping: match.line),
                            text: match.text,
                            // Pairs, as the host sends them; anything else is a
                            // host disagreeing with the protocol and is dropped
                            // rather than turned into a wrong highlight.
                            spans: match.spans.compactMap { span in
                                guard span.count == 2, span[0] <= span[1] else { return nil }
                                return Int(span[0]) ..< Int(span[1])
                            },
                            isWindowed: match.textOffset > 0,
                            before: match.before,
                            after: match.after)
                    })
                case .control:
                    switch try decodeControl(frame.payload) {
                    case .fsSearched(let payload):
                        // The host's last word, whether it finished, hit the cap
                        // or was already stopped: nothing left to cancel.
                        call.completed()
                        return SearchResult(hits: hits, limitHit: payload.limitHit)
                    case .error(let failure):
                        // A refusal the host has already cleaned up behind — no
                        // grep is running, so cancelling would name nothing.
                        call.completed()
                        throw TermiodClientError.requestFailed(failure.message)
                    default:
                        continue
                    }
                default:
                    continue
                }
            }
        }
    }

    /// How long a listing or a read may go without the device saying anything
    /// before the request is treated as unanswered.
    ///
    /// A one-shot channel needed no such bound: the process it hung off died and
    /// took the wait with it. A pooled one outlives its requests, so a request
    /// that would once have ended with the connection now has to end on its own
    /// clock — and a pipe that stops answering must not park the thread that
    /// asked. Generous, because a cold directory on a slow disk is slow and
    /// correct; this bounds silence, not work. `fs.search` keeps its own, much
    /// longer bound: a grep is *expected* to say nothing for a long time.
    static let requestIdleTimeoutSeconds = 30

    /// Runs `body` against the device's pooled `files` channel, refusing up front
    /// on a daemon that did not grant the capability — the pane then says the
    /// device cannot serve files rather than hanging on a reply that never comes.
    private static func withFilesChannel<Result>(
        route: TermiodRoute, _ body: (ChannelCall) throws -> Result
    ) throws -> Result {
        try withPooledRequest(route: route, caps: ["files"]) { call, channel in
            guard channel.capabilities.contains("files") else {
                throw DeviceFileError.unsupported
            }
            return try body(call)
        }
    }

    /// Sends one request and waits for the reply that matches, skipping frames
    /// that do not. `build` takes the call's own `seq` rather than a fixed 1:
    /// that id is what the daemon stamps every answering frame with, and on a
    /// shared channel it is the only thing that tells this reply from the one
    /// belonging to the expand happening alongside it.
    private static func requestFiles<Operation: Encodable, Reply>(
        _ call: ChannelCall,
        operation name: String,
        build: (UInt64) -> Operation,
        match: (IncomingControl) -> Reply?
    ) throws -> Reply {
        try call.send(payload: encodeControl(build(call.seq)))
        while true {
            let frame = try call.next(
                timeoutSeconds: requestIdleTimeoutSeconds, operation: name)
            guard frame.kind == .control else { continue }
            let control = try decodeControl(frame.payload)
            if let reply = match(control) { return reply }
            if case .error(let failure) = control {
                throw TermiodClientError.requestFailed(failure.message)
            }
        }
    }
}

/// What can go wrong reading a device's files, in the vocabulary the pane shows.
/// Deliberately small: the daemon's own message rides
/// `TermiodClientError.requestFailed`, and this covers only the cases the client
/// decides for itself.
enum DeviceFileError: Error, Equatable {
    /// The daemon did not grant the `files` capability — too old, or built
    /// without it.
    case unsupported
    /// The device served less than the whole file, so this is not a preview.
    case tooLarge
    /// A name the tree refuses to build a path from.
    case unsafeName
    case notRegularFile
    /// The device refused the save because what it would replace changed after
    /// this client read it. Carries the host's own sentence, which names both
    /// versions. Not a failure so much as a question for the person typing.
    case conflict(String)
}

extension FileEntry {
    /// One `fs.list` row. `unloaded_dir` is a directory the host will not walk on
    /// its own (VCS internals) — still a directory to the tree, which filters
    /// those names anyway (`FileEntry.ignoredNames`).
    init(wire entry: Termiod.DirEntryPayload) {
        self.init(
            name: entry.name,
            kind: Kind(wire: entry.kind) ?? .other,
            target: entry.targetKind.flatMap(Kind.init(wire:)),
            symlinkTarget: entry.symlinkTarget)
    }
}

extension FileEntry.Kind {
    /// The wire's `EntryKind`. `unloaded_dir` is still a directory to the tree,
    /// which filters those names anyway (`FileEntry.ignoredNames`); a kind this
    /// build has never heard of is `nil` rather than a guess.
    init?(wire kind: String) {
        switch kind {
        case "dir", "unloaded_dir": self = .directory
        case "file": self = .file
        case "symlink": self = .symlink
        default: return nil
        }
    }
}

/// The tree's async seam onto the blocking verbs above. One per pane, so a
/// device that stops answering blocks only its own pane.
///
/// The work runs on a global queue rather than in an actor: a request blocks on
/// a network round trip, and blocking a cooperative pool thread for one is
/// exactly what that pool is not for.
struct DeviceFileProvider: Sendable {
    let route: TermiodRoute
    /// The checkout root every request is confined under, so a listing can never
    /// walk out of the directory the pane is rooted at — the daemon enforces it
    /// (`files.rs` `confine`), and passing the tree's own root is what arms that.
    let root: String

    func list(_ path: String) async throws -> [FileEntry] {
        let listings = try await list([path])
        guard let listing = listings.first else { return [] }
        if let error = listing.error {
            throw TermiodClientError.requestFailed(error)
        }
        return listing.entries
    }

    /// Several directories in **one** request, which is the shape `fs.list` was
    /// given a `paths` array for: the protocol asks a client to name a rendered
    /// directory together with the visible directories under it, rather than
    /// walking the tree a round trip at a time.
    ///
    /// It is the difference between one round trip and N. Measured against a VPS
    /// with a nine-directory checkout open: 339 ms one directory at a time,
    /// 44 ms asked together — and on the pooled channel, 12 ms.
    ///
    /// Failures are per path, not per request: a directory that vanished carries
    /// its own `error` and the rest of the listings still land. Callers key the
    /// result by `path`, which the daemon echoes back exactly as asked.
    func list(_ paths: [String]) async throws -> [Termiod.DirectoryListing] {
        try await listing(paths).listings
    }

    /// The same request, with the `fs:` cursor the answer was taken at. The tree
    /// uses this one: without the cursor it cannot tell a batch its listing
    /// already includes from one raised after it, and would re-list on every
    /// change it had just finished reading.
    func listing(_ paths: [String]) async throws -> Termiod.DirectoryListings {
        guard !paths.isEmpty else {
            return Termiod.DirectoryListings(listings: [], seq: 0)
        }
        return try await run { [route, root] in
            try Termiod.listDirectories(route: route, root: root, paths: paths)
        }
    }

    /// Subscribes to this checkout's `fs:` resource. Held by the tree for as
    /// long as its pane is alive; releasing it retires the watch.
    func watch(
        onUpdate: @escaping @Sendable (Termiod.ResourceWatch.Update) -> Void
    ) -> Termiod.ResourceWatch {
        Termiod.ResourceWatch(
            route: route, caps: ["files", Termiod.ResourceWatch.capability],
            resource: "fs:" + root, onUpdate: onUpdate)
    }

    /// Content search under the pane's own root, on the device. Confined the same
    /// way a listing is: the daemon canonicalises `root` and greps nothing above it.
    func search(_ query: String, limit: Int) async throws -> Termiod.SearchResult {
        try await run { [route, root] in
            try Termiod.searchContents(
                route: route, root: root, query: query, limit: limit)
        }
    }

    func read(_ path: String, limit: Int) async throws -> Termiod.DeviceFile {
        try await run { [route] in
            try Termiod.readFile(route: route, path: path, limit: limit)
        }
    }

    /// Writes `data` back to `path` on the device, replacing what is there.
    ///
    /// `ifUnmodifiedSince` is the version the caller read; the host refuses the
    /// commit if the file has moved on since, and that refusal arrives as
    /// `DeviceFileError.conflict`. The write is confined to this provider's own
    /// root, so a pane can only ever save inside the checkout it is showing.
    /// - Returns: the version the write produced, for the next save to claim.
    func write(
        _ path: String, data: Data, ifUnmodifiedSince: UInt64?
    ) async throws -> UInt64 {
        try await run { [route, root] in
            try Termiod.writeFile(
                route: route, root: root, path: path, data: data,
                ifUnmodifiedSince: ifUnmodifiedSince)
        }
    }

    private func run<Value: Sendable>(
        _ body: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try body() })
            }
        }
    }
}
