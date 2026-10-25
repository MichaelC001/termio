import XCTest
@testable import termio

/// `termio sim logs` and `crash-report` hand an agent what an app said and how it
/// died. Both read files other software writes — `log show`'s ndjson and macOS's
/// `.ips` reports — so the shapes are pinned here, with the two filters that
/// matter: a cursor that never repeats a line, and a report from another
/// simulator never passed off as this one's.
final class SimulatorDiagnosticsTests: XCTestCase {
    private func entry(_ timestamp: String, _ level: String, _ message: String) -> String {
        let object: [String: Any] = [
            "eventType": "logEvent", "timestamp": timestamp, "messageType": level,
            "subsystem": "sh.termio.mobile", "category": "net", "eventMessage": message,
        ]
        let data = try? JSONSerialization.data(withJSONObject: object)
        return String(data: data ?? Data(), encoding: .utf8) ?? ""
    }

    func testLinesAfterTheCursorAtTheLevelAndAboveComeBackOldestFirst() {
        let log = [
            entry("2026-10-24 19:00:00.000001-0700", "Default", "launched"),
            entry("2026-10-24 19:00:01.000001-0700", "Debug", "noise"),
            entry("2026-10-24 19:00:02.000001-0700", "Error", "request failed"),
            "{\"count\":3,\"finished\":1}",
        ].joined(separator: "\n")
        let read = SimulatorDiagnostics.parseLog(
            log, since: "2026-10-24 19:00:00.000001-0700", tail: 100, minimumLevel: "info", filter: nil)
        XCTAssertEqual(read.lines, ["19:00:02.000 error [sh.termio.mobile:net] request failed"])
        XCTAssertEqual(read.cursor, "2026-10-24 19:00:02.000001-0700")
        XCTAssertFalse(read.truncated)
    }

    func testTailKeepsTheNewestAndSaysSomethingWasLeftOut() {
        let log = (0 ..< 5).map { entry("2026-10-24 19:00:0\($0).000000-0700", "Default", "line \($0)") }
            .joined(separator: "\n")
        let read = SimulatorDiagnostics.parseLog(log, since: nil, tail: 2, minimumLevel: "info", filter: "line")
        XCTAssertEqual(read.lines.map { $0.hasSuffix("line 3") || $0.hasSuffix("line 4") }, [true, true])
        XCTAssertTrue(read.truncated)
    }

    private func report(procPath: String) -> String {
        let header = #"{"app_name":"TermioMobile","timestamp":"2026-10-24 19:30:00.00 -0700","bug_type":"309"}"#
        let body: [String: Any] = [
            "procPath": procPath,
            "exception": ["type": "EXC_BREAKPOINT", "signal": "SIGTRAP"],
            "termination": ["indicator": "Trace/BPT trap: 5"],
            "faultingThread": 0,
            "usedImages": [["name": "TermioMobile"]],
            "threads": [["frames": [["imageIndex": 0, "symbol": "ContentView.body.getter", "sourceFile": "ContentView.swift", "sourceLine": 42]]]],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        return header + "\n" + (String(data: data, encoding: .utf8) ?? "")
    }

    func testACrashOnThisDeviceIsSummarisedWithItsCrashedFrames() {
        let path = "/Users/me/Library/Developer/CoreSimulator/Devices/C5B302BE/data/Containers/Bundle/Application/X/TermioMobile.app/TermioMobile"
        let summary = SimulatorDiagnostics.summarize(ips: report(procPath: path), udid: "C5B302BE")
        XCTAssertEqual(summary, """
            TermioMobile crashed at 2026-10-24 19:30:00.00 -0700
            exception: EXC_BREAKPOINT (SIGTRAP)
            reason: Trace/BPT trap: 5
            crashed thread 0:
              0 TermioMobile ContentView.body.getter (ContentView.swift:42)
            """)
    }

    func testACrashFromAnotherSimulatorIsNotThisOnes() {
        let path = "/Users/me/Library/Developer/CoreSimulator/Devices/OTHER/data/TermioMobile.app/TermioMobile"
        XCTAssertNil(SimulatorDiagnostics.summarize(ips: report(procPath: path), udid: "C5B302BE"))
    }
}
