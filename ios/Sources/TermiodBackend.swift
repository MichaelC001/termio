import CryptoKit
import Foundation
import TermioShared

/// `DeviceClient` over the termiod Session Protocol: the phone talking straight
/// to the box a session runs on, with no Mac in the path.
///
/// The screens above this are the same ones the companion wire feeds — that is
/// the point of the port (`docs/design/20260824-ios-as-device-client.md` D1).
/// What differs is everything below: one control channel carrying `list`,
/// `attach`, `kill` and the `fs.*` plane, and a roster the client *builds*,
/// because the daemon holds sessions and has never heard of a project.
///
/// Where a plane does not exist over here it says so. Nothing in this file
/// answers a question with an empty list: `onChanges?([])` would read as "no
/// changes", which is a different sentence from "this device has no git plane".
final class TermiodBackend: DeviceClient {
    var onRoster: ((DeviceRoster) -> Void)?
    var onConnected: ((Bool) -> Void)?
    var onError: ((String) -> Void)?
    var onConnectionFailure: ((String) -> Void)?
    var onStarted: ((String, String?) -> Void)?
    var onFileList: ((String, [DeviceFileEntry]) -> Void)?
    var onFile: ((DeviceFile) -> Void)?
    var onWritten: ((String, Int) -> Void)?
    var onUploaded: ((String) -> Void)?
    var onSearchResults: ((String, [String], Bool) -> Void)?
    var onChanges: (([DeviceChange]) -> Void)?
    var onDiff: ((DeviceDiff) -> Void)?
    var onSSHHosts: (([DeviceSSHHost]) -> Void)?

    /// How many filename hits one search asks for. The host stops there and the
    /// caller is told the batch was capped, rather than the field quietly
    /// showing a slice of a monorepo as if it were everything.
    private static let searchLimit: UInt64 = 200

    private let endpoint: DeviceEndpoint
    /// The session this backend serves, when it serves one. Only the upload
    /// plane needs it: a transfer into a session's scratch directory is reaped
    /// with that session, so there is nowhere to put a paste without one.
    private let sessionID: String?
    private let channel: TermiodChannel
    /// Every live session the device has reported, keyed by its id. Seeded by
    /// `list` and kept current by `roster` / `status` events — pushed, never
    /// polled, which is the same contract the companion roster has.
    private var sessionsByID: [String: Termiod.SessionInformation] = [:]
    private var sessionOrder: [String] = []
    /// Status the device revised since the row it belongs to was last delivered
    /// whole. Held beside the rows rather than merged into them because a row is
    /// what the device said, and a delta is what it said after — folding the two
    /// would lose which is which the moment a fresh row arrives.
    private var statusOverrides: [String: StatusDelta] = [:]
    private var hostID: String?
    /// Requests in flight, keyed by the `re` each was sent with.
    ///
    /// Every reply the daemon sends echoes that id — `Termiod.responseID(of:)`
    /// reads it off a control payload, and `decodeFileChunk` carries it on the
    /// bytes behind an `fs_read` — so a reply reaches the caller that asked
    /// rather than the one that asked first. Order used to be the only thing
    /// matching them, which held solely because this backend issued one request
    /// per verb at a time; two in flight and the second reply landed on the
    /// first caller.
    private var pendingReads: [UInt64: String] = [:]
    private var pendingSearches: [UInt64: String] = [:]
    /// Reads past their header, keyed the same way: the `fs_file` header and the
    /// `F` chunks landing behind it. Several can stream at once without their
    /// bytes interleaving into each other's file.
    private var readsInProgress:
        [UInt64: (path: String, header: Termiod.FsFilePayload, data: Data)] = [:]
    /// Transfers waiting on the daemon's credit-of-one acks, keyed by upload id
    /// once `upload_opened` names one. The first entry is the one being opened.
    private var transfers: [Transfer] = []
    private var seq: UInt64 = 1

    /// One file crossing to the device — an edit being saved, or a photo being
    /// pasted into a prompt.
    private struct Transfer {
        enum Destination {
            /// A save into the checkout, conflict-checked against the version
            /// the editor read.
            case file(path: String, root: String, baseModifiedSeconds: UInt64?)
            /// The session's scratch directory, reaped when the session dies.
            case scratch(name: String)
        }

