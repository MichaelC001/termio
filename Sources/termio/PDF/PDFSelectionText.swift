import Foundation

/// Turns PDF-extracted text back into prose.
///
/// A PDF has no paragraphs — only typeset lines — so `PDFSelection.string` comes back with
/// a hard break at every line ending and words split across a hyphen at the margin. Pasted
/// into an agent's prompt that reads as forty ragged fragments, which is what makes quoting
/// a paper into a terminal miserable. This rejoins the lines the typesetter broke and leaves
/// alone the ones the author wrote.
enum PDFSelectionText {
    /// The selection as prose: wrapped lines rejoined, hyphenated words healed, blank lines
    /// kept as paragraph breaks, and list items kept on their own lines.
    static func unwrapped(_ raw: String) -> String {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        // Each block is a paragraph or a list item; list items stay on adjacent lines
        // while paragraphs are separated by a blank one.
        var blocks: [(text: String, item: Bool)] = []
        var current = ""
        var currentIsItem = false

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { blocks.append((trimmed, currentIsItem)) }
            current = ""
            currentIsItem = false
        }

        for rawLine in normalized.components(separatedBy: "\n") {
            let line = collapseSpaces(rawLine.trimmingCharacters(in: .whitespaces))
            if line.isEmpty {
                flush()
                continue
            }
            if current.isEmpty {
                current = line
                currentIsItem = startsListItem(line)
                continue
            }
            // A line the author started — a bullet, a numbered item — is not a wrap.
            if startsListItem(line) {
                flush()
                current = line
                currentIsItem = true
                continue
            }
            if let healed = dehyphenating(current, joining: line) {
                current = healed
            } else {
                current += " " + line
            }
        }
        flush()
        return blocks.enumerated().reduce(into: "") { text, entry in
            let (index, block) = entry
            if index > 0 {
                text += block.item && blocks[index - 1].item ? "\n" : "\n\n"
            }
            text += block.text
        }
    }

    /// A word broken at the margin (`inter-` + `pretation`) is rejoined without the hyphen.
    /// A line ending in a hyphen followed by a capital or a digit is left alone: that is a
    /// real hyphen the author typed (`Anti-` `Bayesian`, `COVID-` `19`), not a break.
    private static func dehyphenating(_ current: String, joining next: String) -> String? {
        guard current.hasSuffix("-") || current.hasSuffix("\u{2010}") else { return nil }
        guard let first = next.first, first.isLowercase else { return nil }
        // A double hyphen (`--`) is punctuation, not a break.
        let body = String(current.dropLast())
        guard !body.hasSuffix("-") else { return nil }
        return body + next
    }

    private static func startsListItem(_ line: String) -> Bool {
        if let first = line.first, "•‣◦-*–—".contains(first) {
            // "- item" is a bullet; "-3.4 dB" is a number that happens to lead with a dash.
            return line.dropFirst().first == " "
        }
        // "1. ", "2) ", "iv. " — an enumerated item.
        let head = line.prefix(while: { $0.isNumber })
        guard !head.isEmpty, head.count <= 3 else { return false }
        let rest = line.dropFirst(head.count)
        guard let marker = rest.first, marker == "." || marker == ")" else { return false }
        return rest.dropFirst().first == " "
    }

    /// A passage reduced to the characters that survive re-typesetting: no case, no
    /// whitespace, no hyphens. Comparing two quotes this way is what lets a mark recognise
    /// its own words after the page they sit on has been re-laid out — where the same
    /// sentence comes back with different line breaks and a hyphen in a different place.
    static func squashed(_ text: String) -> String {
        text.lowercased().unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
                && $0 != "-" && $0 != "\u{2010}" && $0 != "\u{00AD}"
        }.map(String.init).joined()
    }

    /// Where a passage sits inside a page's text, ignoring how either one is laid out.
    ///
    /// `findString` is no use for this: PDF text carries a newline at every typeset line and
    /// a hyphen at every broken word, and a search matches neither across. So both sides are
    /// squashed to their surviving characters, the match is made there, and the answer is
    /// mapped back to a range in the original text — which is what `PDFPage` needs to hand
    /// back a selection.
    static func locate(_ quote: String, in text: String) -> NSRange? {
        let squashedQuote = squashed(quote)
        guard !squashedQuote.isEmpty else { return nil }
        let source = text as NSString
        var flattened = ""
        var offsets: [Int] = []
        flattened.reserveCapacity(source.length)
        offsets.reserveCapacity(source.length)
        for index in 0..<source.length {
            let character = source.substring(with: NSRange(location: index, length: 1))
            let kept = squashed(character)
            guard !kept.isEmpty else { continue }
            flattened += kept
            offsets.append(index)
        }
        guard let found = flattened.range(of: squashedQuote) else { return nil }
        let start = flattened.distance(from: flattened.startIndex, to: found.lowerBound)
        let end = flattened.distance(from: flattened.startIndex, to: found.upperBound)
        guard start < offsets.count, end > 0, end <= offsets.count else { return nil }
        let first = offsets[start]
        let last = offsets[end - 1]
        return NSRange(location: first, length: last - first + 1)
    }

    private static func collapseSpaces(_ line: String) -> String {
        line.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }
}
