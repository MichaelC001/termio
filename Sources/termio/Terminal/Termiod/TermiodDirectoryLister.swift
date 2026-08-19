import Foundation

extension Termiod {
    /// One `fs_list` round trip for a single directory. Blocking; the lister
    /// serialises the calls so a reply always belongs to the request in flight.
    ///
    /// Frames that are not this reply are skipped rather than treated as an
    /// error: a control channel may carry anything the daemon chooses to say,
    /// and a listing must not fail because something else arrived first.
    static func requestListing(_ transport: Transport, root: String) throws -> PathListingPayload {
        let operation = FsListOperation(root: root, paths: [root], seq: 1)
        try writeFrame(
            transport.writeDescriptor, kind: .control, payload: encodeControl(operation))
        while true {
            let frame = try readFrame(transport.readDescriptor)
            guard frame.kind == .control else { continue }
            switch try decodeControl(frame.payload) {
            case .fsListed(let payload):
                guard let listing = payload.listings.first else {
                    throw TermiodClientError.requestFailed(
                        localized("The machine answered with no listing for that folder."))
                }
                return listing
            case .error(let failure):
                throw TermiodClientError.requestFailed(failure.message)
            default:
                continue
            }
        }
    }
}

/// Lists directories on another machine, one directory at a time, over a
/// control channel it holds open for as long as a picker needs it.
///
/// This is the request plane's read half (§C.12, capability `files`) and it is
/// deliberately *not* a file browser: a path field asks for the directory the
/// user is currently typing inside, and the answer is one `fs.list`. Nothing
/// walks a tree, so a machine with a huge checkout costs the same as an empty
/// one.
///
/// The channel is held rather than reopened per keystroke because opening one
/// means `ssh <host> termiod stdio` — a whole SSH round trip, which would land
/// on every `/` the user types. It rides its own channel and never a session's
/// attachment, for the same reason transfers do: byte delivery must not queue
/// behind a directory listing (anti-100× invariant).
final class TermiodDirectoryLister: @unchecked Sendable {
    /// A directory that can be descended into, which is all a project picker
    /// offers — a file is never a project root.
    struct Entry: Sendable, Equatable {
        let name: String
    }

    enum Failure: Error {
        /// The daemon answered, but refused this path — gone, unreadable, or
        /// outside the root. Carries the daemon's own words.
        case refused(String)
    }

    private let route: TermiodRoute
    /// Serialises the blocking frame reads: one request is in flight at a time,
    /// so a reply can never be claimed by the wrong caller.
    private let queue = DispatchQueue(label: "sh.termio.termiod.directory-lister")
    private var transport: Termiod.Transport?
    private var handshake: Termiod.Handshake?

    init(route: TermiodRoute) {
        self.route = route
    }

    /// Connects and reports the home directory to start from. Called once, off
    /// the main thread; every later `list` reuses the channel it opened.
    func connect(completion: @escaping @Sendable (Result<String, Error>) -> Void) {
        queue.async { [self] in
            do {
                let transport = try Termiod.Transport.open(route)
                let handshake = try Termiod.performHello(
                    transport, role: "control", caps: ["files"])
                guard handshake.capabilities.contains("files") else {
                    transport.close()
                    // An older daemon that never learned the file plane. The
                    // picker still opens; it just cannot complete a path.
                    throw Failure.refused(
                        localized("This machine’s termiod is too old to list folders."))
                }
                self.transport = transport
                self.handshake = handshake
                completion(.success(handshake.home))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// The directories directly inside `path`, sorted the way a picker reads:
    /// case-insensitively, with dot-directories last so `~/.cache` never sits
    /// above `~/code`.
    ///
    /// `root` is `path` itself. Confinement is anchored at the directory being
    /// listed rather than at some remembered ancestor, because the field lets
    /// the user retype the whole path at any moment — anchoring anywhere else
    /// would refuse a sibling directory the user can plainly `cd` to.
    func list(_ path: String, completion: @escaping @Sendable (Result<[Entry], Error>) -> Void) {
        queue.async { [self] in
            guard let transport else {
                completion(.failure(TermiodClientError.connectionClosed))
                return
            }
            do {
                let listing = try Termiod.requestListing(transport, root: path)
                if let message = listing.error {
                    completion(.failure(Failure.refused(message)))
                    return
                }
                let directories = listing.entries
                    .filter(\.isDirectory)
                    .map { Entry(name: $0.name) }
                    .sorted { left, right in
                        let leftHidden = left.name.hasPrefix(".")
                        let rightHidden = right.name.hasPrefix(".")
                        if leftHidden != rightHidden { return rightHidden }
                        return left.name.localizedStandardCompare(right.name) == .orderedAscending
                    }
                completion(.success(directories))
            } catch {
                // A lost pipe must not leave a dead transport behind answering
                // every later keystroke with the same corpse.
                if case TermiodClientError.connectionClosed = error { close() }
                completion(.failure(error))
            }
        }
    }

    /// Drops the channel. Safe to call more than once, and from any thread.
    func close() {
        queue.async { [self] in
            transport?.close()
            transport = nil
            handshake = nil
        }
    }
}
