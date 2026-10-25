import AppKit
import Carbon.HIToolbox
import GhosttyVt
import XCTest
@testable import termio

/// Input on the `vt_stream` plane: every key, click, wheel turn, paste and
/// focus change is encoded against the modes the program negotiated, which
/// only the client terminal still hears once a pane streams.
@MainActor
final class StreamInputTests: XCTestCase {
    private func terminal(_ setup: String = "") throws -> TermiodStreamTerminal {
        var raw: GhosttyTerminal?
        XCTAssertEqual(ghostty_terminal_new(nil, &raw, 40, 10), GHOSTTY_SUCCESS)
        let source = try XCTUnwrap(raw)
        defer { ghostty_terminal_free(source) }
        var encoded: UnsafeMutablePointer<UInt8>?
        var length = 0
        XCTAssertEqual(ghostty_snapshot_encode_alloc(source, nil, &encoded, &length), GHOSTTY_SUCCESS)
        let pointer = try XCTUnwrap(encoded)
        defer { ghostty_free(nil, pointer, length) }
        let terminal = try TermiodStreamTerminal(nativeSnapshot: Data(bytes: pointer, count: length))
        terminal.write(Data(setup.utf8))
        return terminal
    }

    private func string(_ bytes: Data) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    private func key(_ key: GhosttyKey, mods: GhosttyMods = 0, text: String? = nil,
                     action: GhosttyKeyAction = GHOSTTY_KEY_ACTION_PRESS) -> TermiodStreamTerminal.KeyInput {
        TermiodStreamTerminal.KeyInput(action: action, key: key, mods: mods, text: text)
    }

    func testKeysFollowTheModesTheProgramNegotiated() throws {
        let terminal = try terminal()
        XCTAssertEqual(string(terminal.encode(key(GHOSTTY_KEY_ARROW_UP))), "\u{1b}[A")
        XCTAssertEqual(string(terminal.encode(key(GHOSTTY_KEY_A, text: "a"))), "a")
        XCTAssertEqual(string(terminal.encode(key(GHOSTTY_KEY_C, mods: GhosttyMods(GHOSTTY_MODS_CTRL)))), "\u{03}")
        XCTAssertEqual(terminal.encode(key(GHOSTTY_KEY_A, action: GHOSTTY_KEY_ACTION_RELEASE)), Data(),
                       "a release sends nothing outside Kitty's event reporting")

        terminal.write(Data("\u{1b}[?1h".utf8))
        XCTAssertEqual(string(terminal.encode(key(GHOSTTY_KEY_ARROW_UP))), "\u{1b}OA", "application cursor keys")

        terminal.write(Data("\u{1b}[>1u".utf8))
        XCTAssertEqual(string(terminal.encode(key(GHOSTTY_KEY_C, mods: GhosttyMods(GHOSTTY_MODS_CTRL)))),
                       "", "Kitty identifies a key by its unshifted character, which every real press carries")
        var controlC = key(GHOSTTY_KEY_C, mods: GhosttyMods(GHOSTTY_MODS_CTRL))
        controlC.unshiftedCodepoint = 0x63
        XCTAssertEqual(string(terminal.encode(controlC)), "\u{1b}[99;5u", "Kitty's disambiguate flag")
    }

    /// `sessions send --key up` on a stream pane: the same encoder, so it is
    /// `ESC O A` once the program asked for application cursor keys.
    func testANamedKeyFromTheCommandLineUsesTheLiveModes() throws {
        let terminal = try terminal("\u{1b}[?1h")
        let press = try XCTUnwrap(SessionKeyPress.parse("up"))
        let bytes = TermiodStreamKeyboard.inputs(for: press).map { terminal.encode($0) }
        XCTAssertEqual(bytes.map(string), ["\u{1b}OA", ""], "a press, then a release that sends nothing")
        let enter = TermiodStreamKeyboard.inputs(for: .return).map { terminal.encode($0) }
        XCTAssertEqual(string(enter[0]), "\r")
    }

