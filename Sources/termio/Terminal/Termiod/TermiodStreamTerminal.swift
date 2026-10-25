import Foundation
import GhosttyVt
import os

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
/// Two threads use it: the link's reader writes bytes and applies markers, and
/// the renderer copies the screen out once a frame. One lock covers both, held
/// by the renderer only for `ghostty_render_state_begin_update`.
final class TermiodStreamTerminal: @unchecked Sendable {
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
    /// The screen as the renderer last copied it. Owned here, not by the
    /// renderer, because synchronized output has to be copied on the writing
    /// thread at the byte its hold begins; it is only ever touched under `lock`.
    private let renderState: GhosttyRenderState
    private let lock = NSLock()
    /// Raised by the renderer before it asks for `lock`. NSLock is not fair, and
    /// a reader writing chunk after chunk re-takes it before a waiting renderer
    /// wakes: the phase 1 spike measured frames starved for up to 34 ms.
    private let rendererWaiting = OSAllocatedUnfairLock(initialState: false)
    /// What the terminal answers a program's query with — a cursor position
    /// report, a mode report. Called on the writing thread, inside `write`.
    private let onReply: (Data) -> Void
    /// When the program began synchronized output (mode 2026), set by the
    /// render-hold callback under `lock`. Nil while nothing is held.
    private var heldSince: ContinuousClock.Instant?
    /// How long a program may hold the screen before the hold is ended for
    /// it, as libghostty's own example does.
    static let holdLimit: Duration = .seconds(1)

