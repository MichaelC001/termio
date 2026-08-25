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
/// Both verbs are **request/response on one channel**: `fs.list` canonicalises
/// the root and confines every path under it (`termiod/src/files.rs`), and
/// `fs.read` answers one `fs_file` header followed by `F` chunks. Neither is a
/// subscription, so neither needs a connection that outlives the request — which
/// is why the tree can land before `withControlChannel` becomes durable. Live
/// change notification (the `fs:` resource) does need that, and is not here.
extension Termiod {
    /// What one directory answered. `error` is the device's own message for a
    /// path that vanished or escaped the root; a batched request fails one path
    /// at a time rather than as a whole.
    struct DirectoryListing: Sendable {
        let path: String
        let entries: [FileEntry]
        let error: String?
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

    /// One `fs.search` hit: a path relative to the searched root, the 1-based
    /// line it was found on, and that line's text.
    struct SearchHit: Sendable {
        let path: String
        let line: Int
        let text: String
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
    /// Blocking; call it off the main thread (`DeviceFileProvider` does).
    static func listDirectories(
        route: TermiodRoute, root: String, paths: [String]
    ) throws -> [DirectoryListing] {
        try withFilesChannel(route: route) { transport in
            let listed = try requestFiles(
                transport, FsListOperation(root: root, paths: paths, seq: 1)
            ) { control in
                if case .fsListed(let payload) = control { return payload }
                return nil
            }
            return listed.listings.map { listing in
                DirectoryListing(
                    path: listing.path,
                    entries: listing.entries.map(FileEntry.init(wire:)),
                    error: listing.error)
            }
        }
    }

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
    ) throws -> Data {
        try withFilesChannel(route: route) { transport in
            let header = try requestFiles(
                transport, FsReadOperation(path: path, seq: 1)
            ) { control in
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
                let frame = try readFrame(transport.readDescriptor)
                switch frame.kind {
                case .file:
                    let chunk = try decodeFileChunk(frame.payload)
                    data.append(chunk.data)
                    if chunk.last { return data }
                case .control:
                    if case .error(let failure) = try decodeControl(frame.payload) {
                        throw TermiodClientError.requestFailed(failure.message)
                    }
                default:
                    continue
                }
            }
            return data
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
        return try withFilesChannel(route: route) { transport in
            try writeFrame(
                transport.writeDescriptor, kind: .control,
                payload: encodeControl(FsSearchOperation(
                    root: root, query: query, limit: UInt64(limit), seq: 1)))
            var hits: [SearchHit] = []
            while true {
                try waitForReadable(
                    transport.readDescriptor, seconds: idleTimeoutSeconds,
                    operation: "fs.search")
                let frame = try readFrame(transport.readDescriptor)
                switch frame.kind {
                case .event:
                    guard case .searchResults(let payload) = try decodeEvent(frame.payload)
                    else { continue }
                    hits.append(contentsOf: payload.matches.map {
                        SearchHit(path: $0.path, line: Int(clamping: $0.line), text: $0.text)
                    })
                case .control:
                    switch try decodeControl(frame.payload) {
                    case .fsSearched(let payload):
                        return SearchResult(hits: hits, limitHit: payload.limitHit)
                    case .error(let failure):
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

    /// Opens a control channel that negotiated `files`, and refuses up front on a
    /// daemon that did not grant it — the pane then says the device cannot serve
    /// files rather than hanging on a reply that never comes.
    private static func withFilesChannel<Result>(
        route: TermiodRoute, _ body: (Transport) throws -> Result
    ) throws -> Result {
        try withControlChannel(route: route, caps: ["files"]) { transport, handshake in
            guard handshake.capabilities.contains("files") else {
                throw DeviceFileError.unsupported
            }
            return try body(transport)
        }
    }

    private static func requestFiles<Operation: Encodable, Reply>(
        _ transport: Transport,
        _ operation: Operation,
        _ match: (IncomingControl) -> Reply?
    ) throws -> Reply {
        try writeFrame(transport.writeDescriptor, kind: .control,
                       payload: encodeControl(operation))
        while true {
            let frame = try readFrame(transport.readDescriptor)
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
}

extension FileEntry {
    /// One `fs.list` row. `unloaded_dir` is a directory the host will not walk on
    /// its own (VCS internals) — still a directory to the tree, which filters
    /// those names anyway (`FileEntry.ignoredNames`).
    init(wire entry: Termiod.DirEntryPayload) {
        let kind: Kind
        switch entry.kind {
        case "dir", "unloaded_dir": kind = .directory
        case "file": kind = .file
        case "symlink": kind = .symlink
        default: kind = .other
        }
        self.init(name: entry.name, kind: kind)
    }
}

/// The tree's async seam onto the two blocking verbs above. One per pane, so a
/// device that stops answering blocks only its own pane.
///
/// The work runs on a global queue rather than in an actor: each call opens,
/// hellos, asks and closes on one file descriptor, and blocking a cooperative
/// pool thread for a network round trip is exactly what that pool is not for.
struct DeviceFileProvider: Sendable {
    let route: TermiodRoute
    /// The checkout root every request is confined under, so a listing can never
    /// walk out of the directory the pane is rooted at — the daemon enforces it
    /// (`files.rs` `confine`), and passing the tree's own root is what arms that.
    let root: String

    func list(_ path: String) async throws -> [FileEntry] {
        let listings = try await run { [route, root] in
            try Termiod.listDirectories(route: route, root: root, paths: [path])
        }
        guard let listing = listings.first else { return [] }
        if let error = listing.error {
            throw TermiodClientError.requestFailed(error)
        }
        return listing.entries
    }

    /// Content search under the pane's own root, on the device. Confined the same
    /// way a listing is: the daemon canonicalises `root` and greps nothing above it.
    func search(_ query: String, limit: Int) async throws -> Termiod.SearchResult {
        try await run { [route, root] in
            try Termiod.searchContents(
                route: route, root: root, query: query, limit: limit)
        }
    }

    func read(_ path: String, limit: Int) async throws -> Data {
        try await run { [route] in
            try Termiod.readFile(route: route, path: path, limit: limit)
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
