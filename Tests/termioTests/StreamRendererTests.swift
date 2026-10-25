import AppKit
import GhosttyVt
import XCTest
@testable import termio

/// The stream renderer, drawn offscreen: no window, so it runs anywhere Metal
/// does. Pixels are read back at cells whose color the screen fixes, and
/// `TERMIO_RENDER_OUT=<file.png>` saves the frame to look at by eye.
@MainActor
final class StreamRendererTests: XCTestCase {
    private let appearance = TermiodStreamRenderer.Appearance(
        fontFamily: "Menlo", fallbackFamilies: [], fontSize: 13, cursorStyle: .block,
        paddingX: 8, paddingY: 2, backgroundOpacity: 1
    )

    private func terminal() throws -> TermiodStreamTerminal {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "vt-stream-resize", withExtension: "txt", subdirectory: "Fixtures"))
        let attach = try XCTUnwrap(
            try String(contentsOf: url, encoding: .utf8).split(separator: "\n").first { $0.hasPrefix("attach ") })
        var native = Data()
        var high: UInt8?
        for character in attach.dropFirst("attach ".count).utf8 {
            let nibble = try XCTUnwrap(UInt8(String(UnicodeScalar(character)), radix: 16))
            if let first = high { native.append(first << 4 | nibble); high = nil } else { high = nibble }
        }
        let terminal = try TermiodStreamTerminal(nativeSnapshot: native)
        // Finish the OSC the snapshot was taken inside, then start clean.
        terminal.write(Data("\u{7}\u{1b}[2J\u{1b}[H".utf8))
        try terminal.resize(rows: 10, cols: 40, reflow: true)
        return terminal
    }

    private func colors() -> TermiodStreamTerminal.Colors {
        var palette = [GhosttyColorRgb](repeating: GhosttyColorRgb(r: 128, g: 128, b: 128), count: 256)
        palette[1] = GhosttyColorRgb(r: 220, g: 40, b: 40)
        palette[4] = GhosttyColorRgb(r: 40, g: 80, b: 220)
        return TermiodStreamTerminal.Colors(
            foreground: GhosttyColorRgb(r: 230, g: 230, b: 230),
            background: GhosttyColorRgb(r: 20, g: 20, b: 20),
            cursor: nil, palette: palette
        )
    }

    func testAFrameDrawsTheThemeTheCellsAndTheText() throws {
        let terminal = try terminal()
        try terminal.setColors(colors())
        let screen = [
            "\u{1b}[41m  red  \u{1b}[0m \u{1b}[1mbold\u{1b}[0m \u{1b}[3mitalic\u{1b}[0m \u{1b}[2mfaint\u{1b}[0m",
            "\u{1b}[4msingle\u{1b}[0m \u{1b}[4:2mdouble\u{1b}[0m \u{1b}[4:3mcurly\u{1b}[0m \u{1b}[9mstrike\u{1b}[0m",
            "\u{1b}[38;2;255;160;0mtrue colour\u{1b}[0m \u{1b}[44;97m blue \u{1b}[0m \u{1b}[7minverse\u{1b}[0m",
            "你好，世界 ┌──┐ 🚀✨ e\u{301}",
            "$ ",
        ].joined(separator: "\r\n")
        terminal.write(Data(screen.utf8))

        let renderer = try TermiodStreamRenderer(appearance: appearance, scale: 2)
        let metrics = renderer.atlas.metrics
        let width = Int(2 * appearance.paddingX) + metrics.width * 40
        let height = Int(2 * appearance.paddingY * 2) + metrics.height * 10
        let image = try renderer.image(of: terminal, width: width, height: height)
        if let path = ProcessInfo.processInfo.environment["TERMIO_RENDER_OUT"] {
            let representation = NSBitmapImageRep(cgImage: image)
            try representation.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }

        // The texture's own bytes, BGRA: reading through NSColor would color-manage them.
        let pixels = try XCTUnwrap(image.dataProvider?.data as Data?)
        func color(column: Int, row: Int, dx: Int = 1, dy: Int = 1) -> (Int, Int, Int) {
            let x = Int(appearance.paddingX * 2) + column * metrics.width + dx
            let y = Int(appearance.paddingY * 2) + row * metrics.height + dy
            let offset = y * image.bytesPerRow + x * 4
            return (Int(pixels[offset + 2]), Int(pixels[offset + 1]), Int(pixels[offset]))
        }
        // The cell corner, where no glyph reaches: only the background shows.
        XCTAssertEqual(color(column: 0, row: 0).0, 220, accuracy: 2, "red background cell")
        XCTAssertEqual(color(column: 30, row: 6).2, 20, accuracy: 2, "theme background below the text")
        // ` blue ` starts at column 12 of row 2.
        XCTAssertEqual(color(column: 13, row: 2).2, 220, accuracy: 2, "palette blue background")
        // The block cursor sits after `$ ` on row 4, drawn in the foreground.
        XCTAssertEqual(color(column: 2, row: 4).0, 230, accuracy: 2, "block cursor")
    }

    private func builtFrame(
        _ terminal: TermiodStreamTerminal, _ builder: TermiodStreamFrameBuilder,
        _ state: GhosttyRenderState, _ atlas: TermiodGlyphAtlas
    ) throws -> (changed: Bool, rectangles: [TermiodStreamRectangle], glyphs: [TermiodStreamGlyph]) {
        _ = try terminal.capture(into: state)
        let changed = try builder.build(from: state, atlas: atlas, cursorStyle: .block)
        var rectangles: [TermiodStreamRectangle] = []
        var glyphs: [TermiodStreamGlyph] = []
        builder.flatten(rectangles: &rectangles, glyphs: &glyphs)
        return (changed, rectangles, glyphs)
    }

    private func renderState() throws -> GhosttyRenderState {
        var state: GhosttyRenderState?
        XCTAssertEqual(ghostty_render_state_new(nil, &state), GHOSTTY_SUCCESS)
        return try XCTUnwrap(state)
    }

    /// Moving the cursor dirties no cell, and a frame must still follow it;
    /// hiding a block cursor gives the character under it its own color back.
    func testTheCursorRedrawsOnItsOwnAndLeavesNoTrace() throws {
        let terminal = try terminal()
        try terminal.setColors(colors())
        let renderer = try TermiodStreamRenderer(appearance: appearance, scale: 2)
        let builder = try TermiodStreamFrameBuilder()
        let state = try renderState()
        defer { ghostty_render_state_free(state) }
        terminal.write(Data("X".utf8))
        XCTAssertTrue(try builtFrame(terminal, builder, state, renderer.atlas).changed)
        XCTAssertFalse(try builtFrame(terminal, builder, state, renderer.atlas).changed, "nothing changed")

        terminal.write(Data("\u{1b}[D".utf8))
        let onX = try builtFrame(terminal, builder, state, renderer.atlas)
        XCTAssertTrue(onX.changed, "a cursor move alone is a new frame")
        let covered = try XCTUnwrap(onX.glyphs.first { $0.cellX == 0 && $0.cellY == 0 })
        XCTAssertEqual(covered.r, 20, "text under the block cursor takes the background color")

        terminal.write(Data("\u{1b}[?25l".utf8))
        let hidden = try builtFrame(terminal, builder, state, renderer.atlas)
        XCTAssertTrue(hidden.changed)
        let shown = try XCTUnwrap(hidden.glyphs.first { $0.cellX == 0 && $0.cellY == 0 })
        XCTAssertEqual(shown.r, 230, "with the cursor hidden the character is drawn in the foreground")
    }

    /// Mode 2026: nothing is captured while the program holds the screen, and
    /// a hold past the limit is ended for it.
    func testSynchronizedOutputHoldsTheFrameUntilItEnds() throws {
        let terminal = try terminal()
        let state = try renderState()
        defer { ghostty_render_state_free(state) }
        XCTAssertTrue(try terminal.capture(into: state))
        terminal.write(Data("\u{1b}[?2026hhalf a frame".utf8))
        XCTAssertFalse(try terminal.capture(into: state), "held")
        terminal.write(Data("\u{1b}[?2026l".utf8))
        XCTAssertTrue(try terminal.capture(into: state), "released by the program")

        terminal.write(Data("\u{1b}[?2026h".utf8))
        XCTAssertFalse(try terminal.capture(into: state))
        Thread.sleep(forTimeInterval: 1.1)
        XCTAssertTrue(try terminal.capture(into: state), "a hold past the limit is ended")
    }

    /// A full atlas starts over instead of drawing nothing new.
    func testAFullAtlasMakesRoomForNewGlyphs() throws {
        let renderer = try TermiodStreamRenderer(appearance: appearance, scale: 2)
        let atlas = try TermiodGlyphAtlas(device: renderer.device, appearance: appearance, scale: 2, size: 128)
        for codepoint in UInt32(0x4E00)..<UInt32(0x4E00 + 200) {
            XCTAssertNotNil(atlas.slot(graphemes: [codepoint], bold: false, italic: false, cells: 2),
                            "U+\(String(codepoint, radix: 16)) was not drawn")
        }
        XCTAssertGreaterThan(atlas.generation, 0, "the atlas filled and was emptied")
    }
}
