import Foundation
import LanguageServerProtocol

/// Conversions between the editor's `NSTextView` offsets and LSP positions. `NSString` offsets
/// *are* UTF-16 code units — exactly the unit LSP's `Position.character` counts — so the mapping
/// is pure newline bookkeeping, no transcoding.
enum LSPPositions {
    /// Text-view character offset → LSP position. A linear scan is fine: requests are
    /// user-initiated (a click, a keystroke) on editor-sized buffers. In a `\r\n` pair only the
    /// `\n` advances the line, matching how LSP counts.
    static func position(utf16Offset: Int, in text: NSString) -> Position {
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
        return Position(line: line, character: offset - lineStart)
    }
}
