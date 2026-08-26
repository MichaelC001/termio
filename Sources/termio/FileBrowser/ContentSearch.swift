import Foundation

/// One grep hit: a line of a file that contains the query, with the lines around
/// it and — the part that matters — where the query actually hit.
///
/// The spans come from whichever matcher found the line: `git grep`'s own case
/// rule locally, the host's for a device. Nothing downstream re-searches the
/// text. A results row that finds its own highlights is running a second matcher
/// beside the first, and two matchers disagree in exactly the cases that look
/// like bugs: an uppercase query painting lowercase text, a line whose match sat
/// past the length cap and so lit up nothing at all.
struct ContentMatch: Sendable {
    /// Path relative to the searched root — the grouping key and header label.
    let relative: String
    let url: URL
    /// 1-based line number, as grep reports it.
    let line: Int
    /// The matched line, or a window of it when the line is long enough that
    /// sending the whole thing is pointless. Untrimmed — the row trims.
    let text: String
    /// Where the query hit inside `text`. Empty only against a host too old to
    /// report spans, where the row falls back to painting nothing rather than
    /// guessing.
    let spans: [Range<String.Index>]
    /// True when `text` is a window cut out of a longer line, so the row can say
    /// so rather than implying the line begins there.
    let isWindowed: Bool
    /// The lines immediately before and after, for the excerpt. Empty when the
    /// hit is at the top or bottom of its file, or from a host too old to send
    /// context.
    let before: [String]
    private(set) var after: [String]

    /// Appends a line of trailing context, as grep hands it over after the hit.
    mutating func appendAfter(_ line: String) {
        after.append(line)
    }

    /// The line numbers `before` and `after` occupy, which the excerpt gutter
    /// needs and which are pure arithmetic off `line`.
    var firstLine: Int { line - before.count }

    /// A byte range measured by a host, as a range of `text`'s characters.
    /// `nil` when the bytes do not land on character boundaries — a host and a
    /// client disagreeing about where a character starts is a highlight in the
    /// wrong place, and none is better than wrong.
    static func range(_ text: String, bytes: Range<Int>) -> Range<String.Index>? {
        let utf8 = text.utf8
        guard bytes.lowerBound >= 0, bytes.upperBound <= utf8.count else { return nil }
        let start = utf8.index(utf8.startIndex, offsetBy: bytes.lowerBound)
        let end = utf8.index(utf8.startIndex, offsetBy: bytes.upperBound)
        guard let lower = start.samePosition(in: text),
              let upper = end.samePosition(in: text), lower <= upper else { return nil }
        return lower ..< upper
    }
}

/// Project-wide content search behind the inspector's Search pane. `git grep`
/// first — tracked + untracked-but-not-ignored, so ignore rules apply for free,
/// exactly the `listFiles` bargain — falling back to BSD `grep -r` outside a
/// repo. Fixed-string (no regex surprises), smart-case (case-sensitive only
/// when the query has an uppercase letter), binaries skipped, per-file and
/// total caps so a one-letter query in a monorepo can't flood the pane.
/// Cancellation-aware: cancelling the surrounding task terminates the grep.
enum ContentSearch {
    /// Hits per file — past this the file's header row says "in this file",
    /// and the user should sharpen the query.
    private static let perFileLimit = "20"
    /// Lines of context on each side of a hit, matching what the device's host
    /// sends (`SEARCH_CONTEXT_LINES`) so both roads draw the same excerpt.
    static let contextLines = 2
    /// How much of a long line to keep ahead of the first hit.
    private static let windowLead = 64
    /// Longest line text kept; minified bundles can put megabytes on one line.
    private static let lineCap = 500
    /// Byte ceiling on buffered tool output. `maxLines` bounds complete lines,
    /// but the reader only counts newlines — one minified bundle line could
    /// otherwise grow the buffer without limit before its newline ever arrives.
    private static let outputByteCap = 4 << 20