    private func event(_ keycode: Int, _ characters: String, _ flags: NSEvent.ModifierFlags = [],
                       ignoring: String? = nil) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: ignoring ?? characters,
            isARepeat: false, keyCode: UInt16(keycode)
        ))
    }

    func testAKeystrokeBecomesThePhysicalKeyAndTheTextItTyped() throws {
        let a = try event(kVK_ANSI_A, "a")
        XCTAssertEqual(TermiodStreamKeyboard.key(forKeycode: a.keyCode), GHOSTTY_KEY_A)
        XCTAssertEqual(TermiodStreamKeyboard.typedText(of: a), "a")
        // Control turns c into ETX; the encoder wants the c.
        let controlC = try event(kVK_ANSI_C, "\u{03}", .control, ignoring: "c")
        XCTAssertEqual(TermiodStreamKeyboard.typedText(of: controlC), "c")
        // AppKit spells the arrows as private-use characters, which are no text.
        let up = try event(kVK_UpArrow, "\u{F700}")
        XCTAssertNil(TermiodStreamKeyboard.typedText(of: up))
        XCTAssertEqual(TermiodStreamKeyboard.key(forKeycode: up.keyCode), GHOSTTY_KEY_ARROW_UP)
        let input = TermiodStreamKeyboard.input(for: controlC, action: GHOSTTY_KEY_ACTION_PRESS, text: "c")
        XCTAssertEqual(input.mods & GhosttyMods(GHOSTTY_MODS_CTRL), GhosttyMods(GHOSTTY_MODS_CTRL))
        XCTAssertEqual(input.consumedMods & GhosttyMods(GHOSTTY_MODS_CTRL), 0, "Control stays the key's own")
    }

    /// Ghostty's editing defaults send legacy bytes even under Kitty's
    /// protocol, as the embedded surface does.
    func testTheEditingKeysSendWhatGhosttyBindsThemTo() throws {
        XCTAssertEqual(TermiodStreamKeyboard.naturalEditing(try event(kVK_LeftArrow, "\u{F702}", .command)),
                       Data([0x01]))
        XCTAssertEqual(TermiodStreamKeyboard.naturalEditing(try event(kVK_RightArrow, "\u{F703}", .command)),
                       Data([0x05]))
        XCTAssertEqual(TermiodStreamKeyboard.naturalEditing(try event(kVK_Delete, "\u{7f}", .command)),
                       Data([0x15]))
        XCTAssertEqual(TermiodStreamKeyboard.naturalEditing(try event(kVK_LeftArrow, "\u{F702}", .option)),
                       Data("\u{1b}b".utf8))
        XCTAssertEqual(TermiodStreamKeyboard.naturalEditing(try event(kVK_RightArrow, "\u{F703}", .option)),
                       Data("\u{1b}f".utf8))
        XCTAssertNil(TermiodStreamKeyboard.naturalEditing(try event(kVK_LeftArrow, "\u{F702}")))
        XCTAssertNil(TermiodStreamKeyboard.naturalEditing(try event(kVK_LeftArrow, "\u{F702}", [.command, .shift])))
    }

    private let layout = TermiodStreamTerminal.PixelLayout(cellWidth: 10, cellHeight: 20, paddingLeft: 4, paddingTop: 2)

    private func mouse(_ action: GhosttyMouseAction, _ button: GhosttyMouseButton?, column: Float, row: Float,
                       pressed: Bool = true) -> TermiodStreamTerminal.MouseInput {
        TermiodStreamTerminal.MouseInput(
            action: action, button: button, x: 4 + column * 10 + 5, y: 2 + row * 20 + 10, anyButtonPressed: pressed
        )
    }

    func testClicksAreReportedOnlyToAProgramThatAskedForThem() throws {
        let terminal = try terminal()
        XCTAssertFalse(terminal.tracksMouse)
        XCTAssertEqual(terminal.encode(mouse(GHOSTTY_MOUSE_ACTION_PRESS, GHOSTTY_MOUSE_BUTTON_LEFT, column: 3, row: 2),
                                       layout: layout), Data())

        terminal.write(Data("\u{1b}[?1000h\u{1b}[?1006h".utf8))
        XCTAssertTrue(terminal.tracksMouse)
        XCTAssertEqual(string(terminal.encode(
            mouse(GHOSTTY_MOUSE_ACTION_PRESS, GHOSTTY_MOUSE_BUTTON_LEFT, column: 3, row: 2), layout: layout)),
            "\u{1b}[<0;4;3M")
        XCTAssertEqual(string(terminal.encode(
            mouse(GHOSTTY_MOUSE_ACTION_RELEASE, GHOSTTY_MOUSE_BUTTON_LEFT, column: 3, row: 2, pressed: false),
            layout: layout)),
            "\u{1b}[<0;4;3m")
        // The grid is the session's 40 columns, not the pane's width: a click
        // past it is outside the terminal.
        XCTAssertEqual(terminal.encode(
            mouse(GHOSTTY_MOUSE_ACTION_PRESS, GHOSTTY_MOUSE_BUTTON_LEFT, column: 45, row: 2), layout: layout), Data())
    }

    func testTheWheelGoesWhereGhosttySendsIt() throws {
        let at = mouse(GHOSTTY_MOUSE_ACTION_PRESS, nil, column: 0, row: 0, pressed: false)
        let primary = try terminal()
        XCTAssertEqual(primary.scroll(rows: -2, at: at, layout: layout), Data(), "scrollback, nothing sent")

        let alternate = try terminal("\u{1b}[?1049h\u{1b}[?1007h")
        XCTAssertEqual(string(alternate.scroll(rows: -2, at: at, layout: layout)), "\u{1b}[A\u{1b}[A",
                       "alternate scroll turns the wheel into arrow keys")
        alternate.write(Data("\u{1b}[?1h".utf8))
        XCTAssertEqual(string(alternate.scroll(rows: 1, at: at, layout: layout)), "\u{1b}OB")

        let tracking = try terminal("\u{1b}[?1000h\u{1b}[?1006h")
        XCTAssertEqual(string(tracking.scroll(rows: -1, at: at, layout: layout)), "\u{1b}[<64;1;1M")
        XCTAssertEqual(string(tracking.scroll(rows: 2, at: at, layout: layout)), "\u{1b}[<65;1;1M\u{1b}[<65;1;1M")
    }

    func testAPasteIsBracketedOnlyWhenTheProgramAsked() throws {
        let terminal = try terminal()
        XCTAssertEqual(string(terminal.encodePaste("one\ntwo")), "one\rtwo", "unbracketed newlines are returns")
        terminal.write(Data("\u{1b}[?2004h".utf8))
        XCTAssertEqual(string(terminal.encodePaste("one\ntwo")), "\u{1b}[200~one\ntwo\u{1b}[201~")
        XCTAssertEqual(string(terminal.encodePaste("a\u{1b}[201~b")), "\u{1b}[200~a [201~b\u{1b}[201~",
                       "a pasted terminator cannot end the paste")
    }

    func testFocusIsReportedOnlyWhenAsked() throws {
        let terminal = try terminal()
        XCTAssertEqual(terminal.encodeFocus(true), Data())
        terminal.write(Data("\u{1b}[?1004h".utf8))
        XCTAssertEqual(string(terminal.encodeFocus(true)), "\u{1b}[I")
        XCTAssertEqual(string(terminal.encodeFocus(false)), "\u{1b}[O")
    }

    /// What `termio sessions read` reports for a stream pane.
    func testTheActiveScreenReadsAsText() throws {
        let terminal = try terminal("hello\r\nworld")
        let lines = try terminal.activeText().components(separatedBy: "\n")
        XCTAssertEqual(Array(lines.prefix(2)), ["hello", "world"])
    }

    /// Ghostty's preedit: composed text from the cursor on, in the foreground
    /// color and underlined, over the cells it covers, with no cursor drawn.
    func testComposedTextIsDrawnAtTheCursorInPlaceOfTheCells() throws {
        let terminal = try terminal("abcdef\r")
        let appearance = TermiodStreamRenderer.Appearance(
            fontFamily: "Menlo", fallbackFamilies: [], fontSize: 13, paddingX: 0, paddingY: 0, backgroundOpacity: 1
        )
        let renderer = try TermiodStreamRenderer(appearance: appearance, scale: 2)
        let builder = try TermiodStreamFrameBuilder()
        func frame(_ preedit: String?) throws -> ([TermiodStreamRectangle], [TermiodStreamGlyph]) {
            _ = try terminal.withFrame { state, theme in
                try builder.build(from: state, atlas: renderer.atlas, focused: true, theme: theme, preedit: preedit)
            }
            var rectangles: [TermiodStreamRectangle] = []
            var glyphs: [TermiodStreamGlyph] = []
            builder.flatten(rectangles: &rectangles, glyphs: &glyphs)
            return (rectangles, glyphs)
        }
        let plain = try frame(nil)
        XCTAssertEqual(plain.1.count, 6)
        XCTAssertTrue(plain.0.contains { $0.cellX == 0 && $0.cellY == 0 && $0.y == 0 }, "the block cursor")

        let composing = try frame("中文")
        let row = composing.1.filter { $0.cellY == 0 }
        XCTAssertEqual(row.map(\.cellX), [4, 5, 0, 2], "a b c d e f under 中 and 文 give way to them")
        XCTAssertFalse(composing.0.contains { $0.cellX == 0 && $0.y == 0 && $0.height > 4 }, "no cursor")
        let underlines = composing.0.filter { $0.overText && $0.cellY == 0 }
        XCTAssertEqual(underlines.map(\.cellX), [0, 2])

        XCTAssertEqual(try frame(nil).1.count, 6, "committing or cancelling gives the cells back")
    }
}
