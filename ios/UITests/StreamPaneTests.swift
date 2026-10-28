import XCTest

/// A capture harness for the stream pane on the phone (phase 6 of
/// `docs/design/20261024-client-vt-follows-the-stream.md`), in the
/// WidthRegressionTests mold: pairs with the termiod whose invite is in
/// `/tmp/p6/invite` (or `DEVICE_INVITE`), opens a session with the stream
/// pane on, and attaches screenshots. Skips itself without an invite, so CI
/// never runs it.
final class StreamPaneTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func invite() throws -> String {
        let file = (try? String(contentsOfFile: "/tmp/p6/invite", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let invite = ProcessInfo.processInfo.environment["DEVICE_INVITE"] ?? file, !invite.isEmpty else {
            throw XCTSkip("DEVICE_INVITE not set — stream pane capture is manual-only")
        }
        return invite
    }

    private func shoot(_ name: String, settle: TimeInterval = 2.0) {
        Thread.sleep(forTimeInterval: settle)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testStreamPane() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-pair-device", try invite(), "-TermioStreamTerminal", "YES"]
        app.launch()
        shoot("launched", settle: 5)
        // A session in no project is listed under Terminals.
        app.buttons["home.tab.terminals"].tap()
        shoot("terminals", settle: 3)
        let session = app.staticTexts["bash"].firstMatch
        if session.waitForExistence(timeout: 10) {
            session.tap()
            shoot("session", settle: 4)
            // A view that takes keys reads as a text view.
            let stream = app.textViews["terminal.stream"]
            XCTAssertTrue(stream.waitForExistence(timeout: 5), "the stream view is not up")
            stream.typeText("echo streamed from the phone\n")
            shoot("typed", settle: 2)
        } else {
            let attachment = XCTAttachment(string: app.debugDescription)
            attachment.name = "hierarchy"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    /// A dropped link resumes the stream (`vt_resume`): whatever runs between
    /// this test and the device cuts the connection when `/tmp/p6/cut` appears,
    /// and the output typed before it is still on the screen after.
    func testStreamResume() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-pair-device", try invite(), "-TermioStreamTerminal", "YES"]
        app.launch()
        app.buttons["home.tab.terminals"].tap()
        let session = app.cells.firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 15), "no terminal session")
        session.tap()
        let stream = app.textViews["terminal.stream"]
        XCTAssertTrue(stream.waitForExistence(timeout: 10), "the stream view is not up")
        stream.typeText("clear; echo before the cut\n")
        shoot("before", settle: 2)
        FileManager.default.createFile(atPath: "/tmp/p6/cut", contents: Data())
        Thread.sleep(forTimeInterval: 8)
        stream.typeText("echo after the cut\n")
        shoot("after", settle: 3)
    }
}
