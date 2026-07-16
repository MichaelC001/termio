import Foundation

// MARK: - Git

/// Thin wrapper over the `git` CLI for the changes list and diff overlay. Every call
/// runs off the main thread (via `offMain`) and degrades to empty on any failure —
/// the same no-trap stance as `BranchModel`.
enum GitService {
    /// Changed files for a repo root, with their `+`/`−` counts filled in. Empty when
    /// the folder is not a git work tree.
    static func changes(in repoRoot: String) async -> [GitChange] {
        await offMain { loadChanges(repoRoot) }
    }

    /// The unified-diff rows for one changed file (staged + unstaged vs `HEAD`, or the
    /// whole file for an untracked one).
    static func diffRows(for change: GitChange, in repoRoot: String) async -> [DiffRow] {
        await offMain { parseDiff(loadDiffText(change, repoRoot)) }
    }

    /// The raw unified-diff text for one changed file — what "Copy Diff" puts on the
    /// pasteboard, so it round-trips cleanly into `git apply` or an agent prompt.
    static func diffText(for change: GitChange, in repoRoot: String) async -> String {
        await offMain { loadDiffText(change, repoRoot) }
    }

    /// Throws away every change to a single file, restoring it to its clean state:
    /// modified/deleted files reset to `HEAD` (index *and* worktree), a newly-added file
    /// is unstaged and removed, and an untracked file is deleted from disk. Best-effort —
    /// the caller reloads the changes list afterwards regardless of the return.
    @discardableResult
    static func discard(_ change: GitChange, in repoRoot: String) async -> Bool {
        await offMain { discardChanges(change, repoRoot) }
    }

    // MARK: Mutating actions

    /// Commits exactly the checked files with `message`. The paths are staged first
    /// (`git add` registers new files and picks up deletions), then committed with an
    /// explicit pathspec so the commit records *only* those files even if something else
    /// was already staged from the terminal. No `Co-Authored-By` trailer — termio's
    /// commits stay attribution-free by house rule.
    static func commit(message: String, paths: [String], in repoRoot: String) async -> GitActionResult {
        await offMain {
            guard !paths.isEmpty else { return .failure("Nothing selected to commit.") }
            let staged = runResult(["add", "--"] + paths, in: repoRoot)
            if staged.status != 0 { return .failure(oneLine(staged.err, fallback: "Failed to stage files.")) }
            let committed = runResult(["commit", "-m", message, "--"] + paths, in: repoRoot)
            if committed.status != 0 { return .failure(oneLine(committed.err, fallback: "Commit failed.")) }
            return .success
        }
    }

    /// Pushes the current branch. A branch with no upstream gets `-u origin HEAD` so the
    /// first push also sets tracking; otherwise a plain `git push`.
    static func push(in repoRoot: String) async -> GitActionResult {
        await offMain {
            let up = upstreamStateSync(repoRoot)
            let args = up.hasUpstream ? ["push"] : ["push", "-u", "origin", "HEAD"]
            let r = runResult(args, in: repoRoot)
            return r.status == 0 ? .success : .failure(oneLine(r.err, fallback: "Push failed."))
        }
    }

    /// The current branch's ahead/behind position versus its upstream — drives the Push
    /// button's count and enabled state.
    static func upstreamState(in repoRoot: String) async -> GitUpstream {
        await offMain { upstreamStateSync(repoRoot) }
    }

    /// Parses the `## branch...remote [ahead N, behind M]` header line of `git status -sb`.
    /// No `...` means the branch has no upstream (never pushed); a missing bracket means
    /// it is level with the remote.
    private static func upstreamStateSync(_ repoRoot: String) -> GitUpstream {
        guard let out = run(["status", "-sb"], in: repoRoot),
              let header = out.split(separator: "\n", omittingEmptySubsequences: false).first
        else { return .none }
        let line = String(header)
        let hasUpstream = line.contains("...")
        var ahead = 0, behind = 0
        if let open = line.firstIndex(of: "["), let close = line.firstIndex(of: "]"), open < close {
            for part in line[line.index(after: open)..<close].split(separator: ",") {
                let toks = part.split(separator: " ").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                guard toks.count == 2, let n = Int(toks[1]) else { continue }
                if toks[0] == "ahead" { ahead = n }
                if toks[0] == "behind" { behind = n }
            }
        }
        return GitUpstream(hasUpstream: hasUpstream, ahead: ahead, behind: behind)
    }

    // MARK: Loading