    nonisolated static func search(_ query: String, under root: URL, limit: Int) async -> [ContentMatch] {
        guard !query.isEmpty else { return [] }
        // Smart case, the fzf/ripgrep default: all-lowercase queries match
        // insensitively; an uppercase letter opts into exactness.
        let insensitive = query == query.lowercased()

        var gitArgs = ["-C", root.path, "grep", "-I", "--line-number",
                       "--fixed-strings", "--untracked", "--max-count=\(perFileLimit)",
                       "-C", "\(contextLines)"]
        if insensitive { gitArgs.append("--ignore-case") }
        gitArgs += ["-e", query, "--", "."]
        // Exit 0 = hits, 1 = clean no-hits; ≥2 = not a repo (or git error) → fall back.
        if let result = await run("/usr/bin/git", gitArgs, maxLines: limit), result.status <= 1 {
            return parse(result.output, root: root, query: query,
                         insensitive: insensitive, strippingPrefix: nil, limit: limit)
        }
        // A cancelled git grep dies by signal, which looks like the ≥2 error
        // path — don't misread it as "not a repo" and launch the fallback scan.
        guard !Task.isCancelled else { return [] }

        var grepArgs = ["-r", "-n", "--fixed-strings", "--binary-files=without-match",
                        "-m", perFileLimit, "-C", "\(contextLines)",
                        "--exclude-dir=.git", "--exclude-dir=node_modules",
                        "--exclude-dir=.build", "--exclude-dir=DerivedData"]
        if insensitive { grepArgs.append("-i") }
        grepArgs += ["-e", query, root.path]
        guard let result = await run("/usr/bin/grep", grepArgs, maxLines: limit), result.status <= 1 else { return [] }
        return parse(result.output, root: root, query: query, insensitive: insensitive,
                     strippingPrefix: root.path + "/", limit: limit)
    }

    /// One line of grep output: `path:line:text` is a hit, `path-line-text` is a
    /// context line, `--` ends a run. Which separator follows the path is the
    /// only thing that tells a hit from its context — the line number cannot,
    /// and reading it wrong would paint context as a match.
    private enum OutputLine {
        case hit(path: String, line: Int, text: String)
        case context(path: String, text: String)
        case separator
    }

    private static func classify(_ raw: Substring, strippingPrefix: String?) -> OutputLine? {
        if raw == "--" { return .separator }
        func relative(_ path: Substring) -> String {
            var path = String(path)
            if let strippingPrefix, path.hasPrefix(strippingPrefix) {
                path = String(path.dropFirst(strippingPrefix.count))
            }
            return path
        }
        // A hit first: a path containing a hyphen is ordinary, and splitting on
        // the hyphen first would tear one apart.
        if let colon = raw.firstIndex(of: ":") {
            let afterPath = raw.index(after: colon)
            if let second = raw[afterPath...].firstIndex(of: ":"),
               let number = Int(raw[afterPath..<second]) {
                return .hit(path: relative(raw[..<colon]), line: number,
                            text: String(raw[raw.index(after: second)...]))
            }
        }
        guard let dash = raw.firstIndex(of: "-") else { return nil }
        let afterPath = raw.index(after: dash)
        guard let second = raw[afterPath...].firstIndex(of: "-"),
              Int(raw[afterPath..<second]) != nil else { return nil }
        return .context(path: relative(raw[..<dash]),
                        text: String(raw[raw.index(after: second)...]))
    }

    /// Folds grep's output — hits interleaved with their context — into matches
    /// that carry their own excerpt and their own spans.
    private static func parse(_ output: String, root: URL, query: String,
                              insensitive: Bool, strippingPrefix: String?,
                              limit: Int) -> [ContentMatch] {
        var out: [ContentMatch] = []
        var before: [String] = []
        // The hit still collecting the lines after it. An index, so the context
        // can be appended to a match already in `out`.
        var trailing: Int?
        // Walk lines by index instead of `split`: split materializes every line
        // of the output up front, paying for the whole array even though this
        // loop stops at `limit`.
        var cursor = output.startIndex
        while cursor < output.endIndex, out.count < limit {
            let lineEnd = output[cursor...].firstIndex(of: "\n") ?? output.endIndex
            let rawLine = output[cursor..<lineEnd]
            cursor = lineEnd == output.endIndex ? output.endIndex : output.index(after: lineEnd)
            switch classify(rawLine, strippingPrefix: strippingPrefix) {
            case .separator, .none:
                before.removeAll()
                trailing = nil
            case .context(_, let text):
                // The lines after one hit and before the next are the same
                // lines; bank them once and let both sides read them.
                if let index = trailing, out[index].after.count < contextLines {
                    out[index].appendAfter(text)
                } else {
                    trailing = nil
                }
                before.append(text)
                if before.count > contextLines { before.removeFirst() }
            case .hit(let path, let line, let text):
                out.append(match(
                    relative: path, root: root, line: line, text: text,
                    query: query, insensitive: insensitive, before: before))
                before.removeAll()
                trailing = out.count - 1
            }
        }
        return out
    }