        let destination: Destination
        let data: Data
        var uploadID: String?
        var offset: UInt64 = 0
        /// The `re` this transfer's `upload_open` and `upload_commit` went out
        /// with. Transfers stay strictly sequential — that is the credit-of-one
        /// design, not an accident — so these do not multiplex anything; they
        /// are what stops a late reply from a transfer already abandoned from
        /// shifting the queue under the one now at its head.
        var openRequest: UInt64?
        var commitRequest: UInt64?
    }

    init(endpoint: DeviceEndpoint, sessionID: String? = nil) {
        self.endpoint = endpoint
        self.sessionID = sessionID
        channel = TermiodChannel(
            endpoint: endpoint, name: "device", role: "control",
            capabilities: Termiod.deviceCapabilities, delegateQueue: .main
        )
        channel.onReady = { [weak self] handshake in self?.handshakeLanded(handshake) }
        channel.onControl = { [weak self] reply in self?.receive(reply) }
        channel.onEvent = { [weak self] event in self?.receive(event) }
        channel.onFileChunk = { [weak self] payload in self?.receiveFileChunk(payload) }
        channel.onLinkState = { [weak self] up in
            guard let self else { return }
            if !up { forgetInFlight() }
            onConnected?(up)
        }
        channel.onFailure = { [weak self] reason in self?.onConnectionFailure?(reason) }
    }

    func start() { channel.start() }

    func stop() { channel.stop() }

    func reconnectNow() { channel.reconnectNow() }

    // MARK: - Sessions

    func startSession(projectID: String, agentID: String) {
        guard let root = root(ofProjectID: projectID) else {
            onError?(localized("That project isn't on this device."))
            return
        }
        // A loose chat belongs to no checkout, so its workstream carries no
        // project — that empty project is exactly what files it under Chats
        // rather than inventing a folder named after its scratch directory.
        let isLooseChat = projectID == TermiodRoster.chatsProjectID
        create(
            // The scratch root will not exist on a box nobody has started a chat
            // on, and a spawn into a missing directory is refused. Creating it
            // is what `TermioStore.ensureLooseChatRoot` does on the desktop,
            // and it has to happen over there, so the shell does it on the way
            // in rather than the cwd asking for a directory nobody made.
            cwd: isLooseChat ? channel.homeDirectory : root,
            argv: isLooseChat
                ? TermiodAgentLaunch.looseChatArgv(forAgent: agentID, root: root)
                : TermiodAgentLaunch.argv(forAgent: agentID),
            workstream: Termiod.WorkstreamSpecification(
                agentId: agentID, project: isLooseChat ? "" : root),
            agentID: agentID
        )
    }

    func startTerminal(workspaceID _: String?) {
        // One device is one workspace here, so there is nothing to route by. No
        // workstream and no agent is what makes this a loose shell, and it
        // spawns at `$HOME` the way opening a new terminal window does.
        create(
            cwd: TermiodRoster.looseTerminalRoot(homeDirectory: channel.homeDirectory),
            argv: [], workstream: nil, agentID: nil
        )
    }

    func startSSH(host: String, workspaceID _: String?) {
        // The Mac reads `~/.ssh/config` and offers what it finds; the Session
        // Protocol has no verb for that, so there is no list to have picked from
        // and nothing here can honour a choice made against one.
        onError?(localized("Termio can't open an SSH session on \(host) from a device connection."))
    }

    func stopSession(id: String) {
        do {
            channel.send(kind: .control, payload: try Termiod.killPayload(
                target: id, seq: nextSeq()))
        } catch {
            report(error, doing: localized("Couldn't close that session."))
        }
    }

    func requestSSHHosts() {
        onError?(localized("This device doesn't report its SSH hosts."))
    }

    /// The device's Chats container, which needs no finding-or-creating: it is
    /// one per box and `startSession` resolves this id to the scratch directory
    /// a loose agent belongs in.
    func looseChatsContainerID(workspaceID _: String) -> String? {
        TermiodRoster.chatsProjectID
    }

    /// The device path a container id addresses. A folder carries its own; the
    /// two loose containers spawn at roots that depend on the account's home
    /// directory, which only the handshake knows.
    private func root(ofProjectID id: String) -> String? {
        if let root = TermiodRoster.root(ofProjectID: id) { return root }
        let home = channel.homeDirectory
        switch id {
        case TermiodRoster.terminalsProjectID:
            return TermiodRoster.looseTerminalRoot(homeDirectory: home)
        case TermiodRoster.chatsProjectID:
            return TermiodRoster.looseChatRoot(homeDirectory: home)
        default:
            return nil
        }
    }

