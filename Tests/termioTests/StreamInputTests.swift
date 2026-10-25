import AppKit
import Carbon.HIToolbox
import GhosttyVt
import TermioShared
import XCTest
@testable import termio

/// Input on the `vt_stream` plane: the client turns keystrokes into events
/// that termiod encodes against its own VT (termiod's `input` tests cover the
/// bytes), draws the input method's text, and keeps Ghostty's editing keys.
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
        XCTAssertEqual(TermiodStreamKeyboard.key(forKeycode: a.keyCode), "a")
        XCTAssertEqual(TermiodStreamKeyboard.typedText(of: a), "a")
        // Control turns c into ETX; the encoder wants the c.
        let controlC = try event(kVK_ANSI_C, "\u{03}", .control, ignoring: "c")
        XCTAssertEqual(TermiodStreamKeyboard.typedText(of: controlC), "c")
        // AppKit spells the arrows as private-use characters, which are no text.
        let up = try event(kVK_UpArrow, "\u{F700}")
        XCTAssertNil(TermiodStreamKeyboard.typedText(of: up))
        XCTAssertEqual(TermiodStreamKeyboard.key(forKeycode: up.keyCode), "arrow_up")
        let input = TermiodStreamKeyboard.input(for: controlC, action: .press, text: "c")
        XCTAssertEqual(input.mods & TermiodStreamKeyboard.control, TermiodStreamKeyboard.control)
        XCTAssertEqual(input.consumedMods & TermiodStreamKeyboard.control, 0, "Control stays the key's own")
        XCTAssertEqual(input.unshifted, 0x63)
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

    /// `sessions send --key up` on a stream pane is a press and a release of
    /// the named key; termiod picks the bytes.
    func testANamedKeyFromTheCommandLineIsAPressAndARelease() throws {
        let press = try XCTUnwrap(SessionKeyPress.parse("ctrl-c"))
        let events = TermiodStreamKeyboard.inputs(for: press)
        XCTAssertEqual(events.map(\.key), ["c", "c"])
        XCTAssertEqual(events.map(\.action), [.press, .release])
        XCTAssertEqual(events[0].mods, TermiodStreamKeyboard.control)
        XCTAssertEqual(events[0].unshifted, 0x63)
    }

    /// The wire shape termiod's `Event::Key`, `Mouse` and `Focus` decode.
    func testInputEventsCarryTheFieldsTermiodReads() throws {
        func json(_ event: Termiod.InputEvent) throws -> [String: Any] {
            try XCTUnwrap(try JSONSerialization.jsonObject(with: try event.payload()) as? [String: Any])
        }
        let key = try json(.key(.init(action: .repeat, key: "arrow_up", mods: 2, text: nil)))
        XCTAssertEqual(key["ev"] as? String, "key")
        XCTAssertEqual(key["action"] as? String, "repeat")
        XCTAssertEqual(key["key"] as? String, "arrow_up")
        XCTAssertEqual(key["consumed_mods"] as? Int, 0)
        let mouse = try json(.mouse(.init(action: .press, button: 1, mods: 0,
                                          at: .init(x: 5, y: 10, cellWidth: 16, cellHeight: 32), buttonsHeld: true)))
        XCTAssertEqual(mouse["ev"] as? String, "mouse")
        XCTAssertEqual(mouse["cell_width"] as? Int, 16)
        XCTAssertEqual(mouse["buttons_held"] as? Bool, true)
        XCTAssertEqual(try json(.focus(false))["focused"] as? Bool, false)
        XCTAssertEqual(try json(.paste("hi"))["text"] as? String, "hi")
    }

    /// A paste past one frame's room goes as pieces, each but the last marked
    /// `more`, split between characters, never inside one.
    func testALargePasteGoesInPiecesTermiodJoins() throws {
        let text = String(repeating: "中", count: Termiod.InputEvent.pastePieceBytes / 3 + 10)
        let pieces = Termiod.InputEvent.pastePieces(text)
        XCTAssertEqual(pieces.count, 2)
        var joined = ""
        for (index, piece) in pieces.enumerated() {
            guard case .paste(let part, let more) = piece else { return XCTFail("not a paste") }
            XCTAssertLessThanOrEqual(part.utf8.count, Termiod.InputEvent.pastePieceBytes)
            XCTAssertEqual(more, index == 0)
            joined += part
        }
        XCTAssertEqual(joined, text)
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: try pieces[0].payload()) as? [String: Any])
        XCTAssertEqual(first["more"] as? Bool, true)
        XCTAssertEqual(Termiod.InputEvent.pastePieces("short"), [.paste("short")])

        // One character larger than a piece: `a` and half a million combining
        // accents. It is still split, so every piece fits.
        let huge = "a" + String(repeating: "\u{0301}", count: 524_288)
        XCTAssertEqual(huge.count, 1)
        let hugePieces = Termiod.InputEvent.pastePieces(huge)
        XCTAssertGreaterThan(hugePieces.count, 1)
        var rejoined = ""
        for piece in hugePieces {
            guard case .paste(let part, _) = piece else { return XCTFail("not a paste") }
            XCTAssertLessThanOrEqual(part.utf8.count, Termiod.InputEvent.pastePieceBytes)
            rejoined += part
        }
        XCTAssertEqual(rejoined.utf8.count, huge.utf8.count)
    }

    /// Only typing takes the write token: a modifier pressed on the way to a
    /// shortcut, a release, a composing key, motion and focus send no byte.
    func testOnlyTypingClaimsTheWriteToken() {
        XCTAssertTrue(Termiod.InputEvent.key(.init(key: "a", text: "a")).claimsWriter)
        XCTAssertFalse(Termiod.InputEvent.key(.init(key: "meta_left")).claimsWriter)
        XCTAssertFalse(Termiod.InputEvent.key(.init(action: .release, key: "a")).claimsWriter)
        XCTAssertFalse(Termiod.InputEvent.key(.init(key: "a", composing: true)).claimsWriter)
        XCTAssertTrue(Termiod.InputEvent.paste("x").claimsWriter)
        let at = Termiod.InputEvent.Pointer(x: 0, y: 0, cellWidth: 8, cellHeight: 16)
        XCTAssertTrue(Termiod.InputEvent.mouse(.init(action: .press, button: 1, mods: 0, at: at, buttonsHeld: true)).claimsWriter)
        XCTAssertFalse(Termiod.InputEvent.mouse(.init(action: .motion, button: nil, mods: 0, at: at, buttonsHeld: false)).claimsWriter)
        XCTAssertFalse(Termiod.InputEvent.focus(true).claimsWriter)
    }

    /// Back and forward are buttons eight and nine, as Ghostty numbers them.
    func testExtraMouseButtonsKeepTheirNumbers() throws {
        func other(_ number: Int) throws -> UInt8? {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: .otherMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            // `buttonNumber` is not settable on a synthesized event; go through CGEvent.
            let cg = try XCTUnwrap(event.cgEvent)
            cg.setIntegerValueField(.mouseEventButtonNumber, value: Int64(number))
            return TermiodStreamView.otherButton(try XCTUnwrap(NSEvent(cgEvent: cg)))
        }
        XCTAssertEqual(try other(2), 3, "middle")
        XCTAssertEqual(try other(3), 8, "back")
        XCTAssertEqual(try other(4), 9, "forward")
        XCTAssertEqual(try other(5), 6)
        XCTAssertEqual(try other(7), 4)
        XCTAssertEqual(try other(10), 11)
        XCTAssertNil(try other(11))
    }

    func testTheWheelIsTheProgramsOnlyWhenGhosttyWouldSendIt() throws {
        XCTAssertFalse(try terminal().wheelGoesToProgram, "scrollback")
        XCTAssertTrue(try terminal("\u{1b}[?1049h\u{1b}[?1007h").wheelGoesToProgram, "alternate scroll")
        XCTAssertFalse(try terminal("\u{1b}[?1049h\u{1b}[?1007l").wheelGoesToProgram)
        XCTAssertTrue(try terminal("\u{1b}[?1000h").wheelGoesToProgram, "mouse tracking")
    }

    /// What the program tells the terminal that the app acts on, as the
    /// embedded surface publishes it, and what a snapshot already carries.
    func testTheTerminalReportsTitleDirectoryBellNotificationsAndCopies() throws {
        var raw: GhosttyTerminal?
        XCTAssertEqual(ghostty_terminal_new(nil, &raw, 40, 10), GHOSTTY_SUCCESS)
        let source = try XCTUnwrap(raw)
        defer { ghostty_terminal_free(source) }
        let setup = Array("\u{1b}]0;agent at work\u{07}\u{1b}]7;file://localhost/tmp/work\u{07}".utf8)
        ghostty_terminal_vt_write(source, setup, setup.count)
        var encoded: UnsafeMutablePointer<UInt8>?
        var length = 0
        XCTAssertEqual(ghostty_snapshot_encode_alloc(source, nil, &encoded, &length), GHOSTTY_SUCCESS)
        let pointer = try XCTUnwrap(encoded)
        defer { ghostty_free(nil, pointer, length) }
        var signals: [TermiodStreamTerminal.Signal] = []
        let terminal = try TermiodStreamTerminal(
            nativeSnapshot: Data(bytes: pointer, count: length), onSignal: { signals.append($0) }
        )
        XCTAssertEqual(signals, [.workingDirectory("/tmp/work")], "the snapshot's directory, not its title")

        signals = []
        terminal.write(Data("\u{1b}]2;thinking\u{07}".utf8))
        terminal.write(Data("\u{1b}]7;file://localhost/home/me/project%20one\u{07}".utf8))
        terminal.write(Data("\u{07}".utf8))
        terminal.write(Data("\u{1b}]9;build finished\u{07}".utf8))
        terminal.write(Data("\u{1b}]777;notify;Claude;needs you\u{07}".utf8))
        terminal.write(Data("\u{1b}]52;c;aGVsbG8=\u{07}".utf8))
        XCTAssertEqual(signals, [
            .title("thinking"),
            .workingDirectory("/home/me/project one"),
            .bell,
            .notification(title: "", body: "build finished"),
            .notification(title: "Claude", body: "needs you"),
            .clipboard("hello"),
        ])
    }

    /// Ghostty's OSC 7 rule: a `file` or `kitty-shell-cwd` URL naming this
    /// machine. A path from a box reached with ssh does not exist here.
    func testAWorkingDirectoryMustNameThisMachine() {
        let read = { TermiodStreamTerminal.workingDirectory(fromOSC7: $0, localHost: "mac") }
        XCTAssertEqual(read("file://mac/Users/me/a%20b"), "/Users/me/a b")
        XCTAssertEqual(read("file://localhost/tmp"), "/tmp")
        XCTAssertEqual(read("kitty-shell-cwd://mac/raw/%20path"), "/raw/%20path", "kitty sends the path as is")
        XCTAssertNil(read("file://prod/home/deploy"), "another machine")
        XCTAssertNil(read("file:///tmp"), "no host")
        XCTAssertNil(read("https://mac/tmp"), "another scheme")
        XCTAssertNil(read("/tmp"), "not a URL")
    }

    /// A program reading the clipboard is answered through the reply path,
    /// which only the writer sends on.
    func testAClipboardReadIsAnsweredThroughTheReplyPath() throws {
        var raw: GhosttyTerminal?
        XCTAssertEqual(ghostty_terminal_new(nil, &raw, 40, 10), GHOSTTY_SUCCESS)
        let source = try XCTUnwrap(raw)
        defer { ghostty_terminal_free(source) }
        var encoded: UnsafeMutablePointer<UInt8>?
        var length = 0
        XCTAssertEqual(ghostty_snapshot_encode_alloc(source, nil, &encoded, &length), GHOSTTY_SUCCESS)
        let pointer = try XCTUnwrap(encoded)
        defer { ghostty_free(nil, pointer, length) }
        var replies = Data()
        let terminal = try TermiodStreamTerminal(
            nativeSnapshot: Data(bytes: pointer, count: length),
            onReply: { replies.append($0) }, readClipboard: { "hello" }
        )
        terminal.write(Data("\u{1b}]52;c;?\u{07}".utf8))
        let reply = String(decoding: replies, as: UTF8.self)
        XCTAssertTrue(reply.contains("52;c;aGVsbG8="), reply.debugDescription)
    }

    /// Ghostty counts half cells: a selection starts at a cell pressed in its
    /// left half and takes in a cell dragged past its middle, so presses sit
    /// at 2 of 10 pixels and drags at 8.
    private func point(_ column: UInt16, _ row: UInt16, at offset: Double = 2) -> TermiodStreamTerminal.SelectionPoint {
        .init(column: column, row: row, x: Double(column) * 10 + offset, y: Double(row) * 20 + 10)
    }

    /// Ghostty's mouse selection, on the stream pane's own terminal: a drag
    /// selects cells, a double click a word, and copying joins soft wraps.
    func testTheMouseSelectsAsGhosttyDoes() throws {
        let terminal = try terminal("hello world\r\nsecond line")
        let geometry = TermiodStreamTerminal.SelectionGeometry(cellWidth: 10, paddingLeft: 0, screenHeight: 200)
        XCTAssertNil(terminal.selectedText)

        terminal.pressSelection(at: point(0, 0), time: 1_000, interval: 500_000_000)
        terminal.dragSelection(to: point(4, 0, at: 8), geometry: geometry, rectangle: false)
        terminal.releaseSelection(at: point(4, 0, at: 8))
        XCTAssertEqual(terminal.selectedText, "hello")

        // Two presses within the interval: the word under the pointer.
        terminal.pressSelection(at: point(7, 0), time: 2_000_000_000, interval: 500_000_000)
        terminal.releaseSelection(at: point(7, 0))
        terminal.pressSelection(at: point(7, 0), time: 2_100_000_000, interval: 500_000_000)
        terminal.releaseSelection(at: point(7, 0))
        XCTAssertEqual(terminal.selectedText, "world")

        // A single click later clears it.
        terminal.pressSelection(at: point(1, 1), time: 9_000_000_000, interval: 500_000_000)
        terminal.releaseSelection(at: point(1, 1))
        XCTAssertFalse(terminal.hasSelection)

        terminal.selectAll()
        XCTAssertEqual(terminal.selectedText, "hello world\nsecond line")
        terminal.clearSelection()
        XCTAssertNil(terminal.selectedText)
    }

    /// Ghostty's scrolling bindings move this pane's view through history.
    func testTheViewMovesThroughScrollback() throws {
        let terminal = try terminal((1...40).map { "line \($0)" }.joined(separator: "\r\n"))
        XCTAssertTrue(terminal.followsLiveScreen)
        terminal.moveViewport(.top)
        XCTAssertFalse(terminal.followsLiveScreen)
        terminal.moveViewport(.pageDown)
        terminal.moveViewport(.pageDown)
        terminal.moveViewport(.pageDown)
        XCTAssertTrue(terminal.followsLiveScreen, "three pages of ten rows reach the 40 lines' end")
        terminal.moveViewport(.pageUp)
        XCTAssertFalse(terminal.followsLiveScreen)
        terminal.moveViewport(.bottom)
        XCTAssertTrue(terminal.followsLiveScreen)
    }

    /// A selected cell is drawn with its colors swapped.
    func testASelectionIsDrawnWithTheColorsSwapped() throws {
        let terminal = try terminal("abc")
        let appearance = TermiodStreamRenderer.Appearance(
            fontFamily: "Menlo", fallbackFamilies: [], fontSize: 13, paddingX: 0, paddingY: 0, backgroundOpacity: 1
        )
        let renderer = try TermiodStreamRenderer(appearance: appearance, scale: 2)
        let builder = try TermiodStreamFrameBuilder()
        func glyph(at column: UInt16) throws -> TermiodStreamGlyph {
            builder.invalidate()
            _ = try terminal.withFrame { state, theme in
                try builder.build(from: state, atlas: renderer.atlas, focused: false, theme: theme)
            }
            var rectangles: [TermiodStreamRectangle] = []
            var glyphs: [TermiodStreamGlyph] = []
            builder.flatten(rectangles: &rectangles, glyphs: &glyphs)
            return try XCTUnwrap(glyphs.first { $0.cellX == column && $0.cellY == 0 })
        }
        let plain = try glyph(at: 1)
        terminal.pressSelection(at: point(0, 0), time: 1, interval: 1)
        terminal.dragSelection(
            to: point(1, 0, at: 8), geometry: .init(cellWidth: 10, paddingLeft: 0, screenHeight: 200), rectangle: false
        )
        let selected = try glyph(at: 1)
        XCTAssertNotEqual([plain.r, plain.g, plain.b], [selected.r, selected.g, selected.b],
                          "the selected b is drawn in the background color")
        XCTAssertEqual([try glyph(at: 2).r], [plain.r], "c is outside the selection")
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