    /// Decodes the daemon's native snapshot (`S` format 4) into a new terminal.
    /// An attach always builds a fresh one: nothing the previous terminal held
    /// may survive into the new stream.
    init(nativeSnapshot: Data, onReply: @escaping (Data) -> Void = { _ in }) throws {
        terminal = try nativeSnapshot.withUnsafeBytes { buffer in
            try Self.decode(buffer.bindMemory(to: UInt8.self))
        }
        var state: GhosttyRenderState?
        guard ghostty_render_state_new(nil, &state) == GHOSTTY_SUCCESS, let state else {
            ghostty_terminal_free(terminal)
            throw Failure.engine("ghostty_render_state_new", GHOSTTY_OUT_OF_MEMORY)
        }
        renderState = state
        self.onReply = onReply
        let userdata = Unmanaged.passUnretained(self).toOpaque()
        try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, userdata), "ghostty_terminal_set(userdata)")
        let reply: GhosttyTerminalWritePtyFn = { _, userdata, bytes, count in
            guard let userdata, let bytes, count > 0 else { return }
            let owner = Unmanaged<TermiodStreamTerminal>.fromOpaque(userdata).takeUnretainedValue()
            owner.onReply(Data(bytes: bytes, count: count))
        }
        try Self.check(
            ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, unsafeBitCast(reply, to: UnsafeRawPointer.self)),
            "ghostty_terminal_set(write_pty)"
        )
        // Called inside `vt_write` or `resize`, so `lock` is already held. At
        // the start of a hold the terminal holds exactly the frame the program
        // wants on screen, and nothing after it has been parsed yet: that is
        // the moment to copy it (render.h, "synchronized output").
        let hold: GhosttyTerminalRenderHoldFn = { terminal, userdata, held in
            guard let userdata else { return }
            let owner = Unmanaged<TermiodStreamTerminal>.fromOpaque(userdata).takeUnretainedValue()
            if held {
                _ = ghostty_render_state_update(owner.renderState, terminal)
                owner.heldSince = ContinuousClock.now
            } else {
                owner.heldSince = nil
            }
        }
        try Self.check(
            ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_RENDER_HOLD, unsafeBitCast(hold, to: UnsafeRawPointer.self)),
            "ghostty_terminal_set(render_hold)"
        )
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
        ghostty_render_state_free(renderState)
    }

    func write(_ bytes: Data) {
        locked { writeLocked(bytes) }
        while rendererWaiting.withLock({ $0 }) { sched_yield() }
    }

    private func writeLocked(_ bytes: Data) {
        bytes.withUnsafeBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            guard let base = bytes.baseAddress else { return }
            ghostty_terminal_vt_write(terminal, base, bytes.count)
        }
    }

    /// The theme: libghostty resolves "default foreground" and palette indices
    /// against these, so a session drawn by two Macs follows each one's theme.
    /// A decoded snapshot carries none of the daemon's, which never sets any.
    func setColors(_ colors: Colors) throws {
        try locked {
            var foreground = colors.foreground
            var background = colors.background
            var palette = colors.palette
            try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &foreground), "ghostty_terminal_set(foreground)")
            try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &background), "ghostty_terminal_set(background)")
            if var cursor = colors.cursor {
                try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &cursor), "ghostty_terminal_set(cursor)")
            } else {
                try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, nil), "ghostty_terminal_set(cursor)")
            }
            try palette.withUnsafeMutableBufferPointer { buffer in
                try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, buffer.baseAddress), "ghostty_terminal_set(palette)")
            }
        }
    }

    struct Colors: Equatable {
        static func == (left: Colors, right: Colors) -> Bool {
            func same(_ a: GhosttyColorRgb, _ b: GhosttyColorRgb) -> Bool { a.r == b.r && a.g == b.g && a.b == b.b }
            return same(left.foreground, right.foreground) && same(left.background, right.background)
                && left.cursor.map { cursor in right.cursor.map { same(cursor, $0) } ?? false } ?? (right.cursor == nil)
                && left.palette.count == right.palette.count
                && zip(left.palette, right.palette).allSatisfy(same)
        }

        var foreground: GhosttyColorRgb
        var background: GhosttyColorRgb
        var cursor: GhosttyColorRgb?
        /// Exactly 256 entries.
        var palette: [GhosttyColorRgb]
    }

    /// Runs `body` with the screen's render state, under the terminal lock so
    /// the writing thread cannot copy into it meanwhile.
    ///
    /// The state is refreshed first, unless the program holds synchronized
    /// output (mode 2026): then it keeps the frame copied when the hold began,
    /// and a program that redraws hold after hold shows each finished frame in
    /// turn. A hold longer than `holdLimit` is ended for the program.
    func withFrame<Result>(_ body: (GhosttyRenderState) throws -> Result) throws -> Result {
        rendererWaiting.withLock { $0 = true }
        lock.lock()
        rendererWaiting.withLock { $0 = false }
        defer { lock.unlock() }
        if let since = heldSince, ContinuousClock.now - since >= Self.holdLimit {
            // Setting the mode directly never invokes the callback.
            var mode = GhosttyTerminalModeConfig(mode: ghostty_mode_new(2026, false), value: false)
            _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_MODE, &mode)
            heldSince = nil
        }
        if heldSince == nil {
            try Self.check(ghostty_render_state_update(renderState, terminal), "ghostty_render_state_update")
        }
        return try body(renderState)
    }

    private func locked<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Applies an `E vt_resize` marker: the same operation the daemon's sidecar
    /// applied at this byte (`SidecarCommand::Resize` in `termiod/src/session.rs`).
    /// `reflow` is set when no shell held the terminal, and the screen rewraps;
    /// otherwise this is `resize_for_shell`.
    func resize(rows: UInt16, cols: UInt16, reflow: Bool) throws {
        try locked {
            if reflow {
                try resizeReflowing(rows: rows, cols: cols)
            } else {
                try resizeForShell(rows: rows, cols: cols)
            }
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
        try locked { try screenLocked() }
    }

    private func screenLocked() throws -> Screen {
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
        writeLocked(Data("\u{1b}7\u{1b}[\(UInt32(promptRow) + 1);1H\u{1b}[J\u{1b}8".utf8))
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
