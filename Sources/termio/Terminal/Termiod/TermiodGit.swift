import TermioShared
import Foundation

/// The git plane: reading a device's checkout through the `git:` resource and
/// the `git.*` verbs (`termiod/src/git.rs`).
///
/// Status is a **subscription**, not a poll. The device already watches the
/// workspace, so it knows when status moved and the client does not have to ask;
/// what arrives is a delta against what the subscriber holds. Zed publishes the
/// same object under a different name (`UpdateRepository`: `updated_statuses`,
/// `removed_statuses`, `branch_summary`), and VS Code arrives at it from the
/// other side by running the git extension itself on the remote. A client that
/// polled would be the only one of the three doing so.
///
/// Everything here reads. Stage, commit, discard and push are a separate tier
/// that needs the prompt-forwarding channel (`docs/rfcs/remote-git-plane.md` §3)
/// and are deliberately absent — a remote checkout's Changes pane offers no
/// action it cannot honestly perform.
extension Termiod {
    /// What a git channel negotiates. The pool keys channels by capability set,
    /// so this is also what decides whether the Changes pane shares a connection
    /// with the file tree or gets its own — deliberately its own, because the
    /// tree's `["files"]` channel could not answer a `git` verb and handing it
    /// one would hang on a reply the daemon will never send.
    static let gitCapabilities = ["resources", "git"]

    /// The `git:` resource id for a checkout — `resource.rs` `GIT_PREFIX`.
    static func gitResource(root: String) -> String { "git:\(root)" }

    /// One `git_changed` batch: a delta against the subscriber's baseline, with
    /// branch metadata carried whole so a client never merges it.
    struct GitChangedPayload: Sendable {
        let seq: UInt64
        let updatedStatuses: [GitStatusEntryPayload]
        let removedPaths: [String]
        let branch: String?
        let head: String?
        let ahead: Int
        let behind: Int
        let conflicts: [String]
        /// The device cut the status list at its cap (`git.rs` `STATUS_CAP`),
        /// so what arrived is the head of the list and not the whole of it.
        let truncated: Bool
    }

    /// One changed path. The two-axis `status` is the porcelain-v2 vocabulary
    /// the device and the Mac's own parser both speak, so the pane's row reads
    /// the same either way.
    struct GitStatusEntryPayload: Sendable {
        let path: String
        let status: WireGitStatus
        let originalPath: String?
        let additions: Int
        let deletions: Int
        let binary: Bool
    }

    /// `git.rs`'s `GitFileStatus`, as it arrives. Kept as the wire's own shape
    /// rather than flattened on decode: which axis moved is what says whether a
    /// change is staged, and collapsing that here would throw it away.
    enum WireGitStatus: Sendable {
        case untracked
        case ignored
        case tracked(index: String, worktree: String)
        case unmerged
        /// A status this build has never heard of. Additive evolution applies to
        /// the *batch* — one unreadable row must not sink the list — but not to
        /// the row itself, which is dropped rather than drawn as a guess.
        case unknown
    }

    static func decodeGitChanged(_ payload: Data) throws -> GitChangedPayload {
        try gitDecoder().decode(WireGitChanged.self, from: payload).payload
    }

    /// The unified diff for one path, rendered client-side.
    ///
    /// `staged` is a hint about where the change lives; the device walks the
    /// same ladder the Mac's local path does either way, so an untracked file
    /// and a fully-staged one both answer. `context` is the `-U`: the overlay
    /// asks for the whole file so it can fold unchanged runs into expandable
    /// bands, which git's default three lines cannot support.
    static func gitDiff(
        route: TermiodRoute, root: String, path: String, staged: Bool, context: Int? = nil
    ) async throws -> (text: String, truncated: Bool) {
        try await offMain {
            try withPooledRequest(route: route, caps: gitCapabilities) { call, channel in
                guard channel.capabilities.contains("git") else {
                    throw DeviceGitError.unsupported
                }
                try call.send(payload: encodeControl(GitDiffOperation(
                    root: root, path: path, staged: staged,
                    context: context.map(UInt64.init), seq: call.seq)))
                while true {
                    let frame = try call.next(
                        timeoutSeconds: connectTimeoutSeconds, operation: "git diff \(path)")
                    guard frame.kind == .control else { continue }
                    let reply = try decodeControl(frame.payload)
                    if case .error(let failure) = reply {
                        throw TermiodClientError.requestFailed(failure.message)
                    }
                    guard case .unknown = reply else { continue }
                    // `git_diff_result` is not in the shared decode table: it is
                    // this plane's own reply and nothing else consumes it, so it
                    // is decoded here rather than grown into an enum every other
                    // channel would carry.
                    let result = try gitDecoder().decode(GitDiffResult.self, from: frame.payload)
                    return (result.diff, result.truncated)
                }
            }
        }
    }

