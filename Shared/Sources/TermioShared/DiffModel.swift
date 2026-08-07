import Foundation

// MARK: - Unified diff model

/// One line of a parsed unified diff. `text` is the line *without* its `+`/`-`/space
/// marker, so a renderer can style the marker itself (or draw it outside the text, the
/// way both the desktop gutter and the phone's edge bar do) instead of baking it in.
public struct DiffLine: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case addition, deletion, context, hunk }

    public let id: Int
    public let kind: Kind
    public let text: String
    public let oldLine: Int?
    public let newLine: Int?
    /// The changed span within a paired deletion/addition line, in `Character`
    /// offsets — rendered with a stronger tint so a one-word edit inside a long line
    /// reads at a glance. `nil` when the line has no counterpart, or the two sides
    /// share too little for a span to mean anything.
    public var emphasis: Range<Int>?

    public init(
        id: Int, kind: Kind, text: String, oldLine: Int?, newLine: Int?,
        emphasis: Range<Int>? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.oldLine = oldLine
        self.newLine = newLine
        self.emphasis = emphasis
    }
}

/// What a renderer actually lays out: a code line, or a band standing in for a run of
/// unchanged lines that is folded away.
public enum DiffItem: Sendable, Equatable {
    case line(DiffLine)
    /// A folded run, named by the line range it hides (new-side numbers, so it reads
    /// against the gutter) — "227–348" says where you are; a count would only describe
    /// the fold. `expandable` bands (full-context diffs) hold their hidden lines and
    /// splice them back in when tapped; fixed bands (a 3-line-context diff, where the
    /// hidden lines were never fetched) only mark the gap.
    case band(id: Int, lines: ClosedRange<Int>, expandable: Bool)
}