    /// `attach` with `create_if_missing` is the only spawn verb the protocol
    /// has, so starting a session means attaching to a name that does not exist
    /// yet and then stepping back off it — the terminal screen opens its own
    /// attachment a moment later.
    private func create(
        cwd: String,
        argv: [String],
        workstream: Termiod.WorkstreamSpecification?,
        agentID: String?
    ) {
        let name = UUID().uuidString
        let starter = TermiodChannel(
            endpoint: endpoint, name: "start", role: "attach",
            capabilities: Termiod.attachCapabilities, delegateQueue: .main
        )
        // A link self-heals rather than giving up, which is right for a session
        // and wrong for a request someone is waiting on: a device that never
        // answers has to become a refusal instead of a channel dialling forever
        // behind a ＋ that looks like it did nothing.
        let deadline = DispatchWorkItem { [weak self] in
            Self.retire(starter)
            self?.onError?(localized("That device didn't answer."))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: deadline)
        // Held by its own callbacks until the attach is answered; the closures
        // are the only owner, so clearing them is what frees it.
        starter.onReady = { [weak self] _ in
            guard let self else { return }
            do {
                starter.send(kind: .control, payload: try Termiod.attachPayload(
                    target: name,
                    specification: Termiod.CreateSpecification(
                        cwd: cwd, argv: argv,
                        env: TermiodAgentLaunch.presentationEnvironment,
                        rows: 24, cols: 80,
                        workstream: workstream
                    ),
                    rows: 24, cols: 80
                ))
            } catch {
                deadline.cancel()
                Self.retire(starter)
                report(error, doing: localized("Couldn't start that session."))
            }
        }
        starter.onControl = { [weak self] reply in
            guard let self else { return }
            switch reply.control {
            case .attached:
                deadline.cancel()
                // Leave the stream without killing what was just created; the
                // screen that opens next attaches for real.
                if let payload = try? Termiod.detachPayload() {
                    starter.send(kind: .control, payload: payload)
                }
                Self.retire(starter)
                onStarted?(name, agentID)
            case .error(let refusal):
                deadline.cancel()
                Self.retire(starter)
                onError?(refusal.message)
            default:
                break
            }
        }
        starter.onFailure = { [weak self] reason in
            deadline.cancel()
            Self.retire(starter)
            self?.onError?(reason)
        }
        starter.start()
    }

    /// Drops a one-shot channel and the closure cycle keeping it alive.
    private static func retire(_ channel: TermiodChannel) {
        channel.onReady = nil
        channel.onControl = nil
        channel.onFailure = nil
        channel.onLinkState = nil
        channel.stop()
    }

    // MARK: - Files

    func listFiles(projectID: String, path: String) {
        guard let root = root(ofProjectID: projectID) else {
            onError?(localized("That project isn't on this device."))
            return
        }
        do {
            try channel.send(control: Termiod.FsListOperation(
                root: root, paths: [path], seq: nextSeq()))
        } catch {
            report(error, doing: localized("Couldn't list that folder."))
        }
    }

    func readFile(projectID: String, path: String, darkAppearance _: Bool) {
        guard let root = root(ofProjectID: projectID) else {
            onError?(localized("That project isn't on this device."))
            return
        }
        // No rendered preview: `fs_read` answers with the file's bytes and the
        // device has no Markdown renderer to ask. The viewer falls back to
        // showing the source, which is what it does for every other file type.
        //
        // The device is addressed absolutely and answered relatively: the reply
        // carries back the path the caller asked for, and a save sends that same
        // path straight back.
        let request = nextSeq()
        pendingReads[request] = path
        do {
            try channel.send(control: Termiod.FsReadOperation(
                path: Self.absolutePath(root: root, path: path), seq: request))
        } catch {
            pendingReads[request] = nil
            report(error, doing: localized("Couldn't open that file."))
        }
    }

    func writeFile(projectID: String, path: String, data: Data, baseModifiedMilliseconds: Int) {
        guard let root = root(ofProjectID: projectID) else {
            onError?(localized("That project isn't on this device."))
            return
        }
        // The host's version is whole seconds; a millisecond base rounded down
        // is the same instant it reported, so a save it accepted still matches.
        let base = baseModifiedMilliseconds > 0
            ? UInt64(baseModifiedMilliseconds / 1000) : nil
        enqueue(Transfer(
            destination: .file(
                path: Self.absolutePath(root: root, path: path),
                root: root,
                baseModifiedSeconds: base
            ),
            data: data
        ))
    }

