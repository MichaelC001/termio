import TermioShared
import XCTest
@testable import termio

/// A terminal's reply to a host query shares the write path with keystrokes,
/// and misclassifying either way is visible: a report treated as typing claims
/// the write token and drags the PTY to the observer's grid, a keystroke
/// treated as a report is silently dropped.
final class TerminalDeviceReportTests: XCTestCase {
    private func bytes(_ text: String) -> Data { Data(text.utf8) }

    func testRepliesLibghosttyGeneratesAreReports() {
        // Device attributes, status, cursor position.
        XCTAssertTrue(TerminalDeviceReport.isReport(bytes("\u{1B}[?62;22c")))
        XCTAssertTrue(TerminalDeviceReport.isReport(bytes("\u{1B}[?62;22;52c")))
        XCTAssertTrue(TerminalDeviceReport.isReport(bytes("\u{1B}[>1;10;0c")))
        XCTAssertTrue(TerminalDeviceReport.isReport(bytes("\u{1B}[0n")))
        XCTAssertTrue(TerminalDeviceReport.isReport(bytes("\u{1B}[24;80R")))
        XCTAssertTrue(TerminalDeviceReport.isReport(bytes("\u{1B}[1;1R")))
        XCTAssertTrue(TerminalDeviceReport.isReport(bytes("\u{1B}[1;40R")))
        // DECRQM mode reports, private and ANSI.
        XCTAssertTrue(TerminalDeviceReport.isReport(bytes("\u{1B}[?2026;2$y")))
        XCTAssertTrue(TerminalDeviceReport.isReport(bytes("\u{1B}[4;1$y")))
        // XTWINOPS size reports, kitty keyboard flags, XTQMODKEYS.
        XCTAssertTrue(TerminalDeviceReport.isReport(bytes("\u{1B}[8;24;80t")))
        XCTAssertTrue(TerminalDeviceReport.isReport(bytes("\u{1B}[?1u")))
        XCTAssertTrue(TerminalDeviceReport.isReport(bytes("\u{1B}[>4;2m")))
        // DCS: XTVERSION, DECRQSS, XTGETTCAP.
        XCTAssertTrue(TerminalDeviceReport.isReport(bytes("\u{1B}P>|ghostty 1.3.2\u{1B}\\")))
        XCTAssertTrue(TerminalDeviceReport.isReport(bytes("\u{1B}P1$r0 q\u{1B}\\")))
        XCTAssertTrue(TerminalDeviceReport.isReport(bytes("\u{1B}P1+r544e=787465726d\u{1B}\\")))
        // OSC: colours, kitty colours, clipboard.
        XCTAssertTrue(TerminalDeviceReport.isReport(bytes("\u{1B}]4;1;rgb:1e1e/1e1e/2e2e\u{1B}\\")))
        XCTAssertTrue(TerminalDeviceReport.isReport(bytes("\u{1B}]11;rgb:1e1e/1e1e/2e2e\u{1B}\\")))
        XCTAssertTrue(TerminalDeviceReport.isReport(bytes("\u{1B}]21;foreground=rgb:ff/ff/ff\u{1B}\\")))
        XCTAssertTrue(TerminalDeviceReport.isReport(bytes("\u{1B}]52;c;aGVsbG8=\u{1B}\\")))
    }

    func testKeystrokesAreNotReports() {
        XCTAssertFalse(TerminalDeviceReport.isReport(bytes("ls -la\r")))
        XCTAssertFalse(TerminalDeviceReport.isReport(bytes("\u{1B}")))
        XCTAssertFalse(TerminalDeviceReport.isReport(bytes("\u{1B}[A")))
        XCTAssertFalse(TerminalDeviceReport.isReport(bytes("\u{1B}[1;5C")))
        XCTAssertFalse(TerminalDeviceReport.isReport(bytes("\u{1B}[3~")))
        XCTAssertFalse(TerminalDeviceReport.isReport(bytes("\u{1B}OR")))
        // Modified F3 in the legacy encoding shares its shape with a cursor
        // report for row 1; the modifier range decides it.
        XCTAssertFalse(TerminalDeviceReport.isReport(bytes("\u{1B}[1;5R")))
        XCTAssertFalse(TerminalDeviceReport.isReport(bytes("\u{1B}[1;2R")))
        XCTAssertFalse(TerminalDeviceReport.isReport(bytes("\u{1B}[13~")))
        // A key press under the kitty keyboard protocol ends in `u` too, but
        // without the `?` a flags report carries.
        XCTAssertFalse(TerminalDeviceReport.isReport(bytes("\u{1B}[97;5u")))
        // SGR mouse press and release carry `<`, never the `>` of XTQMODKEYS.
        XCTAssertFalse(TerminalDeviceReport.isReport(bytes("\u{1B}[<0;10;20M")))
        XCTAssertFalse(TerminalDeviceReport.isReport(bytes("\u{1B}[<0;10;20m")))
        // Bracketed paste, even when the pasted text starts with an escape.
        XCTAssertFalse(TerminalDeviceReport.isReport(bytes("\u{1B}[200~pasted\u{1B}[201~")))
        XCTAssertFalse(TerminalDeviceReport.isReport(bytes("\u{1B}[200~\u{1B}]11;?\u{1B}\\\u{1B}[201~")))
        // A title OSC or an unlisted DCS is not a reply libghostty emits, and
        // neither is a reply-looking prefix without its introducer.
        XCTAssertFalse(TerminalDeviceReport.isReport(bytes("\u{1B}]0;title\u{1B}\\")))
        XCTAssertFalse(TerminalDeviceReport.isReport(bytes("\u{1B}Pq#0;2;0;0;0\u{1B}\\")))
        XCTAssertFalse(TerminalDeviceReport.isReport(bytes("\u{1B}P>q")))
        XCTAssertFalse(TerminalDeviceReport.isReport(bytes("\u{1B}P$r")))
        XCTAssertFalse(TerminalDeviceReport.isReport(bytes("\u{1B}]4x")))
        XCTAssertFalse(TerminalDeviceReport.isReport(bytes("\u{1B}]11")))
        XCTAssertFalse(TerminalDeviceReport.isReport(bytes("\u{1B}]")))
        XCTAssertFalse(TerminalDeviceReport.isReport(Data()))
    }

    func testGridControlRoundTrips() {
        let message = CompanionControl.grid(cols: 45, rows: 38, writer: false)
        XCTAssertEqual(CompanionControl.decode(message.encoded()), message)
    }
}
