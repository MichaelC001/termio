import Foundation

// MARK: - Worktree discovery

/// Discovers a repo's linked git worktrees so the sidebar reflects them no matter who
/// created them — termio's own "New Worktree" *or* a plain `git worktree add` on the CLI.
/// Git is the source of truth; `TermioStore` reconciles `Project.worktrees` against this
/// (the one piece of git state termio used to mirror instead of read). Runs off-main.
enum WorktreeService {
    /// One record of `git worktree list --porcelain` — everything a caller decides
    /// on: `prunable` means git itself judges the checkout gone (folder deleted, or
    /// its `.git` gitfile damaged), and `locked` means git refuses to let go of it
    /// (the convention for worktrees on removable media).
    struct Record: Sendable {
        /// The path as git printed it — its realpath spelling, which need not match
        /// how the same folder is spelled elsewhere; callers canonicalize both
        /// sides before comparing.
        let path: String
        /// The checked-out branch's short name; `nil` on a detached HEAD or a bare
        /// entry.
        let branch: String?
        let bare: Bool
        let locked: Bool
        let prunable: Bool
    }

    /// What a disk read can say about a checkout git can no longer inspect — the
    /// only evidence left once a worktree's `.git` gitfile is gone or git never
    /// knew the path at all.
    ///
    /// The three "nothing to protect" shapes are kept apart because each needs a
    /// different move: a path that is gone needs nothing done to it, an empty
    /// folder has to be cleared before git will deregister the worktree, and
    /// something that is not a folder at all can only be reported — removing it
    /// would delete a file this action was never pointed at.
    enum FolderEvidence: Equatable {
        /// Nothing is at the path.
        case gone
        /// A directory with nothing in it worth keeping.
        case emptyFolder
        /// Something is at the path that is not a directory — a plain file, or a
        /// symlink — so no checkout is there, and it is not ours to remove.
        case occupied
        /// Entries are present, and nothing can tell whether they are work.
        case mayHoldWork
        /// The path could not be read, so nothing at all is known about it.
        case unreadable
    }