    func searchFiles(projectID: String, query: String) {
        guard let root = root(ofProjectID: projectID) else {
            onError?(localized("That project isn't on this device."))
            return
        }
        // `fs_match` and not `fs_search`: this field searches *names*, and
        // `fs_search` is the device's content search (`git grep`). Wiring one to
        // the other would answer a different question than the one asked.
        //
        // Nothing is cancelled when a query is abandoned, and nothing needs to
        // be: `fs_match` is one reply off an index the host already holds, and
        // only `fs_search` registers a cancellable request (`daemon.rs`, the
        // `Control::Cancel` arm). That changes the day this pane gains content
        // search — an abandoned `fs_search` leaves `git grep` running until the
        // connection drops, and `Termiod.CancelOperation` is what stops it.
        let request = nextSeq()
        pendingSearches[request] = query
        do {
            try channel.send(control: Termiod.FsMatchOperation(
                root: root, query: query, limit: Self.searchLimit, seq: request))
        } catch {
            pendingSearches[request] = nil
            report(error, doing: localized("Couldn't search this project."))
        }
    }

    func upload(projectID _: String, name: String, data: Data) {
        // A paste lands in the session's scratch directory, which the device
        // reaps when that session dies — so a screenshot never outlives the
        // conversation it belonged to. Without a session there is nowhere for it
        // to go that would be cleaned up.
        guard sessionID != nil else {
            onError?(localized("Attaching a file needs an open session on this device."))
            return
        }
        enqueue(Transfer(destination: .scratch(name: name), data: data))
    }

    // MARK: - Git

    func listChanges(projectID _: String) {
        onChangesUnavailable()
    }

    func readDiff(projectID _: String, path _: String, status _: String) {
        onChangesUnavailable()
    }

    private func onChangesUnavailable() {
        onError?(localized("Working-tree changes aren't available over a device connection yet."))
    }

    // MARK: - Roster

    private func handshakeLanded(_ handshake: Termiod.HelloOkPayload) {
        // The device's own identity, and the only one the roster is keyed by:
        // `client_id` names this connection and changes on every reconnect.
        hostID = handshake.hostId
        do {
            // `roster` also carries `writer_changed` and `session_exited`, which
            // is why two names cover everything the list needs.
            channel.send(kind: .control, payload: try Termiod.subscribePayload(
                events: ["roster", "status"], seq: nextSeq()))
            channel.send(kind: .control, payload: try Termiod.listPayload(seq: nextSeq()))
        } catch {
            report(error, doing: localized("Couldn't read this device's sessions."))
        }
    }