    /// Runs a blocking pooled request off the main thread. Every verb here is
    /// blocking by construction — the pool hands out a frame reader, not a
    /// future — and the panes calling them are on the main actor.
    private static func offMain<Value: Sendable>(
        _ body: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    /// Subscribes to the checkout's status. The first batch is the whole state
    /// — the device synthesizes it for a subscriber with no cursor — so the
    /// caller starts from empty and applies what arrives.
    static func watchGit(
        route: TermiodRoute,
        root: String,
        since: UInt64? = nil,
        onBatch: @escaping @Sendable (GitChangedPayload) -> Void,
        onInterrupted: @escaping @Sendable () -> Void
    ) async throws -> (subscription: ResourceSubscription, gap: Bool, seq: UInt64) {
        try await offMain {
            try subscribeResource(
                route: route,
                caps: gitCapabilities,
                resource: gitResource(root: root),
                since: since,
                onEvent: { payload in
                    guard let batch = try? decodeGitChanged(payload) else { return }
                    onBatch(batch)
                },
                onInterrupted: onInterrupted)
        }
    }

    private struct GitDiffOperation: Encodable {
        let op = "git_diff"
        let root: String
        let path: String
        let staged: Bool
        let context: UInt64?
        let seq: UInt64
    }

    private struct GitDiffResult: Decodable {
        let diff: String
        let truncated: Bool

        private enum CodingKeys: String, CodingKey { case diff, truncated }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            diff = try container.decodeIfPresent(String.self, forKey: .diff) ?? ""
            truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        }
    }

    private struct WireGitChanged: Decodable {
        let seq: UInt64
        let updatedStatuses: [WireStatusEntry]
        let removedPaths: [String]
        let branch: String?
        let head: String?
        let aheadBehind: [Int]?
        let conflicts: [String]
        let truncated: Bool

        private enum CodingKeys: String, CodingKey {
            case seq, updatedStatuses, removedPaths, branch, head, aheadBehind, conflicts
            case truncated
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            seq = try container.decodeIfPresent(UInt64.self, forKey: .seq) ?? 0
            updatedStatuses = try container.decodeIfPresent(
                [WireStatusEntry].self, forKey: .updatedStatuses) ?? []
            removedPaths = try container.decodeIfPresent(
                [String].self, forKey: .removedPaths) ?? []
            branch = try container.decodeIfPresent(String.self, forKey: .branch)
            head = try container.decodeIfPresent(String.self, forKey: .head)
            aheadBehind = try container.decodeIfPresent([Int].self, forKey: .aheadBehind)
            conflicts = try container.decodeIfPresent([String].self, forKey: .conflicts) ?? []
            truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        }

        var payload: GitChangedPayload {
            GitChangedPayload(
                seq: seq,
                updatedStatuses: updatedStatuses.map(\.payload),
                removedPaths: removedPaths,
                branch: branch,
                head: head,
                ahead: aheadBehind?.first ?? 0,
                behind: aheadBehind?.dropFirst().first ?? 0,
                conflicts: conflicts,
                truncated: truncated)
        }
    }

    private struct WireStatusEntry: Decodable {
        let path: String
        let status: WireStatusValue
        let originalPath: String?
        let additions: Int
        let deletions: Int
        let binary: Bool

        private enum CodingKeys: String, CodingKey {
            case path, status, originalPath, additions, deletions, binary
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            path = try container.decode(String.self, forKey: .path)
            status = try container.decode(WireStatusValue.self, forKey: .status)
            originalPath = try container.decodeIfPresent(String.self, forKey: .originalPath)
            additions = try container.decodeIfPresent(Int.self, forKey: .additions) ?? 0
            deletions = try container.decodeIfPresent(Int.self, forKey: .deletions) ?? 0
            binary = try container.decodeIfPresent(Bool.self, forKey: .binary) ?? false
        }

        var payload: GitStatusEntryPayload {
            GitStatusEntryPayload(
                path: path, status: status.status, originalPath: originalPath,
                additions: additions, deletions: deletions, binary: binary)
        }
    }

    /// Serde's externally-tagged enum: `"untracked"` for a unit case, and
    /// `{"tracked": {...}}` for one with fields. Decoded by hand because the two
    /// shapes are a string and an object, which no synthesized initializer will
    /// accept as one type.
    private struct WireStatusValue: Decodable {
        let status: WireGitStatus

        init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer(),
               let name = try? single.decode(String.self) {
                switch name {
                case "untracked": status = .untracked
                case "ignored": status = .ignored
                default: status = .unknown
                }
                return
            }
            guard let container = try? decoder.container(keyedBy: Key.self) else {
                status = .unknown
                return
            }
            if let tracked = try? container.decode(
                TrackedAxes.self, forKey: Key(stringValue: "tracked")) {
                status = .tracked(index: tracked.indexStatus, worktree: tracked.worktreeStatus)
            } else if container.contains(Key(stringValue: "unmerged")) {
                status = .unmerged
            } else {
                status = .unknown
            }
        }

        private struct TrackedAxes: Decodable {
            let indexStatus: String
            let worktreeStatus: String
        }

        private struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }
    }

    private static func gitDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

/// What can go wrong reading a device's git, in the pane's vocabulary.
enum DeviceGitError: Error, Equatable {
    /// The daemon did not grant `git` — too old, or built without it.
    case unsupported
}
