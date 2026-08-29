import Foundation

/// Tells a terminal's *device report* apart from the person's keystrokes.
///
/// Every attachment to a session runs its own libghostty, and libghostty
/// answers a host query (XTVERSION, DA, DSR, DECRQM, a colour or clipboard
/// query) on its own, through the same write path keystrokes take. With one
/// PTY and several attachments that is one query and several answers — and
/// the answers are indistinguishable from typing to everything downstream.
/// Two things go wrong: the late duplicates miss the agent's parse window and
/// land in its input line as literal text (a stray `>|ghostty 1.3.2…`), and
/// on a client that claims the write token by writing, an observer's reply
/// *claims the token* and drags the PTY back to its own grid. So the rule on
/// both ends is: a report passes only from the writer, and never claims.
///
/// libghostty has no hook that marks a write as generated, so this is a
/// grammar of exactly the replies it emits (`termio/stream_handler.zig`,
/// `terminal/modes.zig`, `terminal/formatter.zig`), each as one standalone
/// write:
///
///   • `ESC [ … c`        Device Attributes, primary (`?62;22c`) and secondary (`>1;10;0c`)
///   • `ESC [ … n`        DSR operating status (`0n`)
///   • `ESC [ … R`        Cursor Position Report
///   • `ESC [ … $ y`      DECRQM mode report, with or without `?`
///   • `ESC [ … t`        XTWINOPS size and title reports
///   • `ESC [ ? … u`      kitty keyboard protocol flags — only with `?`: a key
///                        press under that protocol is `ESC [ code ; mods u`
///   • `ESC [ > … m`      XTQMODKEYS report — only with `>`: SGR mouse input is
///                        `ESC [ < … M` / `m`
///   • `ESC P > | …`      XTVERSION;  `ESC P n $ r …` DECRQSS;  `ESC P n + r …` XTGETTCAP
///   • `ESC ] 4 ; …`, `ESC ] 10–19 ; …`, `ESC ] 21 …`, `ESC ] 52 ; …`
///                        colour, kitty colour, and clipboard query answers
///
/// Everything else is input: arrows and function keys end a CSI in A–Z, `~`
/// or `u` without `?`; mouse reports carry `<`; a bare Esc is a lone byte;
/// typed text has no ESC lead-in; a paste arrives inside `ESC [ 200 ~`.
///
/// One collision is xterm's, not ours: a modified F3 in the legacy encoding
/// is `ESC [ 1 ; mod R`, the same shape as a cursor report for row 1. A
/// report's second parameter is a column, a key's is a modifier in 2…16, and
/// a cursor sitting in the first sixteen columns of row 1 is answered just
/// after a clear — so that shape is read as the key. Under the kitty keyboard
/// protocol, which every agent TUI enables, F3 is `ESC [ 13 ~` and the
/// collision does not arise.
public enum TerminalDeviceReport {
    public static func isReport(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count >= 3, bytes[0] == 0x1B else { return false }
        switch bytes[1] {
        case 0x5B: // ESC [
            return isControlSequenceReport(bytes)
        case 0x50: // ESC P
            return isDeviceControlReport(bytes)
        case 0x5D: // ESC ]
            return isOperatingSystemCommandReport(bytes)
        default:
            return false
        }
    }

    private static func isControlSequenceReport(_ bytes: [UInt8]) -> Bool {
        let marker = bytes[2]
        var index = 2
        while index < bytes.count {
            let byte = bytes[index]
            // The final byte of a CSI is the first in 0x40–0x7E.
            if byte >= 0x40, byte <= 0x7E {
                switch byte {
                case 0x63, 0x6E, 0x79, 0x74: // c n y t
                    return true
                case 0x52: // R
                    return !isLegacyModifiedFunctionKey(bytes[2..<index])
                case 0x75: // u
                    return marker == 0x3F // ?
                case 0x6D: // m
                    return marker == 0x3E // >
                default:
                    return false
                }
            }
            index += 1
        }
        return false
    }

    /// `1 ; 2…16` — the parameters of a modified F1–F4 in the legacy encoding.
    private static func isLegacyModifiedFunctionKey(_ parameters: ArraySlice<UInt8>) -> Bool {
        let fields = parameters.split(separator: 0x3B, omittingEmptySubsequences: false)
        guard fields.count == 2, fields[0] == [0x31],
              let modifier = Int(String(decoding: fields[1], as: UTF8.self))
        else { return false }
        return (2...16).contains(modifier)
    }

    private static func isDeviceControlReport(_ bytes: [UInt8]) -> Bool {
        // XTVERSION: `ESC P > |`.
        if bytes[2] == 0x3E { return bytes.count > 3 && bytes[3] == 0x7C }
        // DECRQSS `ESC P n $ r` and XTGETTCAP `ESC P n + r`, n a status digit.
        var index = 2
        while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 { index += 1 }
        guard index > 2, index + 1 < bytes.count else { return false }
        return (bytes[index] == 0x24 || bytes[index] == 0x2B) && bytes[index + 1] == 0x72
    }

    private static func isOperatingSystemCommandReport(_ bytes: [UInt8]) -> Bool {
        var number = 0
        var index = 2
        while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
            number = number * 10 + Int(bytes[index] - 0x30)
            index += 1
            if number > 999 { return false }
        }
        // The number, then the `;` every reply puts before its payload.
        guard index > 2, index < bytes.count, bytes[index] == 0x3B else { return false }
        switch number {
        case 4, 5, 10...19, 21, 52:
            return true
        default:
            return false
        }
    }
}
