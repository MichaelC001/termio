import XCTest

/// Not a test of behavior — a screenshot harness for App Store material.
/// Drives the app against the REAL Mac companion roster (passed via the
/// `ROSTER_URL` runner environment variable) and attaches a named screenshot
/// of each marketing state; `xcresulttool export attachments` pulls them out.
/// Skips itself when no roster URL is provided, so CI never runs it.
final class MarketingScreensTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        // Give animations and the terminal renderer a beat to settle.
        Thread.sleep(forTimeInterval: 2.5)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Opens the session row with the given title from the project page,
    /// captures keyboard-up and full-screen states, then pops back.
    private func captureSession(
        _ app: XCUIApplication, row: String, slug: String, keyboardShot: Bool
    ) {
        let sessionRow = app.staticTexts[row].firstMatch
        XCTAssertTrue(sessionRow.waitForExistence(timeout: 8), "no session row \(row)")
        sessionRow.tap()
        let back = app.buttons["terminal.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 8))
        if keyboardShot {
            shoot(app, "\(slug)-keyboard")
        }
        // A pan on the surface resigns first responder — the keyboard drops
        // and the terminal stretches to the screen bottom.
        app.swipeDown()
        shoot(app, "\(slug)-full")
        back.tap()
    }

    func testMarketingScreens() throws {
        guard let rosterURL = ProcessInfo.processInfo.environment["ROSTER_URL"],
              !rosterURL.isEmpty
        else {
            throw XCTSkip("ROSTER_URL not set — marketing capture is manual-only")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-roster-url", rosterURL]
        app.launch()

        // Projects root.
        XCTAssertTrue(app.staticTexts["home"].waitForExistence(timeout: 10))
        shoot(app, "projects")

        // The home project's session list.
        app.staticTexts["home"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Claude Code"].firstMatch.waitForExistence(timeout: 8))
        shoot(app, "sessions")

        captureSession(app, row: "Claude Code", slug: "claude", keyboardShot: true)
        captureSession(app, row: "Codex", slug: "codex", keyboardShot: false)
        captureSession(app, row: "Terminal", slug: "terminal", keyboardShot: false)
    }
}
