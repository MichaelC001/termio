import Foundation

/// Tells a terminal's *device report* apart from the person's keystrokes.
///
/// Every attachment to a session runs its own libghostty, and libghostty
/// answers a host query (XTVERSION, DA, DSR, a colour or clipboard query) on
/// its own, through the same write path keystrokes take. With one PTY and
/// several attachments that is one query and several answers — and the
/// answers are indistinguishable from typing to everything downstream. Two
/// things go wrong: the late duplicates miss the agent's parse window and
/// land in its input line as literal text (a stray `>|ghostty 1.3.2…`), and
/// on a client that claims the write token by writing, an observer's reply
/// *claims the token* and drags the PTY back to its own grid. So the rule on
/// both ends is: a report passes only from the writer, and never claims.
///
/// libghostty emits each reply as one standalone escape sequence:
///   • ESC P … (DCS) — XTVERSION `>|ghostty …`, DECRQSS, XTGETTCAP
///   • ESC ] … (OSC) — colour / clipboard query answers
///   • ESC [ … c     — Device Attributes (primary / secondary)
///   • ESC [ … R     — Cursor Position Report
///
/// Genuine input never matches: arrows / home / end terminate a CSI in A–H
/// or `~`, a bare Esc is a lone byte, pasted or typed text carries no ESC
/// lead-in, and bracketed paste opens with `ESC [ 200 ~`.
public enum TerminalDeviceReport {
    public static func isReport(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.first == 0x1B, bytes.count >= 2 else { return false }
        switch bytes[1] {
        case 0x50, 0x5D: // ESC P (DCS) / ESC ] (OSC)
            return true
        case 0x5B: // ESC [ (CSI): a report only when the final byte is 'c' or 'R'
            var index = 2
            while index < bytes.count {
                let byte = bytes[index]
                if byte >= 0x40, byte <= 0x7E { return byte == 0x63 || byte == 0x52 }
                index += 1
            }
            return false
        default:
            return false
        }
    }
}
