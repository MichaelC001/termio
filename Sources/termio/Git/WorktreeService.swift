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

    /// The linked worktree paths for `repoRoot`, primary checkout excluded and paths
    /// standardized. `nil` when `git worktree list` fails (not a work tree, or a git
    /// error) — the caller treats `nil` as "leave the current list alone" and `[]` as
    /// "git genuinely reports no linked worktrees" (safe to prune).
    ///
    /// A `prunable` worktree — its directory deleted out from under git — is skipped,
    /// as is any path that no longer exists on disk. Without this, a stale worktree
    /// would show in the sidebar and a session started there would launch with a
    /// missing cwd, so the shell silently falls back to `/` (the bug this guards
    /// against).
    static func linkedWorktrees(in repoRoot: String) async -> [String]? {
        await offMain {
            guard let all = records(in: repoRoot) else { return nil }
            return all.dropFirst()                                      // primary checkout
                .filter { !$0.bare && !$0.prunable }
                .compactMap { record in
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: record.path, isDirectory: &isDirectory),
                          isDirectory.boolValue else { return nil }
                    return URL(fileURLWithPath: record.path).standardizedFileURL.path
                }
        }
    }

    /// The repo's worktree records, primary checkout first, in git's order. `nil`
    /// when `git worktree list` fails. Blocks on the git spawn — callers already on
    /// a git-spawning path use it directly; use `linkedWorktrees` off-main.
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
