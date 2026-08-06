import AppKit

// MARK: - Band expansion

/// Which end of a collapsed run a click reveals. The chevron points the way the reader is
/// looking: `up` pulls down the lines nearest the code *below* the band, `down` the lines
/// nearest the code above it. `all` drops the band entirely.
enum DiffBandDirection {
    case up, down, all
}

/// How much of each collapsed run the reader has revealed, keyed by the run's anchor row
/// id. The anchor is the run's first hidden row, which is stable as the run shrinks: the
/// always-shown context lines on either side never move, so revealing from one end never
/// renames the band.
struct DiffExpansion: Equatable {
    /// Lines revealed per click, matching the step every other review surface uses.
    /// Revealing a 400-line gap in one jump loses the reader's place.
    static let step = 20

    private struct Reveal: Equatable {
        var head = 0
        var tail = 0
        var all = false
    }

    private var reveals: [Int: Reveal] = [:]

    init() {}

    var isEmpty: Bool { reveals.isEmpty }

    mutating func reveal(_ anchor: Int, _ direction: DiffBandDirection) {
        var reveal = reveals[anchor] ?? Reveal()
        switch direction {
        case .down: reveal.head += Self.step
        case .up: reveal.tail += Self.step
        case .all: reveal.all = true
        }
        reveals[anchor] = reveal
    }

    /// How many of a run's `count` hidden lines to splice back in at each end.
    func revealed(_ anchor: Int, of count: Int) -> (head: Int, tail: Int) {
        guard let reveal = reveals[anchor] else { return (0, 0) }
        if reveal.all { return (count, 0) }
        let head = min(reveal.head, count)
        return (head, min(reveal.tail, count - head))
    }
}

// MARK: - Diff document

/// The whole diff as one immutable text document: an attributed string (one paragraph
/// per rendered element) plus per-paragraph metadata the layout manager and gutter
/// read at draw time. Built once per (rows, expansion) pair; the text view swaps it
/// in wholesale — TextKit owns layout, wrapping, selection, and the find bar from
/// there, which is what buys continuous multi-line selection and ⌘F.
final class DiffDocument {
    /// One paragraph of the document — a code line, or a collapsed band standing in
    /// for a run of unchanged lines.
    struct Line {
        enum Role {
            case code(DiffRow.Kind)
            /// A band's `controls` are the reveal buttons the gutter offers for it. Empty
            /// means the band is inert: the default-context fallback, where the hidden
            /// lines were never fetched and so cannot be revealed at all.
            case band(controls: BandControls)
        }

        /// The reveal buttons a band offers. A run with nothing rendered above it has no
        /// downward button (there is no code to continue from), and likewise upward.
        struct BandControls: OptionSet {
            let rawValue: Int
            static let up = BandControls(rawValue: 1 << 0)
            static let down = BandControls(rawValue: 1 << 1)
        }

        let role: Role
        /// The paragraph's range in the document, including its trailing newline.
        let range: NSRange
        /// `DiffRow.id` for a code line (keys the syntax-color pass); the run's anchor
        /// row id for a band (keys the reveal state).
        let rowId: Int
        let oldLine: Int?
        let newLine: Int?

        var isBand: Bool {
            if case .band = role { return true }
            return false
        }

        /// The reveal buttons this line offers, empty for anything that is not an
        /// expandable band.
        var bandControls: BandControls {
            if case .band(let controls) = role { return controls }
            return []
        }
    }

    let attributed: NSAttributedString
    let lines: [Line]
    /// The tints this document was laid out with. Carried here rather than passed
    /// alongside so the layout manager, the gutter, and the emphasis spans baked into
    /// `attributed` can never disagree about the palette.
    let palette: DiffPalette
    /// Whether any code line carries an old/new number. A pure-addition file has no
    /// old numbers, so that gutter column collapses rather than showing a blank band;
    /// likewise a pure deletion collapses the new column.
    let hasOldGutter: Bool
    let hasNewGutter: Bool
    /// The largest line number shown, sizing the gutter columns.
    let maxLineNumber: Int

    private init(attributed: NSAttributedString, lines: [Line], palette: DiffPalette,
                 hasOldGutter: Bool, hasNewGutter: Bool, maxLineNumber: Int) {
        self.attributed = attributed
        self.lines = lines
        self.palette = palette
        self.hasOldGutter = hasOldGutter
        self.hasNewGutter = hasNewGutter
        self.maxLineNumber = maxLineNumber
    }

    /// Extra breathing room drawn around a band row (the fill is expanded to match).
    static let bandPadding: CGFloat = 3

    // MARK: Building

