import AppKit

/// The one incremental-find engine behind both ⌘F surfaces — the code editor
/// (`HighlightedTextView`) and the diff overlay (`DiffTextView`). It finds every match of a
/// query (literal or regex, with case / whole-word modifiers), paints them as temporary
/// background highlights over any `NSTextView`, and reveals the focused one. Sharing one engine
/// is what keeps find behaving — and the highlights looking — identical in both places, so the
/// two `FileFindBar`s aren't just visually alike but back onto the same search.
@MainActor
final class TextFindEngine {
    private(set) var matches: [NSRange] = []

    private static let matchColor = NSColor.systemYellow.withAlphaComponent(0.35)
    private static let focusedColor = NSColor.systemYellow.withAlphaComponent(0.7)

    /// What counts as "inside a word" for whole-word find. Shared with `OccurrenceTarget` so the
    /// word the occurrence wash picks up and the boundary this engine matches on can't disagree.
    nonisolated static let wordCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))

    /// Rebuild the match list for `query` over the text view's current string. Returns the count.
    @discardableResult
    func recompute(query: String, options: FindOptions, in textView: NSTextView) -> Int {
        matches.removeAll()
        guard !query.isEmpty else { return 0 }
        let full = textView.string as NSString
        let total = full.length
        guard total > 0 else { return 0 }

        if options.regex {
            var regexOptions: NSRegularExpression.Options = []
            if !options.caseSensitive { regexOptions.insert(.caseInsensitive) }
            guard let regex = try? NSRegularExpression(pattern: query, options: regexOptions) else { return 0 }
            for match in regex.matches(in: textView.string, range: NSRange(location: 0, length: total))
            where match.range.length > 0 {
                if options.wholeWord, !Self.isWordBoundary(match.range, in: full) { continue }
                matches.append(match.range)
            }
            return matches.count
        }

        var searchOptions: NSString.CompareOptions = []
        if !options.caseSensitive { searchOptions.insert(.caseInsensitive) }
        var searchStart = 0
        while searchStart < total {
            let searchRange = NSRange(location: searchStart, length: total - searchStart)
            let hit = full.range(of: query, options: searchOptions, range: searchRange)
            if hit.location == NSNotFound { break }
            if !options.wholeWord || Self.isWordBoundary(hit, in: full) { matches.append(hit) }
            // `hit.length` can be zero for a pathological pattern; step by 1 to guarantee termination.
            searchStart = hit.location + max(hit.length, 1)
        }
        return matches.count
    }

    /// Repaint every match, tinting `focused` brighter. `reveal` scrolls the focused match into
    /// view and pulses the find indicator — pass true only when the focus genuinely moved (a new
    /// query or a next/prev step), never on a passive repaint after an in-document edit.
    func paint(focused: Int, reveal: Bool, in textView: NSTextView) {
        guard let layoutManager = textView.layoutManager else { return }
        clearHighlights(in: textView)
        for (index, range) in matches.enumerated() {
            layoutManager.addTemporaryAttribute(
                .backgroundColor, value: index == focused ? Self.focusedColor : Self.matchColor,
                forCharacterRange: range)
        }
        if reveal, matches.indices.contains(focused) {
            let range = matches[focused]
            textView.scrollRangeToVisible(range)
            textView.showFindIndicator(for: range)
        }
    }

    /// Wash `ranges` in `color` without disturbing anything else already painted — the additive
    /// counterpart to `paint(focused:reveal:)`, which owns the whole document. The occurrence
    /// highlight goes through here so it shares the layer with the bracket wash instead of wiping
    /// it, and `removeHighlight` lifts exactly what this laid down.
    static func addHighlight(_ ranges: [NSRange], color: NSColor, in textView: NSTextView) {
        guard let layoutManager = textView.layoutManager else { return }
        let length = (textView.string as NSString).length
        for range in ranges {
            guard let clamped = clamp(range, to: length) else { continue }
            layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: clamped)
        }
    }

    static func removeHighlight(_ ranges: [NSRange], in textView: NSTextView) {
        guard let layoutManager = textView.layoutManager else { return }
        let length = (textView.string as NSString).length
        for range in ranges {
            guard let clamped = clamp(range, to: length) else { continue }
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: clamped)
        }
    }

    /// `range` cut down to fit a text of `length`, or `nil` when it starts past the end — an edit
    /// can shrink the document between painting and lifting, and touching an attribute past the
    /// end raises.
    private static func clamp(_ range: NSRange, to length: Int) -> NSRange? {
        guard range.location < length else { return nil }
        return NSRange(location: range.location, length: min(range.length, length - range.location))
    }

    private func clearHighlights(in textView: NSTextView) {
        guard let layoutManager = textView.layoutManager else { return }
        let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)
    }

    private static func isWordBoundary(_ range: NSRange, in string: NSString) -> Bool {
        let letters = wordCharacters
        if range.location > 0 {
            let prev = string.character(at: range.location - 1)
            if let scalar = Unicode.Scalar(prev), letters.contains(scalar) { return false }
        }
        let end = range.location + range.length
        if end < string.length {
            let next = string.character(at: end)
            if let scalar = Unicode.Scalar(next), letters.contains(scalar) { return false }
        }
        return true
    }
}