    /// Builds one match: the spans where the query hit under the same case rule
    /// grep ran with, and a window of the line that contains the first of them.
    ///
    /// The window is why a hit in a minified file still lights up. Truncating a
    /// long line from the start sends the row a stretch of text the query is not
    /// in, and the row then draws no highlight at all — which reads as the
    /// search being wrong rather than the line being long.
    static func match(relative: String, root: URL, line: Int, text: String,
                      query: String, insensitive: Bool,
                      before: [String] = [], after: [String] = []) -> ContentMatch {
        let options: String.CompareOptions = insensitive ? [.literal, .caseInsensitive] : [.literal]
        var windowed = text
        var isWindowed = false
        if text.count > lineCap, let first = text.range(of: query, options: options) {
            let lead = text.index(first.lowerBound, offsetBy: -windowLead,
                                  limitedBy: text.startIndex) ?? text.startIndex
            let tail = text.index(lead, offsetBy: lineCap, limitedBy: text.endIndex) ?? text.endIndex
            windowed = String(text[lead..<tail])
            isWindowed = lead != text.startIndex
        } else if text.count > lineCap {
            windowed = String(text.prefix(lineCap))
        }
        var spans: [Range<String.Index>] = []
        var rest = windowed.startIndex
        while rest < windowed.endIndex,
              let found = windowed.range(of: query, options: options,
                                         range: rest ..< windowed.endIndex) {
            spans.append(found)
            rest = found.upperBound > found.lowerBound
                ? found.upperBound
                : windowed.index(after: found.lowerBound)
        }
        return ContentMatch(
            relative: relative, url: root.appendingPathComponent(relative),
            line: line, text: windowed, spans: spans, isWindowed: isWindowed,
            before: before, after: after)
    }

    /// Runs the tool, draining stdout incrementally. `--max-count` is per FILE,
    /// so a short query in a monorepo has no global bound — the caller only
    /// keeps `maxLines` lines, so once that many have arrived the tool is
    /// terminated instead of letting it flood the pipe. Cancelling the
    /// surrounding task also terminates it, which unblocks the read via EOF.
    private static func run(
        _ executable: String, _ arguments: [String], maxLines: Int
    ) async -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // See `GitEnvironment`: keep `git grep` from touching the index; the BSD
        // `grep` fallback ignores it.
        if executable.hasSuffix("/git") {
            process.environment = GitEnvironment.optionalLocksDisabled
        }
        let stdout = Pipe()
        process.standardOutput = stdout
        // Never attach a pipe that isn't drained: BSD grep can emit 64KB+ of
        // per-file "Permission denied" noise, filling the buffer and deadlocking
        // the child against our stdout read. Discard stderr at the kernel.
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }

        return await withTaskCancellationHandler {
            let handle = stdout.fileHandleForReading
            var data = Data()
            var newlines = 0
            var stoppedEarly = false
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }  // EOF: exited, or terminated by cancel
                for byte in chunk where byte == UInt8(ascii: "\n") { newlines += 1 }
                data.append(chunk)
                if newlines >= maxLines || data.count >= outputByteCap {
                    stoppedEarly = true
                    process.terminate()
                    break
                }
            }
            process.waitUntilExit()
            // Lossy on purpose: stopping at a cap can cut the final chunk
            // mid-codepoint, and a strict decode would trade every hit already
            // buffered for one dangling byte.
            let output = String(decoding: data, as: UTF8.self)
            // Self-terminated = success with a full budget of lines; the real
            // exit status is just the SIGTERM we sent.
            return (stoppedEarly ? 0 : process.terminationStatus, output)
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}