    /// Folds the parsed rows into the display list and lays it down as one attributed
    /// string. Hunk plumbing disappears (its gap becomes a band), unchanged runs longer
    /// than a handful of lines collapse to a band keeping 3 lines of context on the
    /// side(s) that face a change, and whatever `expansion` has revealed is spliced back in.
    static func build(rows: [DiffRow], expansion: DiffExpansion, palette: DiffPalette,
                      codeFont: NSFont, lineSpacing: CGFloat) -> DiffDocument {
        build(items: displayItems(rows: rows, expansion: expansion), allRows: rows,
              palette: palette, codeFont: codeFont, lineSpacing: lineSpacing)
    }

    /// The shared assembly: lays the display items down as one attributed string with
    /// per-paragraph metadata. `allRows` sizes the gutter columns (which sides carry
    /// numbers, and the widest).
    private static func build(items: [DisplayItem], allRows: [DiffRow], palette: DiffPalette,
                              codeFont: NSFont, lineSpacing: CGFloat) -> DiffDocument {
        var text = String()
        text.reserveCapacity(items.reduce(0) { $0 + $1.textLength + 1 })
        var lines: [Line] = []
        lines.reserveCapacity(items.count)
        var maxLineNumber = 0

        for item in items {
            let location = (text as NSString).length
            switch item {
            case .line(let row):
                text += row.text
                text += "\n"
                let length = (row.text as NSString).length + 1
                lines.append(Line(role: .code(row.kind), range: NSRange(location: location, length: length),
                                  rowId: row.id, oldLine: row.oldLine, newLine: row.newLine))
                maxLineNumber = max(maxLineNumber, row.oldLine ?? 0, row.newLine ?? 0)
            case .band(let id, let label, let controls):
                text += label
                text += "\n"
                let length = (label as NSString).length + 1
                lines.append(Line(role: .band(controls: controls),
                                  range: NSRange(location: location, length: length),
                                  rowId: id, oldLine: nil, newLine: nil))
            }
        }

        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: codeFont,
            .foregroundColor: NSColor.labelColor,
        ])
        // Leading from the configured code line height — the same lift the file editor gets.
        // Bands and headers re-set their own styles below, with the same spacing.
        let baseStyle = NSMutableParagraphStyle()
        baseStyle.lineSpacing = lineSpacing
        attributed.addAttribute(.paragraphStyle, value: baseStyle,
                                range: NSRange(location: 0, length: attributed.length))
        styleBandsAndEmphasis(attributed, items: items, lines: lines, palette: palette,
                              lineSpacing: lineSpacing)

        return DiffDocument(
            attributed: attributed,
            lines: lines,
            palette: palette,
            hasOldGutter: allRows.contains { $0.kind != .hunk && $0.oldLine != nil },
            hasNewGutter: allRows.contains { $0.kind != .hunk && $0.newLine != nil },
            maxLineNumber: maxLineNumber
        )
    }

    /// The index of the first line whose paragraph ends past `location` — the entry
    /// point for draw-time walks, so painting only ever touches the visible lines.
    func lineIndex(at location: Int) -> Int {
        var low = 0, high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(lines[mid].range) <= location { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// The line containing the character at `location`, if any.
    func line(at location: Int) -> Line? {
        let index = lineIndex(at: location)
        guard index < lines.count, NSLocationInRange(location, lines[index].range) else { return nil }
        return lines[index]
    }

    // MARK: Attributes

    /// Bands restyle to the UI font — left-aligned at the code column, so the row reads as
    /// a control rather than as decoration floating in the middle of the diff; the reveal
    /// chevrons live in the gutter beside it. Intraline emphasis lands as a
    /// `.backgroundColor` attribute — the layout manager's washes paint underneath, and
    /// TextKit's own background pass composites the deeper tint on top.
    private static func styleBandsAndEmphasis(_ attributed: NSMutableAttributedString,
                                              items: [DisplayItem], lines: [Line],
                                              palette: DiffPalette, lineSpacing: CGFloat) {
        let bandStyle = NSMutableParagraphStyle()
        bandStyle.lineSpacing = lineSpacing
        bandStyle.paragraphSpacingBefore = bandPadding
        bandStyle.paragraphSpacing = bandPadding

        for (item, line) in zip(items, lines) {
            switch item {
            case .band(_, _, let controls):
                // The label keeps the code font (inherited from the base attributes):
                // it is a line range, so it should line up with the numbers it names, the
                // way github.com renders its `@@` row in the code face.
                var attrs: [NSAttributedString.Key: Any] = [
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: bandStyle,
                ]
                if !controls.isEmpty { attrs[.cursor] = NSCursor.pointingHand }
                attributed.addAttributes(attrs, range: line.range)
            case .line(let row):
                guard !row.emphasis.isEmpty else { continue }
                let color = row.kind == .addition
                    ? palette.additionEmphasis
                    : palette.deletionEmphasis
                for span in row.emphasis {
                    guard !span.isEmpty, let range = utf16Range(of: span, in: row.text) else { continue }
                    attributed.addAttribute(
                        .backgroundColor, value: color,
                        range: NSRange(location: line.range.location + range.location,
                                       length: range.length))
                }
            }
        }
    }

    /// `DiffRow.emphasis` is in `Character` offsets (the intraline pass is CJK-aware);
    /// attributed-string ranges are UTF-16. Bail rather than misplace the span.
    private static func utf16Range(of emphasis: Range<Int>, in text: String) -> NSRange? {
        guard let lower = text.index(text.startIndex, offsetBy: emphasis.lowerBound,
                                     limitedBy: text.endIndex),
              let upper = text.index(text.startIndex, offsetBy: emphasis.upperBound,
                                     limitedBy: text.endIndex),
              lower < upper else { return nil }
        return NSRange(lower..<upper, in: text)
    }

    // MARK: Display fold

    private enum DisplayItem {
        case line(DiffRow)
        case band(id: Int, label: String, controls: Line.BandControls)

        var textLength: Int {
            switch self {
            case .line(let row): return (row.text as NSString).length
            case .band(_, let label, _): return (label as NSString).length
            }
        }
    }

    /// A band says *where* the skipped lines are, not how many there are. github.com's
    /// expander row carries the `@@` header and its section heading for the same reason:
    /// a line range tells the reader what they are jumping over, while "137 unchanged
    /// lines" only describes the widget they are looking at.
    private static func bandLabel(first: Int?, last: Int?, heading: String? = nil) -> String {
        var label = ""
        if let first, let last {
            label = first == last ? "\(first)" : "\(first)–\(last)"
        }
        if let heading, !heading.isEmpty {
            label += label.isEmpty ? heading : "   \(heading)"
        }
        return label
    }

    /// The section heading git appends to a hunk header (`@@ -a,b +c,d @@ func foo() {`) —
    /// the enclosing scope of the lines that follow.
    static func hunkHeading(_ text: String) -> String? {
        let parts = text.components(separatedBy: "@@")
        guard parts.count >= 3 else { return nil }
        let heading = parts[2...].joined(separator: "@@")
            .trimmingCharacters(in: .whitespaces)
        return heading.isEmpty ? nil : heading
    }

    private static func displayItems(rows: [DiffRow], expansion: DiffExpansion) -> [DisplayItem] {
        var items: [DisplayItem] = []
        var run: [DiffRow] = []
        var sawChange = false
        var lastNewLine = 0

        func flush(isLast: Bool) {
            defer { run = [] }
            guard !run.isEmpty else { return }
            let head = sawChange ? 3 : 0
            let tail = isLast ? 0 : 3
            let hidden = run.count - head - tail
            guard hidden >= 10 else {
                items += run.map(DisplayItem.line)
                return
            }
            items += run.prefix(head).map(DisplayItem.line)
            let hiddenRows = Array(run.dropFirst(head).dropLast(tail))
            let anchor = hiddenRows[0].id
            let revealed = expansion.revealed(anchor, of: hiddenRows.count)
            items += hiddenRows.prefix(revealed.head).map(DisplayItem.line)
            let stillHidden = hiddenRows.dropFirst(revealed.head).dropLast(revealed.tail)
            if !stillHidden.isEmpty {
                // A button only points somewhere there is code to continue from.
                var controls: Line.BandControls = []
                if head > 0 || revealed.head > 0 || !items.isEmpty { controls.insert(.down) }
                if tail > 0 || revealed.tail > 0 || !isLast { controls.insert(.up) }
                let label = bandLabel(first: stillHidden.first?.newLine ?? stillHidden.first?.oldLine,
                                      last: stillHidden.last?.newLine ?? stillHidden.last?.oldLine)
                items.append(.band(id: anchor, label: label, controls: controls))
            }
            items += hiddenRows.suffix(revealed.tail).map(DisplayItem.line)
            items += run.suffix(tail).map(DisplayItem.line)
        }

        for row in rows {
            switch row.kind {
            case .hunk:
                flush(isLast: false)
                if let start = row.newLine, start > lastNewLine + 1 {
                    // The hidden lines were never fetched, so this band cannot be revealed
                    // — but git's own section heading still says what is being skipped.
                    let label = bandLabel(first: lastNewLine + 1, last: start - 1,
                                          heading: hunkHeading(row.text))
                    items.append(.band(id: row.id, label: label, controls: []))
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
}
