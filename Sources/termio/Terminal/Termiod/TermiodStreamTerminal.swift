import Foundation
import GhosttyVt

/// The client's own copy of a session's screen on the `vt_stream` plane: a
/// libghostty-vt terminal that follows the daemon's byte for byte.
///
/// It is built only from the daemon's native snapshot and changed only by what
/// follows it on the wire — `D` bytes and `E vt_resize` markers, applied in the
/// order they arrived. Nothing else resizes it: a view that is larger or smaller
/// than the session draws it clipped or with room to spare, and says how much it
/// could hold through the viewport declaration instead. That is the whole design
/// (docs/design/20261024-client-vt-follows-the-stream.md): the daemon placed the
/// marker where its own VT changed size, so applying the same operation at the
/// same byte leaves both screens identical, with no keyframe to wait for.
///
/// Confined to the one thread that reads the stream.
final class TermiodStreamTerminal {
    enum Failure: Error, Equatable {
        case engine(String, GhosttyResult)
    }

    /// The cell metrics termiod's sidecar resizes with (`resize_reflowing` in
    /// `termiod/vt/src/lib.rs`). The grid does not depend on them, but pixel
    /// sizes reach size reports and image placement, so both ends use one pair.
    static let cellWidth: UInt32 = 8
    static let cellHeight: UInt32 = 16
    /// The decoder's cap on unfinished input carried in a snapshot, matching
    /// the daemon's `CONTINUATION_LIMIT`. A snapshot taken mid-sequence carries
    /// the partial sequence; a larger one than this is refused, not truncated.
    static let continuationLimit = 1 << 20

    private let terminal: GhosttyTerminal

    /// Decodes the daemon's native snapshot (`S` format 4) into a new terminal.
    /// An attach always builds a fresh one: nothing the previous terminal held
    /// may survive into the new stream.
    init(nativeSnapshot: Data) throws {
        terminal = try nativeSnapshot.withUnsafeBytes { buffer in
            try Self.decode(buffer.bindMemory(to: UInt8.self))
        }
    }

    /// The decoder borrows `bytes` until it is freed, so everything from its
    /// creation to its release stays inside the caller's `withUnsafeBytes`.
    private static func decode(_ bytes: UnsafeBufferPointer<UInt8>) throws -> GhosttyTerminal {
        var decoder: GhosttySnapshotDecoder?
        try check(
            ghostty_snapshot_decoder_new_buf(nil, &decoder, bytes.baseAddress, bytes.count),
            "ghostty_snapshot_decoder_new_buf"
        )
        guard let decoder else {
            throw Failure.engine("ghostty_snapshot_decoder_new_buf", GHOSTTY_INVALID_VALUE)
        }
        defer { ghostty_snapshot_decoder_free(decoder) }
        var limit = continuationLimit
        try check(
            ghostty_snapshot_decoder_set(decoder, GHOSTTY_SNAPSHOT_DECODER_OPT_MAX_CONTINUATION_BYTES, &limit),
            "ghostty_snapshot_decoder_set(max continuation)"
        )
        var decoded: GhosttyTerminal?
        try check(ghostty_snapshot_decoder_decode(decoder, &decoded), "ghostty_snapshot_decoder_decode")
        guard let decoded else {
            throw Failure.engine("ghostty_snapshot_decoder_decode", GHOSTTY_INVALID_VALUE)
        }
        return decoded
    }

    deinit {
        ghostty_terminal_free(terminal)
    }