    private static func loadChanges(_ repoRoot: String) -> [GitChange] {
        guard run(["rev-parse", "--is-inside-work-tree"], in: repoRoot)?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "true",
            let raw = run(["status", "--porcelain=v2", "-z", "--untracked-files=all"], in: repoRoot)
        else { return [] }

        var changes = parseStatus(raw)
        applyCounts(&changes, repoRoot: repoRoot)
        return changes
    }

    /// Parses `git status --porcelain=v2 -z`. Records are NUL-separated; the path is
    /// always the *current* path, so renames (type `2`) carry the original path in the
    /// following NUL field, which is consumed and ignored.
    private static func parseStatus(_ raw: String) -> [GitChange] {
        let tokens = raw.components(separatedBy: "\0").filter { !$0.isEmpty }
        var result: [GitChange] = []
        var i = 0
        while i < tokens.count {
            let rec = tokens[i]
            i += 1
            guard let kind = rec.first else { continue }
            switch kind {
            case "1":
                let f = rec.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard f.count == 9 else { continue }
                result.append(make(xy: Array(f[1]), path: String(f[8]), untracked: false))
            case "2":
                let f = rec.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard f.count == 10 else { continue }
                if i < tokens.count { i += 1 } // skip the original path
                result.append(make(xy: Array(f[1]), path: String(f[9]), untracked: false))
            case "u":
                let f = rec.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard f.count == 11 else { continue }
                result.append(GitChange(path: String(f[10]), status: .conflicted, isUntracked: false))
            case "?":
                result.append(GitChange(path: String(rec.dropFirst(2)), status: .untracked, isUntracked: true))
            default:
                continue // "!" ignored entries
            }
        }
        return result
    }

    /// Builds a change from a porcelain-v2 `XY` field, where `.` means unmodified — the
    /// worktree side (`Y`) wins, falling back to the index side (`X`).
    private static func make(xy: [Character], path: String, untracked: Bool) -> GitChange {
        let x = xy.first ?? "."
        let y = xy.count > 1 ? xy[1] : "."
        let primary: Character = (y != ".") ? y : x
        return GitChange(path: path, status: GitFileStatus(code: primary), isUntracked: untracked)
    }

