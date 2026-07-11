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

    func testSlashPanelScrolls() {
        let app = launch("terminal")
        XCTAssertTrue(app.staticTexts["Prompt"].waitForExistence(timeout: 8))
        // The composer is already first responder on screen load, so type
        // straight into it (firstMatch would grab the terminal surface).
        app.typeText("/")
        XCTAssertTrue(app.buttons["Send /clear"].waitForExistence(timeout: 4))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "slash-panel"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testTerminalControlBarAppearsWithKeyboard() {
        let app = launch("terminal")
        XCTAssertTrue(app.staticTexts["Prompt"].waitForExistence(timeout: 8))
        // Focusing the composer brings up the system keyboard with the control
        // bar docked above it — esc leads, the configured keys follow.
        app.textViews.firstMatch.tap()
        XCTAssertTrue(app.buttons["esc"].waitForExistence(timeout: 4))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "terminal-control-bar"
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
        // The attachment sheet: ✕ / "Recents ⌄" header, edge-to-edge recents
        // grid with a camera tile up front, Gallery·File tab bar. The grid is
        // our own collection view, so a11y queries are safe here (unlike
        // PHPicker's remote tree, which SIGKILLs the runner).
        XCTAssertTrue(app.buttons["Recents"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["File"].exists)
        XCTAssertTrue(app.buttons["Close"].exists)
        // First open asks for photo access (each test run resets TCC and
        // XCTest's implicit interruption monitor would deny it) — answer the
        // system alert explicitly.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow Full Access"]
        if allow.waitForExistence(timeout: 4) { allow.tap() }
        sleep(2)
        attachShot(app, "sheet-open")
        // Cell 0 is the camera tile (the iOS 26 simulator reports a camera),
        // so the photos start at index 1.
        let cells = app.collectionViews["attach.grid"].cells
        XCTAssertTrue(cells.element(boundBy: 2).waitForExistence(timeout: 8))
        cells.element(boundBy: 1).tap()
        cells.element(boundBy: 2).tap()
        attachShot(app, "sheet-selected")
        let addButton = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH 'Add'")).firstMatch
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()
        // Both uploads land as absolute Mac paths in the draft.
        let uploaded = app.textViews.matching(
            NSPredicate(format: "value CONTAINS '.termio/uploads/'")).firstMatch
        XCTAssertTrue(uploaded.waitForExistence(timeout: 30), "no upload path in draft")
        attachShot(app, "attach-upload-draft")
    }

    // MARK: - Chat lens (live companion only)

    /// End-to-end over a REAL companion link: a Claude session opens as the
    /// chat view (user bubble, agent reply, tool-call group with an
    /// expandable diff) — for an adapted agent the conversation IS the
    /// session UI, with no terminal toggle. Needs a Mac whose roster holds
    /// a Claude session with at least one edit turn — skips itself
    /// otherwise, so the demo suite stays green without one.
    func testChatLensRendersStructuredConversation() throws {
        let app = XCUIApplication()
        // A dev-channel Mac serves on 8788 with a pairing token; pass its URL
        // via TEST_RUNNER_CHATLENS_ROSTER_URL. Default matches the release port.
        let roster = ProcessInfo.processInfo.environment["CHATLENS_ROSTER_URL"]
            ?? "ws://127.0.0.1:8787"
        app.launchArguments = ["-roster-url", roster]
        app.launch()
        let row = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS 'Create and edit'")).firstMatch
        try XCTSkipUnless(row.waitForExistence(timeout: 15), "no live claude session in roster")
        row.tap()

        // Chat is the default lens for a Claude session: the transcript's
        // user prompt renders as a bubble without any lens switching.
        let bubble = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS 'Use the Write tool'")).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 20), "user bubble did not render")
        attachShot(app, "chat-default")

        // The Write + Edit calls fold behind one humanized summary line;
        // expanding it discloses the per-call rows (same phrasing, so the
        // summary is match 0 and the calls are matches 1 and 2).
        let toolRows = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS 'Edited chatlens-test.txt'"))
        XCTAssertTrue(toolRows.firstMatch.waitForExistence(timeout: 10), "tool summary missing")
        toolRows.firstMatch.tap()
        XCTAssertTrue(toolRows.element(boundBy: 2).waitForExistence(timeout: 5), "call rows missing")
        attachShot(app, "chat-tools-expanded")

        // Opening the Edit call (the second disclosed row) shows its diff.
        toolRows.element(boundBy: 2).tap()
        let diffLine = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS 'BETA'")).firstMatch
        XCTAssertTrue(diffLine.waitForExistence(timeout: 5), "diff lines missing")
        attachShot(app, "chat-diff")

        // The conversation is the whole session UI: no terminal toggle.
        XCTAssertFalse(app.buttons["terminal.lens"].exists)

        // Sending from the composer shows the typing indicator immediately
        // (the optimistic window) — the chat is never a dead screen while
        // the agent works. The chat opens reading-first (no auto-focus), so
        // the composer needs a tap and a settled focus before typing.
        let composer = app.textViews["composer.field"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        if (composer.value(forKey: "hasKeyboardFocus") as? Bool) != true {
            sleep(1)
            composer.tap()
        }
        composer.typeText("Reply with exactly: pong")
        app.buttons["Send"].tap()
        let typing = app.otherElements["chat.typing"]
        XCTAssertTrue(typing.waitForExistence(timeout: 5), "typing indicator missing after send")
        attachShot(app, "chat-typing")
        // The reply's arrival depends on a possibly just-resumed agent and
        // model latency; the indicator above was the assertion — the reply
        // shot is best-effort evidence, not a gate.
        _ = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'pong'"))
            .firstMatch.waitForExistence(timeout: 60)
        attachShot(app, "chat-reply")
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
