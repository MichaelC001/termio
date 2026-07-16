import Foundation
import Combine

/// Tracks the *current* git branch of one or more folders and keeps each label
/// live: when the user runs `git checkout` / `git switch` inside a folder, the
/// label updates on its own. This is what lets the sidebar's worktree nodes and
/// the terminal title bar show a folder's real branch instead of a value frozen
/// at the moment the project was opened.
///
/// Identity is the *folder* (a stable directory path); the branch is a mutable
/// attribute read from that folder's `HEAD`. A folder is watched by observing the
/// directory that contains its `HEAD` file — for the primary checkout that is
/// `<repo>/.git`, for a linked worktree it is `<repo>/.git/worktrees/<name>`. Git
/// resolves the right one via `rev-parse --git-path HEAD`. Watching the *directory*
/// (not the file) survives git's atomic replace-on-write of `HEAD`, where the file
/// inode is swapped out from under a file-level watch.
///
/// All git work runs off the main thread; `branches` is only ever mutated on main,
/// so SwiftUI observers stay safe.
final class BranchModel: ObservableObject {
    /// Folder path → branch label (the branch name, or a short commit SHA when the
    /// folder is in a detached HEAD). Absent when the folder is not a git repo, so
    /// callers can hide the branch chip entirely.
    @Published private(set) var branches: [String: String] = [:]
    /// Detached state stays separate from the label because existing branch chips
    /// still use the short SHA, while a worktree folder node uses its directory name
    /// and keeps that SHA for the tooltip.
    @Published private(set) var detachedFolders: Set<String> = []

    private let queue = DispatchQueue(label: "sh.termio.branch", qos: .utility)
    private var watchers: [String: Watcher] = [:]
    /// Pending debounce work items per folder, touched only on `queue`.
    private var pending: [String: DispatchWorkItem] = [:]

    /// A live file-system observer on the directory holding a folder's `HEAD`.
    private final class Watcher {
        let source: DispatchSourceFileSystemObject
        init(source: DispatchSourceFileSystemObject) { self.source = source }
    }

    /// The current branch label for `folder`, or `nil` when it is not a git repo
    /// (or has not resolved yet).
    func branch(for folder: String) -> String? {
        branches[Self.standardized(folder)]
    }

    func isDetached(_ folder: String) -> Bool {
        detachedFolders.contains(Self.standardized(folder))
    }

    /// Reconciles the watched set with `folders`: starts watching (and resolves) any
    /// newly present folder and stops watching any that has gone. Idempotent, so the
    /// store can call it after every change to the project tree. Main-actor only.
    func setWatched(_ folders: Set<String>) {
        let wanted = Set(folders.map(Self.standardized))

        for (folder, watcher) in watchers where !wanted.contains(folder) {
            watcher.source.cancel()
            watchers[folder] = nil
            branches[folder] = nil
            detachedFolders.remove(folder)
        }
        for folder in wanted where watchers[folder] == nil {
            arm(folder)
            resolve(folder)
        }
    }

    /// Opens a directory-level watch on the folder's `HEAD` container. A folder that
    /// is not a git repo simply gets no watcher (and no branch entry).
    private func arm(_ folder: String) {
        guard let headDirectory = headDirectory(for: folder) else { return }
        let descriptor = open(headDirectory, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend, .link, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self] in self?.scheduleResolve(folder) }
        source.setCancelHandler { close(descriptor) }
        watchers[folder] = Watcher(source: source)
        source.resume()
    }

    /// Coalesces a burst of file-system events (a checkout rewrites several refs)
    /// into a single re-resolve. Runs on `queue`, where `pending` lives.
    private func scheduleResolve(_ folder: String) {
        pending[folder]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.pending[folder] = nil
            self?.publish(folder, state: self?.currentBranchState(for: folder))
        }
        pending[folder] = item
        queue.asyncAfter(deadline: .now() + 0.12, execute: item)
    }

    /// Reads the branch off the main thread and publishes it.
    private func resolve(_ folder: String) {
        queue.async { [weak self] in
            self?.publish(folder, state: self?.currentBranchState(for: folder))
        }
    }

    private func publish(_ folder: String, state: BranchState?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let isDetached = state?.isDetached == true
            if isDetached {
                self.detachedFolders.insert(folder)
            } else {
                self.detachedFolders.remove(folder)
            }
            if self.branches[folder] != state?.label { self.branches[folder] = state?.label }
        }
    }

    // MARK: - Git

    private struct BranchState {
        var label: String
        var isDetached: Bool
    }

    /// The folder's current branch name, or its short SHA plus detached state when
    /// no branch owns HEAD. Returns `nil` when the folder is not a git work tree.
    private func currentBranchState(for folder: String) -> BranchState? {
        guard git(["rev-parse", "--is-inside-work-tree"], in: folder) == "true" else { return nil }
        let head = git(["rev-parse", "--abbrev-ref", "HEAD"], in: folder)
        if let head, head != "HEAD", !head.isEmpty {
            return BranchState(label: head, isDetached: false)
        }
        // Detached HEAD (rebase in progress, or checked out at a bare commit): show
        // the short SHA so the node still reads as "somewhere specific".
        guard let commit = git(["rev-parse", "--short", "HEAD"], in: folder) else { return nil }
        return BranchState(label: commit, isDetached: true)
    }

    /// The directory that contains the folder's `HEAD` file. `git-path` resolves the
    /// linked-worktree case (`…/.git/worktrees/<name>/HEAD`) as well as the primary
    /// checkout (`…/.git/HEAD`). Returns `nil` for a non-repo.
    private func headDirectory(for folder: String) -> String? {
        guard let headPath = git(["rev-parse", "--git-path", "HEAD"], in: folder) else { return nil }
        let absolute = headPath.hasPrefix("/")
            ? headPath
            : URL(fileURLWithPath: folder).appendingPathComponent(headPath).path
        return (absolute as NSString).deletingLastPathComponent
    }

    /// Runs `git -C <folder> <arguments…>` synchronously (callers are already off the
    /// main thread), returning trimmed stdout on success or `nil` on any failure —
    /// the same no-trap, degrade-gracefully stance the rest of the app takes.
    private func git(_ arguments: [String], in folder: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", folder] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func standardized(_ folder: String) -> String {
        URL(fileURLWithPath: folder).standardizedFileURL.path
    }
}