    /// Fills each change's add/delete counts: `git diff --numstat` (unstaged) merged
    /// with `--cached` (staged) for tracked files, and a line count for untracked ones.
    private static func applyCounts(_ changes: inout [GitChange], repoRoot: String) {
        var counts: [String: (Int, Int)] = [:]
        for args in [["diff", "--numstat"], ["diff", "--numstat", "--cached"]] {
            guard let out = run(args, in: repoRoot) else { continue }
            for line in out.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 2)
                guard parts.count == 3 else { continue }
                let adds = Int(parts[0]) ?? 0   // "-" for binary → 0
                let dels = Int(parts[1]) ?? 0
                let path = String(parts[2])
                let existing = counts[path] ?? (0, 0)
                counts[path] = (existing.0 + adds, existing.1 + dels)
            }
        }
        for idx in changes.indices {
            if changes[idx].isUntracked {
                let abs = (repoRoot as NSString).appendingPathComponent(changes[idx].path)
                if let content = try? String(contentsOfFile: abs, encoding: .utf8), !content.isEmpty {
                    changes[idx].additions = content.split(separator: "\n", omittingEmptySubsequences: false).count
                }
            } else if let c = counts[changes[idx].path] {
                changes[idx].additions = c.0
                changes[idx].deletions = c.1
            }
        }
    }

    /// Reverts one file to clean. Untracked and freshly-added files are deleted from
    /// disk (the added one is unstaged first so git forgets it); everything else is
    /// reset to its `HEAD` blob across both the index and the working tree via
    /// `git restore`. Renames restore the current path only — a rare, best-effort case.
    private static func discardChanges(_ change: GitChange, _ repoRoot: String) -> Bool {
        let abs = (repoRoot as NSString).appendingPathComponent(change.path)
        switch change.status {
        case .untracked:
            return (try? FileManager.default.removeItem(atPath: abs)) != nil
        case .added:
            _ = run(["restore", "--staged", "--", change.path], in: repoRoot, ignoreStatus: true)
            return (try? FileManager.default.removeItem(atPath: abs)) != nil
        default:
            return run(["restore", "--staged", "--worktree", "--source=HEAD", "--", change.path],
                       in: repoRoot, ignoreStatus: true) != nil
        }
    }

    private static func loadDiffText(_ change: GitChange, _ repoRoot: String) -> String {
        if change.isUntracked {
            // `--no-index` exits non-zero when the files differ, which is the normal
            // case here, so the status is ignored.
            return run(["diff", "--no-index", "--", "/dev/null", change.path],
                       in: repoRoot, ignoreStatus: true) ?? ""
        }
        // `diff HEAD` shows staged and unstaged together. Fall back to the split views
        // for a repo with no commit yet, or a fully-staged change.
        if let d = run(["diff", "HEAD", "--", change.path], in: repoRoot), !d.isEmpty { return d }
        let unstaged = run(["diff", "--", change.path], in: repoRoot) ?? ""
        if !unstaged.isEmpty { return unstaged }
        return run(["diff", "--cached", "--", change.path], in: repoRoot) ?? ""
    }

    /// Parses unified-diff text into rows, tracking old/new line numbers from each
    /// hunk header and dropping the file-header lines (`diff --git`, `+++`, …).
    private static func parseDiff(_ text: String) -> [DiffRow] {
        var rows: [DiffRow] = []
        var id = 0
        var oldNo = 0
        var newNo = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("@@") {
                if let (o, n) = parseHunkHeader(line) { oldNo = o; newNo = n }
                rows.append(DiffRow(id: id, kind: .hunk, text: line, oldLine: nil, newLine: nil)); id += 1
                continue
            }
            if isFileHeader(line) { continue }
            guard let first = line.first else { continue }
            let body = String(line.dropFirst())
            switch first {
            case "+":
                rows.append(DiffRow(id: id, kind: .addition, text: body, oldLine: nil, newLine: newNo)); id += 1; newNo += 1
            case "-":
                rows.append(DiffRow(id: id, kind: .deletion, text: body, oldLine: oldNo, newLine: nil)); id += 1; oldNo += 1
            case " ":
                rows.append(DiffRow(id: id, kind: .context, text: body, oldLine: oldNo, newLine: newNo)); id += 1; oldNo += 1; newNo += 1
            default:
                continue
            }
        }
        return rows
    }

    private static func isFileHeader(_ line: String) -> Bool {
        for prefix in ["diff ", "index ", "--- ", "+++ ", "new file", "deleted file",
                       "old mode", "new mode", "similarity ", "dissimilarity ",
                       "rename ", "copy ", "\\ "] where line.hasPrefix(prefix) {
            return true
        }
        return false
    }

    /// Pulls the starting old and new line numbers out of `@@ -a,b +c,d @@`.
    private static func parseHunkHeader(_ line: String) -> (Int, Int)? {
        let parts = line.split(separator: " ")
        guard parts.count >= 3 else { return nil }
        func start(_ s: Substring) -> Int? {
            Int(s.dropFirst().split(separator: ",").first ?? s.dropFirst())
        }
        guard let o = start(parts[1]), let n = start(parts[2]) else { return nil }
        return (o, n)
    }

    // MARK: Process

    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }

    /// Runs `git -C <dir> <args>` and returns stdout, or `nil` on launch failure (or a
    /// non-zero exit unless `ignoreStatus`). stdout is drained *before* `waitUntilExit`
    /// because a diff can exceed the 64 KB pipe buffer and otherwise deadlock the child;
    /// stderr is sent to the null device so it can never fill either.
    private static func run(_ args: [String], in dir: String, ignoreStatus: Bool = false) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", dir] + args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if !ignoreStatus, process.terminationStatus != 0 { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// stderr and exit status of a `git` invocation. Used by the mutating actions, which
    /// need the exit code (to detect failure) and stderr (to surface why). stdout is
    /// drained but discarded — none of the mutating commands' output is shown.
    private struct RunResult { let err: String; let status: Int32 }

    /// Like `run`, but also captures stderr and the exit code. The output of a commit or
    /// push is a handful of lines — well under the pipe buffer — so reading stdout then
    /// stderr sequentially can't deadlock here the way a large diff would.
    private static func runResult(_ args: [String], in dir: String) -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", dir] + args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch {
            return RunResult(err: error.localizedDescription, status: -1)
        }
        // Drain stdout so a chatty command can't block on a full pipe; its contents are
        // unused — only stderr and the exit code matter for a commit/push.
        _ = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return RunResult(
            err: String(data: errData, encoding: .utf8) ?? "",
            status: process.terminationStatus
        )
    }

    /// The last non-empty line of a git error blob (git puts the actionable message last,
    /// after any `hint:` preamble), or `fallback` when stderr is empty.
    static func oneLine(_ stderr: String, fallback: String) -> String {
        let line = stderr.split(separator: "\n").map(String.init)
            .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return line?.trimmingCharacters(in: .whitespaces) ?? fallback
    }
}