/// Parsing and folding unified-diff text, kept free of any UI framework so both ends
/// share one reading of a diff. The desktop renders through its own AppKit document
/// today; this is the model the iOS diff view is built on.
public enum DiffParser {
    /// Parses unified-diff text into lines, tracking old/new line numbers from each
    /// hunk header and dropping the file-header plumbing (`diff --git`, `+++`, …).
    public static func lines(from text: String) -> [DiffLine] {
        var rows: [DiffLine] = []
        var id = 0
        var oldNo = 0
        var newNo = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("@@") {
                if let (o, n) = parseHunkHeader(line) { oldNo = o; newNo = n }
                // Hunk rows carry their start numbers so a renderer can size the gap to
                // the previous hunk when it draws the boundary as a band.
                rows.append(DiffLine(id: id, kind: .hunk, text: line, oldLine: oldNo, newLine: newNo))
                id += 1
                continue
            }
            if isFileHeader(line) { continue }
            guard let first = line.first else { continue }
            let body = String(line.dropFirst())
            switch first {
            case "+":
                rows.append(DiffLine(id: id, kind: .addition, text: body, oldLine: nil, newLine: newNo))
                id += 1; newNo += 1
            case "-":
                rows.append(DiffLine(id: id, kind: .deletion, text: body, oldLine: oldNo, newLine: nil))
                id += 1; oldNo += 1
            case " ":
                rows.append(DiffLine(id: id, kind: .context, text: body, oldLine: oldNo, newLine: newNo))
                id += 1; oldNo += 1; newNo += 1
            default:
                continue
            }
        }
        applyIntraline(&rows)
        return rows
    }

    /// Folds parsed lines into the display list: hunk plumbing disappears (its gap
    /// becomes a band), unchanged runs longer than a handful of lines collapse to a
    /// band keeping 3 lines of context on the side(s) facing a change, and ids in
    /// `expanded` splice their hidden lines back in.
    public static func displayItems(lines rows: [DiffLine], expanded: Set<Int>) -> [DiffItem] {
        var items: [DiffItem] = []
        var run: [DiffLine] = []
        var sawChange = false
        var lastNewLine = 0

        func flush(isLast: Bool) {
            defer { run = [] }
            guard !run.isEmpty else { return }
            let head = sawChange ? 3 : 0
            let tail = isLast ? 0 : 3
            let hidden = run.count - head - tail
            guard hidden >= 10 else {
                items += run.map(DiffItem.line)
                return
            }
            items += run.prefix(head).map(DiffItem.line)
            let hiddenRows = Array(run.dropFirst(head).dropLast(tail))
            if expanded.contains(hiddenRows[0].id) {
                items += hiddenRows.map(DiffItem.line)
            } else {
                let first = hiddenRows[0].newLine ?? hiddenRows[0].oldLine ?? 0
                let last = hiddenRows[hiddenRows.count - 1].newLine
                    ?? hiddenRows[hiddenRows.count - 1].oldLine ?? first
                items.append(.band(
                    id: hiddenRows[0].id, lines: first...max(first, last), expandable: true
                ))
            }
            items += run.suffix(tail).map(DiffItem.line)
        }

        for row in rows {
            switch row.kind {
            case .hunk:
                flush(isLast: false)
                if let start = row.newLine, start > lastNewLine + 1 {
                    items.append(.band(
                        id: row.id, lines: (lastNewLine + 1)...(start - 1), expandable: false
                    ))
                }
            case .context:
                run.append(row)
                lastNewLine = row.newLine ?? lastNewLine
            case .addition:
                flush(isLast: false)
                sawChange = true
                items.append(.line(row))
                lastNewLine = row.newLine ?? lastNewLine
            case .deletion:
                flush(isLast: false)
                sawChange = true
                items.append(.line(row))
            }
        }
        flush(isLast: true)
        return items
    }

    // MARK: Intraline

    /// Marks the changed span inside modified lines: within each run, a block of
    /// deletions immediately followed by a block of additions is paired index-wise, and
    /// each pair gets its common prefix/suffix stripped to leave the span that changed.
    private static func applyIntraline(_ rows: inout [DiffLine]) {
        var i = 0
        while i < rows.count {
            guard rows[i].kind == .deletion else { i += 1; continue }
            let delStart = i
            while i < rows.count, rows[i].kind == .deletion { i += 1 }
            let addStart = i
            while i < rows.count, rows[i].kind == .addition { i += 1 }
            for k in 0..<min(addStart - delStart, i - addStart) {
                guard let (old, new) = emphasisRanges(rows[delStart + k].text, rows[addStart + k].text)
                else { continue }
                rows[delStart + k].emphasis = old
                rows[addStart + k].emphasis = new
            }
        }
    }

    /// The changed spans of a deletion/addition pair: the common prefix and suffix are
    /// peeled off, then the boundaries snap outward to whole words so renaming
    /// `newValue` → `oldValue` highlights the identifiers, not a `ldValue` tail. `nil`
    /// when the sides share under a fifth of the shorter line — a rewrite, where
    /// span-highlighting the whole line would just be noise.
    private static func emphasisRanges(_ oldText: String, _ newText: String) -> (Range<Int>, Range<Int>)? {
        guard oldText != newText, oldText.count <= 2000, newText.count <= 2000 else { return nil }
        let o = Array(oldText), n = Array(newText)
        var prefix = 0
        while prefix < o.count, prefix < n.count, o[prefix] == n[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < o.count - prefix, suffix < n.count - prefix,
              o[o.count - 1 - suffix] == n[n.count - 1 - suffix] { suffix += 1 }
        guard (prefix + suffix) * 5 >= min(o.count, n.count) else { return nil }

        // CJK scripts have no intra-word boundaries, so snapping there would swallow the
        // whole run — every ideograph/kana counts as its own boundary instead.
        func isWord(_ c: Character) -> Bool {
            guard c.isLetter || c.isNumber || c == "_" else { return false }
            guard let scalar = c.unicodeScalars.first else { return false }
            return scalar.value < 0x2E80
        }
        while prefix > 0, isWord(o[prefix - 1]),
              (prefix < o.count - suffix && isWord(o[prefix]))
                || (prefix < n.count - suffix && isWord(n[prefix])) {
            prefix -= 1
        }
        while suffix > 0, isWord(o[o.count - suffix]),
              (o.count - suffix > prefix && isWord(o[o.count - suffix - 1]))
                || (n.count - suffix > prefix && isWord(n[n.count - suffix - 1])) {
            suffix -= 1
        }
        return (prefix..<(o.count - suffix), prefix..<(n.count - suffix))
    }

    // MARK: Line scanning

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
}
