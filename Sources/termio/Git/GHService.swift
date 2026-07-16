import Foundation

// MARK: - GitHub (gh CLI)

/// Thin wrapper over the `gh` CLI for the changes pane's pull-request affordance —
/// the GitHub counterpart of `GitService`. Everything is gated on `gh` being installed
/// *and* authenticated (`isAvailable`); when it isn't, the pane simply hides the PR row,
/// so there is never a hard dependency on GitHub. Every call runs off the main thread.
///
/// termio is launched from Finder, whose `PATH` is minimal (no Homebrew) — the same trap
/// that once broke agent launch — so `gh` is resolved by absolute path, and the child is
/// handed a `PATH` that includes the usual Homebrew/`/usr/bin` locations so `gh` can shell
/// out to `git` itself.
enum GHService {
    /// True only when `gh` is on disk and `gh auth status` succeeds — i.e. the user has a
    /// working GitHub login. Cheap enough to re-check on each pane load.
    static func isAvailable(in repoRoot: String) async -> Bool {
        await offMain {
            guard let gh = ghPath() else { return false }
            return runResult(gh, ["auth", "status"], in: repoRoot).status == 0
        }
    }

    /// The open/merged/closed pull request for the checked-out branch, or `nil` when the
    /// branch has none yet (which is when the pane offers to create one). A non-zero exit
    /// is the normal "no PR for this branch" signal, not an error.
    static func pullRequest(in repoRoot: String) async -> PullRequestInfo? {
        await offMain {
            guard let gh = ghPath() else { return nil }
            let r = runResult(gh, ["pr", "view", "--json",
                                   "number,url,title,state,statusCheckRollup"], in: repoRoot)
            guard r.status == 0, let data = r.out.data(using: .utf8) else { return nil }
            return parsePR(data)
        }
    }

    /// The repo's default branch (the natural PR base), from `gh repo view`. Falls back to
    /// `main` when gh can't answer — the create sheet lets the user override it anyway.
    static func defaultBranch(in repoRoot: String) async -> String {
        await offMain {
            guard let gh = ghPath() else { return "main" }
            let r = runResult(gh, ["repo", "view", "--json", "defaultBranchRef",
                                   "-q", ".defaultBranchRef.name"], in: repoRoot)
            let name = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            return (r.status == 0 && !name.isEmpty) ? name : "main"
        }
    }

    /// Opens a pull request for the current branch. On success the result carries the new
    /// PR's URL (gh prints it on stdout) so the caller can open it in the browser.
    static func createPR(title: String, body: String, base: String, in repoRoot: String) async -> CreatePRResult {
        await offMain {
            guard let gh = ghPath() else { return .failure("GitHub CLI (gh) not found.") }
            var args = ["pr", "create", "--title", title, "--base", base]
            // `--body ""` is valid (an empty description); gh would otherwise open $EDITOR.
            args += ["--body", body]
            let r = runResult(gh, args, in: repoRoot)
            guard r.status == 0 else {
                return .failure(GitService.oneLine(r.err, fallback: "Could not create pull request."))
            }
            let url = r.out.split(separator: "\n").map(String.init)
                .last { $0.hasPrefix("http") } ?? r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            return .success(url)
        }
    }

    // MARK: JSON

    private static func parsePR(_ data: Data) -> PullRequestInfo? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let number = root["number"] as? Int,
              let url = root["url"] as? String
        else { return nil }
        let rollup = (root["statusCheckRollup"] as? [[String: Any]]) ?? []
        return PullRequestInfo(
            number: number,
            url: url,
            title: (root["title"] as? String) ?? "#\(number)",
            state: (root["state"] as? String) ?? "OPEN",
            checks: rollupState(rollup)
        )
    }

    /// Collapses gh's per-check rollup into one badge: any failure wins, then anything
    /// still running reads as pending, otherwise it's passing. An empty rollup means the
    /// PR has no checks configured.
    private static func rollupState(_ checks: [[String: Any]]) -> PRChecks {
        guard !checks.isEmpty else { return .none }
        var sawPending = false
        for check in checks {
            // CheckRun uses `status`+`conclusion`; StatusContext uses `state`.
            let conclusion = ((check["conclusion"] as? String) ?? "").uppercased()
            let state = ((check["state"] as? String) ?? "").uppercased()
            let status = ((check["status"] as? String) ?? "").uppercased()
            if conclusion == "FAILURE" || conclusion == "TIMED_OUT" || conclusion == "CANCELLED"
                || state == "FAILURE" || state == "ERROR" {
                return .failing
            }
            if status == "IN_PROGRESS" || status == "QUEUED" || status == "PENDING"
                || state == "PENDING" || (conclusion.isEmpty && state.isEmpty) {
                sawPending = true
            }
        }
        return sawPending ? .pending : .passing
    }

    // MARK: Process

    /// Resolves the `gh` executable: the common install locations first (fast, no shell),
    /// then a login-shell `command -v gh` for anything exotic. Cached would be premature —
    /// the lookup is only hit on pane load.
    private static func ghPath() -> String? {
        let fm = FileManager.default
        for candidate in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        where fm.isExecutableFile(atPath: candidate) {
            return candidate
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let r = runResult(shell, ["-lc", "command -v gh"], in: nil)
        let path = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return (r.status == 0 && fm.isExecutableFile(atPath: path)) ? path : nil
    }

    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }

    private struct RunResult { let out: String; let err: String; let status: Int32 }

    /// Runs an executable by absolute path with an augmented `PATH` (Homebrew + system) so
    /// `gh` can find `git`. `dir` sets the working directory when the command is repo-scoped.
    private static func runResult(_ launchPath: String, _ args: [String], in dir: String?) -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        if let dir { process.currentDirectoryURL = URL(fileURLWithPath: dir) }
        var env = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PATH"] = env["PATH"].map { "\(extra):\($0)" } ?? extra
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch {
            return RunResult(out: "", err: error.localizedDescription, status: -1)
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return RunResult(
            out: String(data: outData, encoding: .utf8) ?? "",
            err: String(data: errData, encoding: .utf8) ?? "",
            status: process.terminationStatus
        )
    }
}
