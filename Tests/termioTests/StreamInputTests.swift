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

    func testTheWheelIsTheProgramsOnlyWhenGhosttyWouldSendIt() throws {
        XCTAssertFalse(try terminal().wheelGoesToProgram, "scrollback")
        XCTAssertTrue(try terminal("\u{1b}[?1049h\u{1b}[?1007h").wheelGoesToProgram, "alternate scroll")
        XCTAssertFalse(try terminal("\u{1b}[?1049h\u{1b}[?1007l").wheelGoesToProgram)
        XCTAssertTrue(try terminal("\u{1b}[?1000h").wheelGoesToProgram, "mouse tracking")
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
