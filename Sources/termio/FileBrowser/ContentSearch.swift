import Foundation

/// One grep hit: a line of a file that contains the query.
struct ContentMatch: Sendable {
    /// Path relative to the searched root — the grouping key and header label.
    let relative: String
    let url: URL
    /// 1-based line number, as grep reports it.
    let line: Int
    /// The matched line's text (capped, untrimmed — the row trims for display).
    let text: String
}

/// Project-wide content search behind the inspector's Search pane. `git grep`
/// first — tracked + untracked-but-not-ignored, so ignore rules apply for free,
/// exactly the `listFiles` bargain — falling back to BSD `grep -r` outside a
/// repo. Fixed-string (no regex surprises), smart-case (case-sensitive only
/// when the query has an uppercase letter), binaries skipped, per-file and
/// total caps so a one-letter query in a monorepo can't flood the pane.
/// Blocking — call it off the main thread.
enum ContentSearch {
    /// Hits per file — past this the file's header row says "in this file",
    /// and the user should sharpen the query.
    private static let perFileLimit = "20"
    /// Longest line text kept; minified bundles can put megabytes on one line.
    private static let lineCap = 500

    nonisolated static func search(_ query: String, under root: URL, limit: Int) -> [ContentMatch] {
        guard !query.isEmpty else { return [] }
        // Smart case, the fzf/ripgrep default: all-lowercase queries match
        // insensitively; an uppercase letter opts into exactness.
        let insensitive = query == query.lowercased()

        var gitArgs = ["-C", root.path, "grep", "-I", "--line-number",
                       "--fixed-strings", "--untracked", "--max-count=\(perFileLimit)"]
        if insensitive { gitArgs.append("--ignore-case") }
        gitArgs += ["-e", query, "--", "."]
        // Exit 0 = hits, 1 = clean no-hits; ≥2 = not a repo (or git error) → fall back.
        if let result = run("/usr/bin/git", gitArgs), result.status <= 1 {
            return parse(result.output, root: root, strippingPrefix: nil, limit: limit)
        }

        var grepArgs = ["-r", "-n", "--fixed-strings", "--binary-files=without-match",
                        "-m", perFileLimit,
                        "--exclude-dir=.git", "--exclude-dir=node_modules",
                        "--exclude-dir=.build", "--exclude-dir=DerivedData"]
        if insensitive { grepArgs.append("-i") }
        grepArgs += ["-e", query, root.path]
        guard let result = run("/usr/bin/grep", grepArgs), result.status <= 1 else { return [] }
        return parse(result.output, root: root, strippingPrefix: root.path + "/", limit: limit)
    }

    /// `path:line:text` per line — git grep emits repo-relative paths, BSD grep
    /// absolute ones (stripped back to relative via `strippingPrefix`). A path
    /// containing `:` would mis-split; accepted as vanishingly rare.
    private static func parse(_ output: String, root: URL, strippingPrefix: String?, limit: Int) -> [ContentMatch] {
        var out: [ContentMatch] = []
        for rawLine in output.split(separator: "\n") {
            if out.count >= limit { break }
            guard let firstColon = rawLine.firstIndex(of: ":") else { continue }
            let afterPath = rawLine.index(after: firstColon)
            guard let secondColon = rawLine[afterPath...].firstIndex(of: ":"),
                  let lineNumber = Int(rawLine[afterPath..<secondColon]) else { continue }
            var path = String(rawLine[..<firstColon])
            if let strippingPrefix, path.hasPrefix(strippingPrefix) {
                path = String(path.dropFirst(strippingPrefix.count))
            }
            let text = String(rawLine[rawLine.index(after: secondColon)...].prefix(lineCap))
            out.append(ContentMatch(
                relative: path,
                url: root.appendingPathComponent(path),
                line: lineNumber,
                text: text
            ))
        }
        return out
    }

    private static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        return (process.terminationStatus, output)
    }
}
