import Foundation

// MARK: - AI commit message

/// Generates a commit message by shelling out to an already-installed, already-authed
/// agent CLI (`claude -p`, falling back to `codex exec`) — no API keys, no networking of
/// our own, the same `Process`-by-absolute-path shape as `GHService`. termio is an agent
/// terminal, so the agent the user already uses writes the message; the result always
/// lands *editable* in the field, never auto-committed.
enum AICommitMessage {
    /// The instruction handed to the agent. The diff itself arrives on stdin, so this stays
    /// short and the model can't confuse prose for diff content.
    private static let prompt = """
    Read the git diff on stdin and write ONE Conventional Commits message for it.
    Format: a `type(scope): subject` line under 72 characters; if the change warrants it, \
    add a blank line then 1–3 short bullet points. Use types like feat, fix, refactor, \
    docs, chore, style, test. Output ONLY the commit message — no code fences, no preamble, \
    no sign-off, no Co-Authored-By trailer.
    """

    /// True when at least one supported agent CLI resolves — gates the ✨ button so it is
    /// simply absent (no nag) on a machine without claude or codex.
    static func isAvailable() async -> Bool {
        await offMain { resolve("claude") != nil || resolve("codex") != nil }
    }

    /// Produces a message from `diff` (already the concatenated diffs of the checked files).
    /// Capped at 24 KB so a huge changeset stays fast and cheap; the trailing overflow is
    /// dropped rather than truncating mid-token in a way that confuses the model.
    static func generate(diff: String) async -> CreatePRResult {
        await offMain {
            let trimmed = diff.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .failure("Nothing to summarize.") }
            let capped = String(trimmed.prefix(24_000))
            if let claude = resolve("claude") {
                return run(claude, ["-p", prompt, "--model", "haiku"], stdin: capped,
                           fallback: "Claude could not generate a message.")
            }
            if let codex = resolve("codex") {
                return run(codex, ["exec", prompt], stdin: capped,
                           fallback: "Codex could not generate a message.")
            }
            return .failure("No agent CLI (claude or codex) found.")
        }
    }

    // MARK: Process

    /// Runs an agent CLI with `diff` on stdin and returns its trimmed stdout. A 45-second
    /// watchdog terminates a hung CLI. stdin (≤24 KB) is written and closed before stdout is
    /// drained — well under the pipe buffer, so it can't deadlock.
    private static func run(_ launchPath: String, _ args: [String], stdin: String, fallback: String) -> CreatePRResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PATH"] = env["PATH"].map { "\(extra):\($0)" } ?? extra
        process.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe
        do { try process.run() } catch { return .failure(error.localizedDescription) }

        inPipe.fileHandleForWriting.write(Data(stdin.utf8))
        try? inPipe.fileHandleForWriting.close()

        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 45, execute: watchdog)

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        let text = String(data: outData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0, !text.isEmpty else {
            let err = String(data: errData, encoding: .utf8) ?? ""
            return .failure(GitService.oneLine(err, fallback: fallback))
        }
        return .success(stripFences(text))
    }

    /// Strips a ```-fenced wrapper if the model added one despite being told not to.
    private static func stripFences(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.first?.hasPrefix("```") == true { lines.removeFirst() }
        if lines.last?.hasPrefix("```") == true { lines.removeLast() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resolves an agent CLI to an absolute path: common install locations first (no shell),
    /// then a login-shell lookup — the Finder-minimal `PATH` won't find it otherwise.
    private static func resolve(_ tool: String) -> String? {
        let fm = FileManager.default
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let candidate = "\(dir)/\(tool)"
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let lookup = Process()
        lookup.executableURL = URL(fileURLWithPath: shell)
        lookup.arguments = ["-lc", "command -v \(tool)"]
        let pipe = Pipe()
        lookup.standardOutput = pipe
        lookup.standardError = FileHandle.nullDevice
        do { try lookup.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        lookup.waitUntilExit()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (lookup.terminationStatus == 0 && fm.isExecutableFile(atPath: path)) ? path : nil
    }

    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }
}
