import XCTest

/// Smoke suite over the app's deterministic demo states (`-demo …` launch
/// arguments), so every screen is reachable without a Mac companion link:
/// the session list (the iMessage-style inbox root), the terminal session
/// screen (the Moshi shape: PTY + composer, no separate chat UI), and the
/// file viewer.
final class TermioMobileUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(_ mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", mode]
        app.launch()
        return app
    }

    // MARK: - Session list (the inbox root page)

    func testSidebarListsMockSessionsGroupedByProject() {
        let app = launch("list")
        // Mock roster: project headers + session rows.
        XCTAssertTrue(app.staticTexts["fix-sidebar"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["landing-hero"].exists)
        XCTAssertTrue(app.staticTexts["termio"].exists)      // project header
        XCTAssertTrue(app.staticTexts["vibewizard"].exists)  // second project
    }

    func testSidebarSortMenuReordersProjects() {
        let app = launch("list")
        let sort = app.buttons["Sort"]
        XCTAssertTrue(sort.waitForExistence(timeout: 8))
        sort.tap()
        // The Mac sidebar's two orders, mirrored.
        XCTAssertTrue(app.buttons["Name"].waitForExistence(timeout: 3))
        app.buttons["Name"].tap()
        XCTAssertTrue(app.staticTexts["termio"].waitForExistence(timeout: 3))
        // Restore the default so this test doesn't leak state.
        sort.tap()
        app.buttons["Recent Activity"].tap()
    }

    // MARK: - Session screen (terminal + composer)

    func testOpenSessionFromListPushesTerminal() {
        let app = launch("list")
        let row = app.staticTexts["fix-sidebar"]
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()
        // The terminal pushes over the list: back chevron + composer.
        XCTAssertTrue(app.buttons["terminal.back"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Prompt"].exists)
    }

    func testTerminalSwipeRightPopsToList() {
        let app = launch("terminal")
        XCTAssertTrue(app.staticTexts["Prompt"].waitForExistence(timeout: 8))
        // A rightward pan anywhere on the surface goes back to the inbox,
        // the same swipe Messages answers with a pop.
        app.swipeRight()
        XCTAssertTrue(app.staticTexts["Sessions"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["fix-sidebar"].exists)
    }

    func testTerminalBackChevronPopsToList() {
        let app = launch("terminal")
        let back = app.buttons["terminal.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 8))
        back.tap()
        XCTAssertTrue(app.staticTexts["Sessions"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["fix-sidebar"].exists)
    }

    func testTerminalFingerScrollDoesNotCrash() {
        let app = launch("terminal")
        XCTAssertTrue(app.staticTexts["Prompt"].waitForExistence(timeout: 8))
        // Vertical pan over the terminal surface — the scroll path seeds the
        // ghostty mouse position via reflection into the wrapper's internals,
        // so this guards that chain against wrapper updates breaking it.
        app.swipeUp()
        app.swipeDown()
        XCTAssertTrue(app.staticTexts["Prompt"].exists)
    }

    func testTerminalKeyboardSwapsIn() {
        let app = launch("terminal")
        let toggle = app.buttons["Terminal keyboard"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))
        // The real flow: the system keyboard comes up first (the swap reuses
        // its measured height), then ⌨︎ switches planes.
        app.textViews.firstMatch.tap()
        toggle.tap()
        // The swap-in keyboard: esc leads the control zone, return anchors
        // the bottom row.
        XCTAssertTrue(app.buttons["esc"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["return"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "terminal-keyboard"
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - Inspector drawer (file tree)

    func testInspectorFileTreeShowsLanguageIcons() {
        let app = launch("terminal")
        XCTAssertTrue(app.staticTexts["Prompt"].waitForExistence(timeout: 8))
        // A leftward pan on the surface pulls the inspector drawer out.
        app.swipeLeft()
        // The mock tree's rows come up; files draw their language marks.
        XCTAssertTrue(app.staticTexts["App.swift"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["README.md"].exists)
        XCTAssertTrue(app.staticTexts["Package.swift"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "inspector-file-tree"
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - Attachments (live companion only)

    /// End-to-end over a REAL companion link: multi-select two photos, watch
    /// the queue upload them, and expect both Mac-side paths in the draft.
    /// Skips itself when no Mac companion server is reachable, so the demo
    /// suite stays green without one.
    func testAttachPhotoBatchUploadsToCompanion() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-roster-url", "ws://127.0.0.1:8787"]
        app.launch()
        let row = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS 'Claude Code'")).firstMatch
        try XCTSkipUnless(row.waitForExistence(timeout: 15), "no live companion roster")
        row.tap()
        let attach = app.buttons["Attach"]
        try XCTSkipUnless(attach.waitForExistence(timeout: 10), "session has no upload backend")
        attach.tap()
        // The source sheet. (Camera's row is environment-dependent — the
        // iOS 26 simulator reports a camera — so it isn't asserted.)
        XCTAssertTrue(app.buttons["Photo Library"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Choose File"].exists)
        app.buttons["Photo Library"].tap()
        // PHPicker is remote but its cells surface through the a11y tree,
        // labeled "Photo, <date>, <time>" — scope by label so the app's own
        // symbol images (chevrons etc.) don't match first.
        sleep(4)
        attachShot(app, "picker-open")
        // PHPicker's remote tree hangs XCUITest queries (runner gets SIGKILLed
        // building snapshots), so the picker is driven blind: normalized
        // coordinate taps for two grid cells, then the Add button.
        tapNormalized(app, 0.17, 0.63)
        tapNormalized(app, 0.50, 0.63)
        sleep(1)
        attachShot(app, "picker-selected")
        tapNormalized(app, 0.91, 0.167)
        sleep(2)
        attachShot(app, "picker-added")
        // Both uploads land as absolute Mac paths in the draft.
        let uploaded = app.textViews.matching(
            NSPredicate(format: "value CONTAINS '.termio/uploads/'")).firstMatch
        XCTAssertTrue(uploaded.waitForExistence(timeout: 30), "no upload path in draft")
        attachShot(app, "attach-upload-draft")
    }

    private func tapNormalized(_ app: XCUIApplication, _ dx: Double, _ dy: Double) {
        app.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy)).tap()
    }

    private func attachShot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - Mac pairing (QR)

    /// Pairing lives in Settings ▸ Connectivity: its Scan QR Code row brings
    /// up the scanner sheet (camera-less simulators show its typed-address
    /// fallback instead of a preview — presentation is what's under test).
    func testScanEntryPresentsScanner() throws {
        let app = launch("list")
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 8))
        app.buttons["Settings"].tap()
        let connectivity = app.staticTexts["Connectivity"]
        XCTAssertTrue(connectivity.waitForExistence(timeout: 4))
        connectivity.tap()
        let scan = app.staticTexts["Scan QR Code"]
        XCTAssertTrue(scan.waitForExistence(timeout: 4))
        scan.tap()
        XCTAssertTrue(app.navigationBars["Scan QR Code"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Connectivity"].waitForExistence(timeout: 3))
    }

    // MARK: - File viewer

    func testFileViewerShowsHighlightedSource() {
        let app = launch("file")
        XCTAssertTrue(app.staticTexts["RootContainerViewController.swift"]
            .waitForExistence(timeout: 8))
        // Footer: language · size.
        XCTAssertTrue(app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS %@", "swift"))
            .firstMatch.exists)
    }
}