    func write(_ bytes: Data) {
        bytes.withUnsafeBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            guard let base = bytes.baseAddress else { return }
            ghostty_terminal_vt_write(terminal, base, bytes.count)
        }
    }

    /// Applies an `E vt_resize` marker: the same operation the daemon's sidecar
    /// applied at this byte (`SidecarCommand::Resize` in `termiod/src/session.rs`).
    /// `reflow` is set when no shell held the terminal, and the screen rewraps;
    /// otherwise this is `resize_for_shell`.
    func resize(rows: UInt16, cols: UInt16, reflow: Bool) throws {
        if reflow {
            try resizeReflowing(rows: rows, cols: cols)
        } else {
            try resizeForShell(rows: rows, cols: cols)
        }
    }

    /// What the terminal holds, in a form two engines can be compared by: the
    /// grid and its pixel size, the cursor, the active screen, and the screen
    /// serialised as VT with styles, modes, charsets and keyboard state. The
    /// parity test reads it against what termiod's VT recorded.
    struct Screen: Equatable {
        var rows: UInt16
        var cols: UInt16
        var widthPixels: UInt32
        var heightPixels: UInt32
        var cursorX: UInt16
        var cursorY: UInt16
        var alternate: Bool
        var vt: Data
    }

    func screen() throws -> Screen {
        var rows: UInt16 = 0
        var cols: UInt16 = 0
        var widthPixels: UInt32 = 0
        var heightPixels: UInt32 = 0
        var cursorX: UInt16 = 0
        var cursorY: UInt16 = 0
        var active = GHOSTTY_TERMINAL_SCREEN_PRIMARY
        try get(GHOSTTY_TERMINAL_DATA_ROWS, &rows)
        try get(GHOSTTY_TERMINAL_DATA_COLS, &cols)
        try get(GHOSTTY_TERMINAL_DATA_WIDTH_PX, &widthPixels)
        try get(GHOSTTY_TERMINAL_DATA_HEIGHT_PX, &heightPixels)
        try get(GHOSTTY_TERMINAL_DATA_CURSOR_X, &cursorX)
        try get(GHOSTTY_TERMINAL_DATA_CURSOR_Y, &cursorY)
        try get(GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &active)
        return Screen(
            rows: rows, cols: cols, widthPixels: widthPixels, heightPixels: heightPixels,
            cursorX: cursorX, cursorY: cursorY,
            alternate: active == GHOSTTY_TERMINAL_SCREEN_ALTERNATE, vt: try formattedVT()
        )
    }

    /// The options `VtTerminal::format_vt` formats with, so the two engines'
    /// output can be compared byte for byte.
    private func formattedVT() throws -> Data {
        var options = GhosttyFormatterTerminalOptions()
        options.size = MemoryLayout<GhosttyFormatterTerminalOptions>.size
        options.extra.size = MemoryLayout<GhosttyFormatterTerminalExtra>.size
        options.extra.screen.size = MemoryLayout<GhosttyFormatterScreenExtra>.size
        options.emit = GHOSTTY_FORMATTER_FORMAT_VT
        options.unwrap = false
        options.trim = false
        options.extra.palette = false
        options.extra.modes = true
        options.extra.scrolling_region = true
        options.extra.tabstops = false
        options.extra.pwd = true
        options.extra.keyboard = true
        options.extra.screen.cursor = true
        options.extra.screen.style = true
        options.extra.screen.hyperlink = true
        options.extra.screen.protection = true
        options.extra.screen.kitty_keyboard = true
        options.extra.screen.charsets = true
        var formatter: GhosttyFormatter?
        try Self.check(ghostty_formatter_terminal_new(nil, &formatter, terminal, options), "ghostty_formatter_terminal_new")
        guard let formatter else {
            throw Failure.engine("ghostty_formatter_terminal_new", GHOSTTY_INVALID_VALUE)
        }
        defer { ghostty_formatter_free(formatter) }
        // A blank screen formats to nothing, which the allocating call reports
        // as an error, so this sizes first and writes into a buffer.
        var length = 0
        let sizing = ghostty_formatter_format_buf(formatter, nil, 0, &length)
        guard sizing != GHOSTTY_SUCCESS else { return Data() }
        guard sizing == GHOSTTY_OUT_OF_SPACE else {
            throw Failure.engine("ghostty_formatter_format_buf(size)", sizing)
        }
        var text = Data(count: length)
        var written = 0
        let result = text.withUnsafeMutableBytes { buffer in
            ghostty_formatter_format_buf(
                formatter, buffer.bindMemory(to: UInt8.self).baseAddress, length, &written
            )
        }
        try Self.check(result, "ghostty_formatter_format_buf")
        return text.prefix(written)
    }

    /// A port of `VtTerminal::resize_for_shell`, which documents why: with
    /// OSC 133 marks, blank the prompt the cursor sits in and then reflow, so
    /// the shell's SIGWINCH redraw lands on clean rows; without them, resize
    /// without reflowing, the way the shell's redraw arithmetic assumes.
    private func resizeForShell(rows: UInt16, cols: UInt16) throws {
        guard let promptRow = try currentPromptStart() else {
            try resizeTruncating(rows: rows, cols: cols)
            return
        }
        write(Data("\u{1b}7\u{1b}[\(UInt32(promptRow) + 1);1H\u{1b}[J\u{1b}8".utf8))
        try resizeReflowing(rows: rows, cols: cols)
    }

    /// `VtTerminal::resize`: libghostty reflows only while wraparound is on, so
    /// turning it off for the resize is what truncates.
    private func resizeTruncating(rows: UInt16, cols: UInt16) throws {
        let wraparound = try mode(GHOSTTY_MODE_WRAPAROUND_VALUE)
        if wraparound {
            try setMode(GHOSTTY_MODE_WRAPAROUND_VALUE, false)
        }
        let resized = Result { try resizeReflowing(rows: rows, cols: cols) }
        if wraparound {
            // Restored even when the resize failed: the mode is the program's.
            try setMode(GHOSTTY_MODE_WRAPAROUND_VALUE, true)
        }
        try resized.get()
    }

    private func resizeReflowing(rows: UInt16, cols: UInt16) throws {
        try Self.check(
            ghostty_terminal_resize(terminal, cols, rows, Self.cellWidth, Self.cellHeight),
            "ghostty_terminal_resize"
        )
    }

    /// `VtTerminal::current_prompt_start`: the first row of the prompt the
    /// cursor is in, or nil whenever the marks do not say so for certain.
    private func currentPromptStart() throws -> UInt16? {
        var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
        try get(GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)
        guard screen == GHOSTTY_TERMINAL_SCREEN_PRIMARY else { return nil }
        var row: UInt16 = 0
        try get(GHOSTTY_TERMINAL_DATA_CURSOR_Y, &row)
        while true {
            switch try semanticPrompt(row: row) {
            case GHOSTTY_ROW_SEMANTIC_PROMPT:
                return row
            case GHOSTTY_ROW_SEMANTIC_PROMPT_CONTINUATION where row > 0:
                row -= 1
            default:
                return nil
            }
        }
    }

    private func semanticPrompt(row: UInt16) throws -> GhosttyRowSemanticPrompt {
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_ACTIVE
        point.value.coordinate = GhosttyPointCoordinate(x: 0, y: UInt32(row))
        var reference = GhosttyGridRef()
        reference.size = MemoryLayout<GhosttyGridRef>.size
        try Self.check(ghostty_terminal_grid_ref(terminal, point, &reference), "ghostty_terminal_grid_ref")
        var gridRow: GhosttyRow = 0
        try Self.check(ghostty_grid_ref_row(&reference, &gridRow), "ghostty_grid_ref_row")
        var prompt = GHOSTTY_ROW_SEMANTIC_NONE
        try Self.check(ghostty_row_get(gridRow, GHOSTTY_ROW_DATA_SEMANTIC_PROMPT, &prompt), "ghostty_row_get")
        return prompt
    }

    private func mode(_ mode: GhosttyMode) throws -> Bool {
        var config = GhosttyTerminalModeConfig(mode: mode, value: false)
        try get(GHOSTTY_TERMINAL_DATA_MODE, &config)
        return config.value
    }

    private func setMode(_ mode: GhosttyMode, _ value: Bool) throws {
        var config = GhosttyTerminalModeConfig(mode: mode, value: value)
        try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_MODE, &config), "ghostty_terminal_set(mode)")
    }

    private func get<Value>(_ data: GhosttyTerminalData, _ value: inout Value) throws {
        try Self.check(ghostty_terminal_get(terminal, data, &value), "ghostty_terminal_get")
    }

    private static func check(_ result: GhosttyResult, _ call: String) throws {
        guard result == GHOSTTY_SUCCESS else { throw Failure.engine(call, result) }
    }
}

/// `GHOSTTY_MODE_WRAPAROUND` is a function-like macro, which Swift does not import.
private let GHOSTTY_MODE_WRAPAROUND_VALUE = ghostty_mode_new(7, false)
