import Foundation

/// The editor's one line/offset vocabulary. `NSString` offsets *are* UTF-16 code units — the
/// unit `NSTextView` selections use — so every conversion here is pure newline bookkeeping, no
/// transcoding. Linear scans are fine: callers are user-initiated (a caret move, a search-hit
/// reveal) on editor-sized buffers, and the scan allocates nothing (unlike the
/// `substring`/`components` split it replaced in the footer path).
enum TextPositions {
    /// Text-view character offset → 0-based (line, UTF-16 character). In a `\r\n` pair only the
    /// `\n` advances the line.
    static func position(utf16Offset: Int, in text: NSString) -> (line: Int, character: Int) {
        let offset = min(max(utf16Offset, 0), text.length)
        var line = 0
        var lineStart = 0
        var index = 0
        while index < offset {
            if text.character(at: index) == 0x0A {
                line += 1
                lineStart = index + 1
            }
            index += 1
        }
        return (line, offset - lineStart)
    }

    /// The same scan in the footer's 1-based dialect (`Ln 12, Col 4`).
    static func lineColumn(utf16Offset: Int, in text: NSString) -> (line: Int, column: Int) {
        let position = position(utf16Offset: utf16Offset, in: text)
        return (position.line + 1, position.character + 1)
    }

    /// 1-based line number → the offset of that line's first character, clamped to the last
    /// line when the number runs past the end (the reveal-a-search-hit contract).
    static func offset(ofLine line: Int, in text: NSString) -> Int {
        var location = 0
        var current = 1
        while current < line, location < text.length {
            location = NSMaxRange(text.lineRange(for: NSRange(location: location, length: 0)))
            current += 1
        }
        return min(location, max(text.length - 1, 0))
    }
}