    /// One spelling for a worktree path however it reaches us: git prints
    /// realpaths, while a stored `Worktree.path` keeps whatever spelling created
    /// it, so a symlinked ancestor (`/tmp`, `/var`, a linked home) makes the two
    /// disagree.
    ///
    /// The resolution has to survive the path being *gone*, which is the whole
    /// case this exists for. `resolvingSymlinksInPath` returns a path that does
    /// not exist unchanged, so canonicalizing the leaf directly stopped working
    /// at exactly the moment a worktree's folder was deleted: the stored row and
    /// git's record no longer matched, the record read as absent, and a removal
    /// dropped the row while git kept the registration for good. So the deepest
    /// *existing* ancestor is resolved — that part is real, and both spellings
    /// share it — and the missing components are appended back to it.
    static func canonicalPath(_ path: String) -> String {
        var missing: [String] = []
        var probe = URL(fileURLWithPath: path).standardized
        var hops = 0
        while !FileManager.default.fileExists(atPath: probe.path) {
            // A symlink whose target is gone still says where it pointed, and
            // that is the spelling git recorded. `resolvingSymlinksInPath` gives
            // up on one, which left a worktree under a symlinked ancestor
            // unmatchable once that target went — the row and its sessions
            // dropped while git kept the registration for good. The hop count is
            // for a link that points at itself.
            if hops < 32,
               let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: probe.path) {
                hops += 1
                probe = (destination.hasPrefix("/")
                    ? URL(fileURLWithPath: destination)
                    : probe.deletingLastPathComponent().appendingPathComponent(destination))
                    .standardized
                continue
            }
            let parent = probe.deletingLastPathComponent().standardized
            // The root resolves to itself; without this a path on no existing
            // volume at all would walk forever. Breaking rather than returning
            // keeps the components gathered so far, which a bare return dropped
            // — collapsing every path to `/`, where any row would match any
            // record.
            guard parent.path != probe.path else { break }
            missing.append(probe.lastPathComponent)
            probe = parent
        }
        var resolved = probe.resolvingSymlinksInPath()
        for component in missing.reversed() {
            resolved.appendPathComponent(component)
        }
        return resolved.path
    }

    /// What is at `path`, for the callers that have no git left to ask.
    ///
    /// Fails closed, and that is the whole point of the return type: a read that
    /// throws answers `.unreadable`, never `.nothingToProtect`. A folder behind a
    /// permission or TCC denial is one nothing has looked inside, and reading that
    /// as "empty, safe to let go of" is how an unreadable checkout full of
    /// uncommitted work gets deregistered.
    ///
    /// `.DS_Store` is Finder's, not the user's: a folder emptied in the Finder
    /// keeps one, and counting it as work would dead-end a removal on a worktree
    /// with nothing in it.
    static func folderEvidence(at path: String) -> FolderEvidence {
        let manager = FileManager.default
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try manager.attributesOfItem(atPath: path)
        } catch let error as NSError
            where (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError)
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)) {
            // Absent is only "deleted" when the volume it would be on is here to
            // say so. An unplugged drive answers `ENOENT` for everything on it,
            // which would read as "nothing to protect" for a checkout sitting
            // safely on the drive — the one shape this probe must not fail open
            // on.
            return volumeIsMissing(for: path) ? .unreadable : .gone
        } catch {
            // Something is there, and this could not find out what.
            return .unreadable
        }
        // A path that is not a directory holds no checkout — replaced by a plain
        // file, or a symlink, which this deliberately does not follow: whatever
        // is on the other side was never part of the checkout.
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            return .occupied
        }
        let entries: [String]
        do {
            entries = try manager.contentsOfDirectory(atPath: path)
        } catch {
            return .unreadable
        }
        return entries.contains { $0 != ".DS_Store" } ? .mayHoldWork : .emptyFolder
    }

    /// Whether `path` is absent because what would hold it is not mounted.
    ///
    /// That is the case worth telling apart from a deleted checkout: everything
    /// on an ejected drive or a dropped share answers "no such file", and letting
    /// go of a worktree on that evidence deregisters a checkout still sitting on
    /// the drive, uncommitted work and all.
    ///
    /// It asks where the path *stops* existing. A mount that is gone leaves its
    /// mount point gone with it, so the deepest directory still there is the one
    /// that was holding it — and two kinds of directory hold mounts: `/Volumes`,
    /// which is where macOS puts what a person plugs in or connects to, and an
    /// autofs trigger such as `/net`, which mounts on demand and reports its own
    /// filesystem type. Neither test fires for a checkout deleted from a volume
    /// that is still mounted: there the deepest existing directory is inside that
    /// volume, not the container holding it.
    ///
    /// A share the user mounts somewhere of their own — `~/mnt/work` — cannot be
    /// told from a deleted directory once it is unmounted, because nothing on
    /// disk records that a mount belonged there. `git worktree lock` is git's own
    /// answer for that, and the removal honors it.
    private static func volumeIsMissing(for path: String) -> Bool {
        guard let ancestor = deepestExistingAncestor(of: path) else { return false }
        return ancestor == "/Volumes" || filesystemType(at: ancestor) == "autofs"
    }

    /// The deepest directory on `path` that exists, or `nil` when `path` itself
    /// does — the caller only asks about paths that are absent.
    private static func deepestExistingAncestor(of path: String) -> String? {
        var probe = URL(fileURLWithPath: path).standardized
        while !FileManager.default.fileExists(atPath: probe.path) {
            let parent = probe.deletingLastPathComponent().standardized
            guard parent.path != probe.path else { return nil }
            probe = parent
        }
        return probe.path
    }

    /// The filesystem mounted at `path`, as the kernel names it.
    private static func filesystemType(at path: String) -> String? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        return withUnsafeBytes(of: info.f_fstypename) { raw in
            raw.bindMemory(to: CChar.self).baseAddress.map { String(cString: $0) }
        }
    }

    /// What a reconcile pass needs to merge git's worktrees into a project's,
    /// with every path it will compare already resolved.
    ///
    /// The resolving is the point. Matching a stored row against git's spelling
    /// takes `canonicalPath`, which stats and reads links, and the merge itself
    /// runs on the main actor — so a hung SMB mount or a stalled `/Volumes`
    /// device would beachball the app on a pass that fires whenever an agent
    /// touches git state. Those spellings are worked out here, off-main, and the
    /// merge only looks them up.
    struct Reconcile: Sendable {
        /// Linked worktrees git reports and this machine can see, in git's order.
        let discovered: [String]
        /// Canonical spelling for every path the merge compares, by the spelling
        /// it was asked about.
        let canonical: [String: String]
    }

    /// The linked worktrees of `repoRoot`, primary checkout excluded, together
    /// with canonical spellings for them and for `known` — the paths the caller
    /// already holds. `nil` when `git worktree list` fails (not a work tree, or a
    /// git error): the caller treats `nil` as "leave the current list alone" and
    /// an empty `discovered` as "git genuinely reports no linked worktrees".
    ///
    /// A `prunable` worktree — its directory deleted out from under git — is
    /// skipped, as is any path that no longer exists on disk. Without this, a
    /// stale worktree would show in the sidebar and a session started there would
    /// launch with a missing cwd, so the shell silently falls back to `/` (the
    /// bug this guards against).
    static func reconcile(in repoRoot: String, against known: [String]) async -> Reconcile? {
        await offMain {
            guard let all = records(in: repoRoot) else { return nil }
            sweepVanishedWorktrees(all, in: repoRoot)
            let discovered = all.dropFirst()                            // primary checkout
                .filter { !$0.bare && !$0.prunable }
                .compactMap { record -> String? in
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: record.path, isDirectory: &isDirectory),
                          isDirectory.boolValue else { return nil }
                    return URL(fileURLWithPath: record.path).standardizedFileURL.path
                }
            var canonical: [String: String] = [:]
            for path in discovered + known where canonical[path] == nil {
                canonical[path] = canonicalPath(path)
            }
            return Reconcile(discovered: discovered, canonical: canonical)
        }
    }

    /// Deregister the worktrees whose folders are simply gone.
    ///
    /// These rows leave the sidebar on the next pass — `discovered` filters
    /// `prunable` out — so without this nothing could ever reach them again:
    /// the registration and its branch stayed in the repo for good, and a later
    /// `git worktree add` at the same path was refused as already registered.
    /// A successful removal used to sweep them as a side effect, by running
    /// `git worktree prune` across the whole repo. That was the wrong tool —
    /// it also deregistered worktrees holding work nobody had inspected — but
    /// dropping it left the job undone.
    ///
    /// So each one is removed by name, and only where there is nothing to lose:
    /// `.gone` is the path not being there at all, which is the one shape
    /// `git worktree remove` settles without touching a file. A folder that
    /// still holds anything, one this cannot read, one on a volume that is not
    /// mounted, and one git is holding with `lock` are all left exactly as they
    /// are for the user's own Remove to decide on. Branches are left alone too:
    /// deleting a ref is not something a pass nobody asked for should do, and
    /// the sweep this replaces never did either.
    private static func sweepVanishedWorktrees(_ records: [Record], in repoRoot: String) {
        for record in records.dropFirst() where record.prunable && !record.locked {
            guard folderEvidence(at: record.path) == .gone else { continue }
            _ = run(["worktree", "remove", record.path], in: repoRoot)
        }
    }

    /// The repo's worktree records, primary checkout first, in git's order. `nil`
    /// when `git worktree list` fails. Blocks on the git spawn — callers already on
    /// a git-spawning path use it directly; `reconcile(in:against:)` is the
    /// off-main entry point.
    static func records(in repoRoot: String) -> [Record]? {
        guard let out = run(["worktree", "list", "--porcelain"], in: repoRoot) else { return nil }
        return records(from: out)
    }

    /// Parses `git worktree list --porcelain`: blank-line-separated records, each
    /// opening with `worktree <path>`. `locked` and `prunable` may carry a reason
    /// after a space; `branch` is a full ref (`refs/heads/<name>`), reduced here to
    /// the short name every caller wants.
    static func records(from listing: String) -> [Record] {
        listing.components(separatedBy: "\n\n").compactMap { record in
            let lines = record.split(separator: "\n", omittingEmptySubsequences: true)
            guard let worktreeLine = lines.first(where: { $0.hasPrefix("worktree ") }) else { return nil }
            let branch = lines.first(where: { $0.hasPrefix("branch ") })
                .map { String($0.dropFirst("branch ".count)) }
                .map { reference in
                    reference.hasPrefix("refs/heads/")
                        ? String(reference.dropFirst("refs/heads/".count))
                        : reference
                }
            return Record(
                path: String(worktreeLine.dropFirst("worktree ".count)),
                branch: branch,
                bare: lines.contains { $0 == "bare" },
                locked: lines.contains { $0 == "locked" || $0.hasPrefix("locked ") },
                prunable: lines.contains { $0 == "prunable" || $0.hasPrefix("prunable ") }
            )
        }
    }

    // MARK: Process

    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }

    /// `git -C <dir> <args>` → trimmed stdout, or `nil` on launch failure / non-zero exit —
    /// the same degrade-to-nothing stance as `GitService`/`BranchModel`.
    private static func run(_ args: [String], in dir: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", dir] + args
        process.environment = GitEnvironment.optionalLocksDisabled
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
