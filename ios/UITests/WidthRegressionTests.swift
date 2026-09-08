import XCTest

/// Not a test of behavior — a capture harness for the width/rendering
/// investigation, in the MarketingScreensTests mold: drives the app against
/// the REAL Mac companion roster (`/tmp/marketing-roster-url`, or the
/// `ROSTER_URL` runner environment variable) and attaches named screenshots
/// of the states under suspicion; `xcresulttool export attachments` pulls
/// them out. Skips itself when no roster URL is provided, so CI never runs
/// it. Read-only by design: it opens sessions, scrolls, and toggles the
/// keyboard — it never types into an agent.
final class WidthRegressionTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func rosterURL() throws -> String {
        let fileURL = (try? String(contentsOfFile: "/tmp/marketing-roster-url", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = ProcessInfo.processInfo.environment["ROSTER_URL"] ?? fileURL,
              !url.isEmpty
        else {
            throw XCTSkip("ROSTER_URL not set — width capture is manual-only")
        }
        return url
    }

    private func shoot(_ name: String, settle: TimeInterval = 2.0) {
        Thread.sleep(forTimeInterval: settle)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func open(_ app: XCUIApplication, project: String, row: String) {
        let projectRow = app.staticTexts[project].firstMatch
        XCTAssertTrue(projectRow.waitForExistence(timeout: 10), "no project \(project)")
        projectRow.tap()
        let sessionRow = app.staticTexts[row].firstMatch
        XCTAssertTrue(sessionRow.waitForExistence(timeout: 8), "no session row \(row)")
        sessionRow.tap()
        XCTAssertTrue(app.buttons["terminal.back"].waitForExistence(timeout: 8))
    }

    /// The static states: a long-lived agent session opening with the
    /// keyboard up (the covered-input report), keyboard away, and a fresh
    /// terminal as the native-width baseline.
    func testWidthStates() throws {
        let roster = try rosterURL()
        let app = XCUIApplication()
        app.launchArguments = ["-roster-url", roster]
        app.launch()

        open(app, project: "paradigm-study-web",
             row: "Document application architecture and design patterns")
        shoot("full-session-keyboard-up", settle: 3.0)
        app.swipeDown()
        shoot("full-session-keyboard-down")
        app.buttons["terminal.back"].tap()

        // Still on the project page; the plain terminal is the native-width
        // baseline.
        let terminal = app.staticTexts["Terminal"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 8), "no Terminal row")
        terminal.tap()
        XCTAssertTrue(app.buttons["terminal.back"].waitForExistence(timeout: 8))
        shoot("fresh-terminal-keyboard-up", settle: 3.0)
        app.swipeDown()
        shoot("fresh-terminal-keyboard-down")
    }

    /// The scroll seam: slow drags through the transcript with a screenshot
    /// burst riding on a background queue, aiming to catch the torn frame the
    /// report describes (a stale strip splitting the screen left/right while
    /// content is in motion).
    func testScrollSeam() throws {
        let roster = try rosterURL()
        let app = XCUIApplication()
        app.launchArguments = ["-roster-url", roster]
        app.launch()

        open(app, project: "paradigm-study-web",
             row: "Document application architecture and design patterns")
        // Keyboard away first so the whole height scrolls.
        app.swipeDown()
        Thread.sleep(forTimeInterval: 2.0)

        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))

        var burst: [XCUIScreenshot] = []
        let burstLock = NSLock()
        var bursting = true
        let capture = DispatchQueue(label: "seam-burst")
        capture.async {
            while bursting {
                let shot = XCUIScreen.main.screenshot()
                burstLock.lock()
                burst.append(shot)
                burstLock.unlock()
                Thread.sleep(forTimeInterval: 0.12)
            }
        }

        // Three slow pulls down through the scrollback, then three back up.
        for _ in 0..<3 {
            start.press(forDuration: 0.05, thenDragTo: end,
                        withVelocity: 200, thenHoldForDuration: 0.05)
        }
        for _ in 0..<3 {
            end.press(forDuration: 0.05, thenDragTo: start,
                      withVelocity: 200, thenHoldForDuration: 0.05)
        }

        bursting = false
        capture.sync {}
        burstLock.lock()
        let shots = burst
        burstLock.unlock()
        for (index, shot) in shots.enumerated() {
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = String(format: "scroll-burst-%03d", index)
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        shoot("scroll-settled")
    }
}
