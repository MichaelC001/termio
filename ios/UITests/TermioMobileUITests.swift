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