    /// Routes one reply to the request that caused it.
    ///
    /// Not private so the routing can be driven with real replies: which of
    /// several in-flight requests an arriving frame lands on is the kind of
    /// thing that goes wrong silently, and a socket is not needed to prove it.
    func receive(_ reply: TermiodChannel.Reply) {
        switch reply.control {
        case .sessions(let payload):
            sessionOrder = payload.sessions.map(\.id)
            sessionsByID = Dictionary(
                payload.sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            statusOverrides.removeAll()
            publishRoster()
        case .fsListed(let payload):
            receiveListings(payload)
        case .fsFile(let header):
            receiveFileHeader(header, responseID: reply.responseID)
        case .fsMatched(let payload):
            receiveMatches(payload, responseID: reply.responseID)
        case .uploadOpened(let opened):
            receiveUploadOpened(opened, responseID: reply.responseID)
        case .uploadAck(let ack):
            receiveUploadAck(ack)
        case .uploadCommitted(let committed):
            receiveUploadCommitted(committed, responseID: reply.responseID)
        case .error(let failure):
            failInFlight(failure.message, responseID: reply.responseID)
        default:
            break
        }
    }

    /// Which outstanding request a reply belongs to.
    ///
    /// The `re` names it outright. A reply that carries none — a daemon too old
    /// to stamp them — can still be placed when exactly one request of that verb
    /// is waiting, because then there is nothing to confuse it with. Two waiting
    /// and no `re` is genuinely ambiguous, and guessing there is the behaviour
    /// this correlation exists to end.
    private func request<Value>(for responseID: UInt64?, in waiting: [UInt64: Value]) -> UInt64? {
        if let responseID { return waiting[responseID] != nil ? responseID : nil }
        return waiting.count == 1 ? waiting.keys.first : nil
    }

    private func receive(_ event: Termiod.IncomingEvent) {
        switch event {
        case .roster(let update):
            if let information = update.info {
                if sessionsByID[information.id] == nil { sessionOrder.append(information.id) }
                sessionsByID[information.id] = information
                // A whole row is the device's current word on this session, so
                // it retires the delta that was standing in for one.
                statusOverrides[information.id] = nil
            } else if update.action == "removed" {
                forget(update.session)
            } else {
                // An arrival notice with no row: the `list` that answers it is
                // what fills the gap, and there is nothing to redraw yet.
                return
            }
            publishRoster()
        case .status(let status):
            guard sessionsByID[status.session] != nil else { return }
            statusOverrides[status.session] = StatusDelta(
                status: status.status, title: status.title)
            publishRoster()
        case .sessionExited(let exit):
            forget(exit.session)
            publishRoster()
        default:
            break
        }
    }

    private func publishRoster() {
        // No identity yet means no workspace id, and a roster whose workspace
        // ids churn between pushes would reshuffle every list on screen.
        guard let hostID else { return }
        let live = sessionOrder.compactMap { sessionsByID[$0] }
        onRoster?(DeviceRoster(
            hostID: hostID,
            projects: TermiodRoster.projects(
                from: live, homeDirectory: channel.homeDirectory),
            statusOverrides: statusOverrides
        ))
    }

    private func receiveListings(_ payload: Termiod.FsListedPayload) {
        for listing in payload.listings {
            if let failure = listing.error {
                onError?(failure)
                continue
            }
            onFileList?(listing.path, listing.entries.map {
                // Nothing marks a device entry as changed: that flag comes from
                // the working diff, which is the git plane this connection does
                // not have.
                DeviceFileEntry(name: $0.name, isDirectory: $0.isDirectory)
            })
        }
    }

    private func receiveFileHeader(_ header: Termiod.FsFilePayload, responseID: UInt64?) {
        guard let request = request(for: responseID, in: pendingReads),
              let path = pendingReads.removeValue(forKey: request)
        else { return }
        guard header.length > 0 else {
            deliver(path: path, header: header, data: Data())
            return
        }
        readsInProgress[request] = (path, header, Data())
    }

    /// Not private for the same reason `receive(_:)` is not: the bytes behind
    /// one read landing in another read's file is silent when it happens.
    func receiveFileChunk(_ payload: Data) {
        let chunk: (request: UInt64, offset: UInt64, last: Bool, data: Data)
        do {
            chunk = try Termiod.decodeFileChunk(payload)
        } catch {
            // The header is what says which read a chunk belongs to, so an
            // unreadable one cannot be attributed. Every read in flight is
            // abandoned rather than left waiting on a stream that has stopped
            // making sense.
            readsInProgress.removeAll()
            report(error, doing: localized("Couldn't read that file."))
            return
        }
        // A chunk names its read, so the bytes of two files streaming at once
        // never interleave into one.
        guard var pending = readsInProgress[chunk.request] else { return }
        pending.data.append(chunk.data)
        readsInProgress[chunk.request] = pending
        guard chunk.last || UInt64(pending.data.count) >= pending.header.length else { return }
        readsInProgress[chunk.request] = nil
        deliver(path: pending.path, header: pending.header, data: pending.data)
    }

    private func deliver(path: String, header: Termiod.FsFilePayload, data: Data) {
        onFile?(DeviceFile(
            path: path,
            data: data,
            size: Int(clamping: header.size),
            // The host reports bytes and says nothing about what they are, so
            // the classification is this side's: a NUL in the first block is
            // what every diff tool calls binary.
            isBinary: data.prefix(8 << 10).contains(0),
            isTruncated: header.truncated,
            modifiedMilliseconds: Int(clamping: header.mtime) * 1000
        ))
    }

    private func receiveMatches(_ payload: Termiod.FsMatchedPayload, responseID: UInt64?) {
        guard let request = request(for: responseID, in: pendingSearches),
              let query = pendingSearches.removeValue(forKey: request)
        else { return }
        guard !payload.indexIsMissing else {
            // Zero hits at zero coverage means the device never indexed this
            // checkout — reporting that as "no matches" would be a lie about
            // the repository rather than about the connection.
            onError?(localized("This device hasn't indexed this project's filenames."))
            return
        }
        onSearchResults?(query, payload.paths, payload.paths.count >= Int(Self.searchLimit))
    }

    // MARK: - Transfers

    private func enqueue(_ transfer: Transfer) {
        transfers.append(transfer)
        guard transfers.count == 1 else { return }
        openNextTransfer()
    }

    private func openNextTransfer() {
        guard let transfer = transfers.first else { return }
        let digest = SHA256.hash(data: transfer.data)
            .map { String(format: "%02x", $0) }.joined()
        let request = nextSeq()
        transfers[0].openRequest = request
        let operation: Termiod.UploadOpenOperation
        switch transfer.destination {
        case .file(let path, let root, _):
            operation = Termiod.UploadOpenOperation(
                dest: path, root: root,
                size: UInt64(transfer.data.count), sha256: digest, seq: request)
        case .scratch(let name):
            operation = Termiod.UploadOpenOperation(
                dest: "temp:\(name)", session: sessionID,
                size: UInt64(transfer.data.count), sha256: digest, seq: request)
        }
        do {
            try channel.send(control: operation)
        } catch {
            transfers.removeFirst()
            report(error, doing: localized("Couldn't send that file to the device."))
            openNextTransfer()
        }
    }

    private func receiveUploadOpened(_ opened: Termiod.UploadOpenedPayload, responseID: UInt64?) {
        guard !transfers.isEmpty else { return }
        // A reply naming an open this queue has moved past belongs to a transfer
        // already abandoned; honouring it would hand the head transfer someone
        // else's upload id and send its bytes to the wrong file.
        guard responseID == nil || responseID == transfers[0].openRequest else { return }
        transfers[0].uploadID = opened.uploadId
        transfers[0].offset = opened.offset
        sendNextChunk()
    }

    /// One chunk per ack — the daemon's credit-of-one, which is what keeps a
    /// transfer from starving the keystrokes sharing this connection.
    private func sendNextChunk() {
        guard let transfer = transfers.first, let uploadID = transfer.uploadID else { return }
        let start = Int(clamping: transfer.offset)
        guard start < transfer.data.count else {
            commit(transfer, uploadID: uploadID)
            return
        }
        let end = min(start + Termiod.maximumDataFrameSize, transfer.data.count)
        channel.send(kind: .upload, payload: Termiod.uploadChunkPayload(
            uploadID: uploadID, offset: transfer.offset,
            data: transfer.data.subdata(in: start ..< end)))
    }

    private func receiveUploadAck(_ ack: Termiod.UploadAckPayload) {
        guard !transfers.isEmpty, transfers[0].uploadID == ack.uploadId else { return }
        transfers[0].offset = ack.offset
        sendNextChunk()
    }

    private func commit(_ transfer: Transfer, uploadID: String) {
        // Only ever reached with the head transfer, but the subscript below is
        // what would trap if that ever stopped being true.
        guard !transfers.isEmpty else { return }
        let base: UInt64?
        switch transfer.destination {
        case .file(_, _, let baseModifiedSeconds): base = baseModifiedSeconds
        case .scratch: base = nil
        }
        let request = nextSeq()
        transfers[0].commitRequest = request
        do {
            try channel.send(control: Termiod.UploadCommitOperation(
                uploadId: uploadID, ifUnmodifiedSince: base, seq: request))
        } catch {
            transfers.removeFirst()
            report(error, doing: localized("Couldn't save that file on the device."))
            openNextTransfer()
        }
    }

    private func receiveUploadCommitted(
        _ committed: Termiod.UploadCommittedPayload, responseID: UInt64?
    ) {
        guard !transfers.isEmpty else { return }
        // Same reason as `upload_opened`: a commit this queue has moved past
        // would otherwise pop the transfer now at its head and report the wrong
        // file as saved.
        guard responseID == nil || responseID == transfers[0].commitRequest else { return }
        let transfer = transfers.removeFirst()
        switch transfer.destination {
        case .file(let path, _, _):
            onWritten?(path, Int(clamping: committed.mtime) * 1000)
        case .scratch:
            onUploaded?(committed.path)
        }
        openNextTransfer()
    }

    // MARK: - Failure

    /// A device refusal names the request it answers, so it fails that caller
    /// and leaves everything else in flight alone.
    ///
    /// It used to be attributed to whatever this connection had outstanding,
    /// newest concern first — which meant a refused search could cancel a read
    /// that was still perfectly alive, and the read would then hang until the
    /// socket dropped.
    private func failInFlight(_ message: String, responseID: UInt64?) {
        defer { onError?(message) }
        guard let responseID else {
            // `re` is absent on the connection-level refusals (a protocol error,
            // a denied capability). Those belong to no one request, so nothing
            // is retired — but the reason still has to reach the screen, which
            // is what the `defer` above guarantees on every path here.
            return
        }
        if pendingReads.removeValue(forKey: responseID) != nil { return }
        if readsInProgress.removeValue(forKey: responseID) != nil { return }
        if pendingSearches.removeValue(forKey: responseID) != nil { return }
        guard let index = transfers.firstIndex(where: {
            $0.openRequest == responseID || $0.commitRequest == responseID
        }) else { return }
        transfers.remove(at: index)
        // Only the head transfer is ever on the wire, so a refused one has to
        // hand the queue on or everything behind it stalls.
        if index == 0 { openNextTransfer() }
    }

    /// A dropped socket takes every in-flight request with it. Left in place,
    /// a reply on the next connection could carry an id this one had already
    /// handed out, and land on a request nobody is waiting for any more.
    private func forgetInFlight() {
        pendingReads.removeAll()
        pendingSearches.removeAll()
        readsInProgress.removeAll()
        transfers.removeAll()
    }

    private func forget(_ sessionID: String) {
        sessionsByID[sessionID] = nil
        statusOverrides[sessionID] = nil
        sessionOrder.removeAll { $0 == sessionID }
    }

    private func report(_ error: Error, doing what: String) {
        Log.device.error("""
        \(what, privacy: .public): \(error.localizedDescription, privacy: .public)
        """)
        onError?(what)
    }

    private func nextSeq() -> UInt64 {
        seq &+= 1
        return seq
    }

    /// Join a project root and a root-relative path. "" is the root itself,
    /// which is what the file pane asks for first.
    private static func absolutePath(root: String, path: String) -> String {
        path.isEmpty ? root : (root as NSString).appendingPathComponent(path)
    }
}

// MARK: - Pairing

/// A pairing dial that did not reach a device, carrying whatever said so — the
/// daemon's own refusal, or the fact that nothing answered at all.
struct DeviceUnreachable: Error {
    let message: String
}

extension TermiodBackend {
    /// D4's verify step: dial once, wait for `hello_ok`, and hand back the
    /// device's own `host_id`. Nothing is written to the paired list until this
    /// answers — saving an unverified address is what produced the companion's
    /// worst failure mode, paired and silently unreachable.
    ///
    /// `completion` runs on the main queue, exactly once.
    static func verify(
        endpoint: DeviceEndpoint, completion: @escaping (Result<String, DeviceUnreachable>) -> Void
    ) {
        let channel = TermiodChannel(
            endpoint: endpoint, name: "pair", role: "control",
            capabilities: Termiod.controlCapabilities, delegateQueue: .main
        )
        var answered = false
        // The link never gives up on its own, which is right for a session and
        // wrong for a dialog waiting on an answer: a box that is simply not
        // there has to become a refusal the person can act on.
        let deadline = DispatchWorkItem {
            guard !answered else { return }
            answered = true
            retire(channel)
            completion(.failure(DeviceUnreachable(message: localized("That device didn’t answer."))))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: deadline)
        channel.onReady = { handshake in
            guard !answered else { return }
            answered = true
            deadline.cancel()
            retire(channel)
            completion(.success(handshake.hostId))
        }
        channel.onFailure = { reason in
            guard !answered else { return }
            answered = true
            deadline.cancel()
            retire(channel)
            completion(.failure(DeviceUnreachable(message: reason)))
        }
        channel.start()
    }
}

// MARK: - Roster synthesis

private extension DeviceRoster {
    /// The device's flat session list as the Device → Workspace → Project →
    /// Session tree the screens draw.
    ///
    /// Three things the wire does not answer, decided here:
    ///
    /// - **The name.** Device architecture §4 is explicit that the host never
    ///   supplies one, so nothing is reported and `PairedMac.name` — the name
    ///   the phone gave the box when it paired — stands.
    /// - **The agents.** Each row's agent is read off `foregroundArgv`, which
    ///   exists precisely so the client decides. The ＋ menu is the weaker half:
    ///   it offers the built-in list as a fallback, so it can offer an agent the
    ///   box does not have. `agents_probed` / `AgentPresence` is the answer to
    ///   that and is not wired up yet (see the RFC's P4 follow-ups) — a separate
    ///   change from this one, which only fixed how replies find their caller.
    /// - **The workspace.** One device is one workspace, and it carries no
    ///   `deviceAlias`: the box *is* the paired peer, which is what makes
    ///   `RosterStore.localWorkspaces` offer it as a place to start a session.
    init(
        hostID: String,
        projects: [TermiodRoster.Project],
        statusOverrides: [String: StatusDelta]
    ) {
        self.init(
            deviceID: hostID,
            deviceName: nil,
            agents: RosterAgent.legacyDefaults,
            projects: projects.map { project in
                // The two loose containers are named here rather than on the
                // wire, for the same reason the device supplies no display name
                // for itself: the words a person reads are the client's.
                let name = switch project.kind {
                case .terminals: localized("Terminals")
                case .chats: localized("Chats")
                case .folder: project.name
                }
                return MockProject(
                    name: name,
                    path: project.path,
                    rosterID: project.id,
                    kind: project.kind.rawValue,
                    workspaceID: hostID,
                    workspaceName: "",
                    sessions: project.sessions.map {
                        MockSession(
                            device: $0, container: project, named: name,
                            revision: statusOverrides[$0.id])
                    }
                )
            }
        )
    }
}

private extension MockSession {
    init(
        device information: Termiod.SessionInformation,
        container: TermiodRoster.Project,
        named containerName: String,
        revision: StatusDelta?
    ) {
        let agent = TermiodAgentLaunch.agent(for: information)
        let declared = information.agentID.flatMap { $0.isEmpty ? nil : $0 } != nil
        let reported = revision?.title ?? information.title
        let title = reported.flatMap { $0.isEmpty ? nil : $0 }
        self.init(
            // A reported title first, then the agent's display name when the
            // device declared one — `displayLabel` would hand back the raw
            // `agent_id` there, so a chat would read `terminal` rather than
            // `Terminal`. A session that declared no agent has no name to
            // borrow, and `displayLabel` is what turns it into the program
            // actually running (`zsh`) instead of the daemon's uuid handle.
            title: title ?? (declared ? agent.name : information.displayLabel),
            project: containerName,
            agent: agent,
            status: SessionStatus(wire: revision?.status ?? information.status),
            subtitle: "",
            time: "",
            rosterID: information.id,
            projectRosterID: container.id,
            projectPath: container.path
        )
    }
}

/// The two fields an `E status` revises on a row the device already described.
struct StatusDelta: Equatable {
    let status: String
    let title: String?
}

/// What the client decides about a session the device merely describes: which
/// agent it is, and what to run when starting a new one.
enum TermiodAgentLaunch {
    /// The environment a session inherits from *this* client — how output
    /// should look, which belongs to the viewer no matter which machine the
    /// process runs on. Nothing here names a path or an identity: those describe
    /// where the process runs, and the device owns that.
    static let presentationEnvironment = [
        ["TERM", "xterm-ghostty"],
        ["COLORTERM", "truecolor"],
        ["TERM_PROGRAM", "termio"],
    ]

