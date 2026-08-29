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
        XCTAssertTrue(TerminalDeviceReport.isReport(bytes("\u{1B}P>|ghostty 1.3.2\u{1B}\\")))
        XCTAssertTrue(TerminalDeviceReport.isReport(bytes("\u{1B}]11;rgb:1e1e/1e1e/2e2e\u{1B}\\")))
        XCTAssertTrue(TerminalDeviceReport.isReport(bytes("\u{1B}[?62;22c")))
        XCTAssertTrue(TerminalDeviceReport.isReport(bytes("\u{1B}[>1;10;0c")))
        XCTAssertTrue(TerminalDeviceReport.isReport(bytes("\u{1B}[24;80R")))
    }

    func testKeystrokesAreNotReports() {
        XCTAssertFalse(TerminalDeviceReport.isReport(bytes("ls -la\r")))
        XCTAssertFalse(TerminalDeviceReport.isReport(bytes("\u{1B}")))
        XCTAssertFalse(TerminalDeviceReport.isReport(bytes("\u{1B}[A")))
        XCTAssertFalse(TerminalDeviceReport.isReport(bytes("\u{1B}[1;5C")))
        XCTAssertFalse(TerminalDeviceReport.isReport(bytes("\u{1B}[3~")))
        XCTAssertFalse(TerminalDeviceReport.isReport(bytes("\u{1B}[200~pasted\u{1B}[201~")))
        XCTAssertFalse(TerminalDeviceReport.isReport(Data()))
    }

    func testGridControlRoundTrips() {
        let message = CompanionControl.grid(cols: 45, rows: 38, writer: false)
        XCTAssertEqual(CompanionControl.decode(message.encoded()), message)
    }
}