    /// What to exec for an agent. A login shell runs it so the agent is found
    /// on the user's own `PATH` — a GUI process's `PATH` is not the shell's, and
    /// a bare exec is how agents came up dead at 0 ms on the Mac.
    static func argv(forAgent id: String) -> [String] {
        guard id != RosterAgent.terminal.id else { return [] }
        return ["/bin/sh", "-lc", "exec \(shellQuoted(id))"]
    }

    /// The same, into the scratch directory a loose agent belongs in — created
    /// on the way, because nothing on the device has made it yet.
    static func looseChatArgv(forAgent id: String, root: String) -> [String] {
        let directory = shellQuoted(root)
        guard id != RosterAgent.terminal.id else {
            return ["/bin/sh", "-lc", "mkdir -p \(directory) && cd \(directory) && exec \"$SHELL\" -l"]
        }
        return ["/bin/sh", "-lc",
                "mkdir -p \(directory) && cd \(directory) && exec \(shellQuoted(id))"]
    }

    /// Single-quoted for `sh`. An agent id comes from a manifest and a root from
    /// the device's own handshake, so neither is hostile — but both end up
    /// inside a shell command, and a path with a space in it would otherwise
    /// spawn in the wrong place.
    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Which agent a roster row is running. The device's own `agent_id` wins;
    /// without one the foreground argv is read, because the host reports the
    /// process and the client owns the mapping.
    static func agent(for information: Termiod.SessionInformation) -> RosterAgent {
        if let id = information.agentID, !id.isEmpty { return RosterAgent.fallback(wire: id) }
        guard let executable = information.foregroundArgv?.first, !executable.isEmpty else {
            return .terminal
        }
        let name = URL(fileURLWithPath: executable).lastPathComponent
        let program = name.hasPrefix("-") ? String(name.dropFirst()) : name
        return RosterAgent.legacyDefaults.first { $0.id == program } ?? .terminal
    }
}
