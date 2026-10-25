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
    /// The theme last set, under `lock`; the renderer reads the parts of it
    /// libghostty does not hold (cursor text, the contrast floor).
    private var theme: Theme?
    /// How long a program may hold the screen before the hold is ended for
    /// it, as libghostty's own example does.
    static let holdLimit: Duration = .seconds(1)
    /// libghostty's input encoders, reused for every event and used only under
    /// `lock`: they read the terminal's modes at the moment of encoding.
    private let keyEncoder: GhosttyKeyEncoder
    private let keyEvent: GhosttyKeyEvent
    private let mouseEncoder: GhosttyMouseEncoder
    private let mouseEvent: GhosttyMouseEvent

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
        var keyEncoder: GhosttyKeyEncoder?
        var keyEvent: GhosttyKeyEvent?
        var mouseEncoder: GhosttyMouseEncoder?
        var mouseEvent: GhosttyMouseEvent?
        _ = ghostty_key_encoder_new(nil, &keyEncoder)
        _ = ghostty_key_event_new(nil, &keyEvent)
        _ = ghostty_mouse_encoder_new(nil, &mouseEncoder)
        _ = ghostty_mouse_event_new(nil, &mouseEvent)
        guard let keyEncoder, let keyEvent, let mouseEncoder, let mouseEvent else {
            ghostty_key_encoder_free(keyEncoder)
            ghostty_key_event_free(keyEvent)
            ghostty_mouse_encoder_free(mouseEncoder)
            ghostty_mouse_event_free(mouseEvent)
            ghostty_render_state_free(state)
            ghostty_terminal_free(terminal)
            throw Failure.engine("input encoders", GHOSTTY_OUT_OF_MEMORY)
        }
        self.keyEncoder = keyEncoder
        self.keyEvent = keyEvent
        self.mouseEncoder = mouseEncoder
        self.mouseEvent = mouseEvent
        var trackLastCell = true
        ghostty_mouse_encoder_setopt(mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL, &trackLastCell)
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
        // A snapshot taken mid-hold restores mode 2026 without a callback, and
        // a repeated begin raises none: start held, on the frame decoded.
        if try mode(ghostty_mode_new(2026, false)) {
            try Self.check(ghostty_render_state_update(renderState, terminal), "ghostty_render_state_update")
            heldSince = ContinuousClock.now
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
        ghostty_key_encoder_free(keyEncoder)
        ghostty_key_event_free(keyEvent)
        ghostty_mouse_encoder_free(mouseEncoder)
        ghostty_mouse_event_free(mouseEvent)
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
    func setTheme(_ colors: Theme) throws {
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
            // The default a program's DECSCUSR 0 returns to — and what a cursor
            // nobody styled shows. One the program chose explicitly keeps its
            // own shape: the terminal tells the two apart even after a decode.
            //
            // Setting either default also rewrites the blink mode, so each is
            // set only when its setting changes, as Ghostty does on a config
            // change. On the first theme a decoded screen that already blinks
            // keeps blinking — the daemon's own default is off, so that blink
            // is the program's. One a program turned off cannot be told from
            // that default, and takes the setting.
            let programBlinks = theme == nil ? try mode(ghostty_mode_new(12, false)) : false
            if theme?.cursorStyle != colors.cursorStyle {
                var cursorStyle = colors.cursorStyle
                try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_STYLE, &cursorStyle), "ghostty_terminal_set(default cursor)")
            }
            if theme?.cursorBlink != colors.cursorBlink {
                var cursorBlink = colors.cursorBlink
                try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK, &cursorBlink), "ghostty_terminal_set(default blink)")
            }
            if programBlinks {
                var mode = GhosttyTerminalModeConfig(mode: ghostty_mode_new(12, false), value: true)
                try Self.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_MODE, &mode), "ghostty_terminal_set(blink mode)")
            }
            theme = colors
        }
    }

    struct Theme: Equatable {
        static func == (left: Theme, right: Theme) -> Bool {
            func same(_ a: GhosttyColorRgb, _ b: GhosttyColorRgb) -> Bool { a.r == b.r && a.g == b.g && a.b == b.b }
            return left.cursorStyle == right.cursorStyle && left.cursorBlink == right.cursorBlink
                && left.minimumContrast == right.minimumContrast
                && left.cursorText.map { text in right.cursorText.map { same(text, $0) } ?? false } ?? (right.cursorText == nil)
                && same(left.foreground, right.foreground) && same(left.background, right.background)
                && left.cursor.map { cursor in right.cursor.map { same(cursor, $0) } ?? false } ?? (right.cursor == nil)
                && left.palette.count == right.palette.count
                && zip(left.palette, right.palette).allSatisfy(same)
        }

        var foreground: GhosttyColorRgb
        var background: GhosttyColorRgb
        var cursor: GhosttyColorRgb?
        /// Exactly 256 entries.
        var palette: [GhosttyColorRgb]
        /// The cursor settings, as the defaults a program's DECSCUSR can override.
        var cursorStyle: GhosttyTerminalCursorStyle
        var cursorBlink: Bool
        /// The color of a character under a block cursor; nil is the background.
        var cursorText: GhosttyColorRgb? = nil
        /// The WCAG ratio a glyph keeps against its own background, 1 for none.
        var minimumContrast: Double = 1
    }

    /// Runs `body` with the screen's render state, under the terminal lock so
    /// the writing thread cannot copy into it meanwhile.
    ///
    /// The state is refreshed first, unless the program holds synchronized
    /// output (mode 2026): then it keeps the frame copied when the hold began,
    /// and a program that redraws hold after hold shows each finished frame in
    /// turn. A hold longer than `holdLimit` is ended for the program.
    func withFrame<Result>(_ body: (GhosttyRenderState, Theme?) throws -> Result) throws -> Result {
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
        return try body(renderState, theme)
    }

    private func locked<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// One key event, in libghostty's terms. `text` is what the keyboard layout
    /// typed, never a control character or a function key's private-use code:
    /// the encoder derives those from `key` and `mods` itself.
    struct KeyInput: Equatable {
        var action: GhosttyKeyAction = GHOSTTY_KEY_ACTION_PRESS
        var key: GhosttyKey
        var mods: GhosttyMods = 0
        var consumedMods: GhosttyMods = 0
        var text: String?
        var unshiftedCodepoint: UInt32 = 0
        var composing = false
    }

    /// The bytes a key sends to the program, against the modes it negotiated
    /// now: cursor and keypad application mode, the Kitty keyboard flags,
    /// modifyOtherKeys. Empty when the key sends nothing, as a release does
    /// outside Kitty's event reporting.
    func encode(_ input: KeyInput) -> Data {
        locked {
            let bytes = encodeLocked(input)
            if !bytes.isEmpty, input.action != GHOSTTY_KEY_ACTION_RELEASE { scrollToBottomLocked() }
            return bytes
        }
    }

    private func encodeLocked(_ input: KeyInput) -> Data {
        ghostty_key_encoder_setopt_from_terminal(keyEncoder, terminal)
        // Option composes text on a Mac, as the embedded surface leaves it.
        var optionAsAlt = GHOSTTY_OPTION_AS_ALT_FALSE
        ghostty_key_encoder_setopt(keyEncoder, GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, &optionAsAlt)
        ghostty_key_event_set_action(keyEvent, input.action)
        ghostty_key_event_set_key(keyEvent, input.key)
        ghostty_key_event_set_mods(keyEvent, input.mods)
        ghostty_key_event_set_consumed_mods(keyEvent, input.consumedMods)
        ghostty_key_event_set_unshifted_codepoint(keyEvent, input.unshiftedCodepoint)
        ghostty_key_event_set_composing(keyEvent, input.composing)
        // The event borrows the text, so it is cleared before the bytes go.
        defer { ghostty_key_event_set_utf8(keyEvent, nil, 0) }
        let text = Array((input.text ?? "").utf8)
        return text.withUnsafeBufferPointer { utf8 in
            utf8.withMemoryRebound(to: CChar.self) { utf8 in
                ghostty_key_event_set_utf8(keyEvent, utf8.baseAddress, utf8.count)
                return Self.encoded { buffer, capacity, length in
                    ghostty_key_encoder_encode(keyEncoder, keyEvent, buffer, capacity, length)
                }
            }
        }
    }

    /// One mouse event at a point in the pane, in pixels from its top-left.
    struct MouseInput: Equatable {
        var action: GhosttyMouseAction
        var button: GhosttyMouseButton?
        var mods: GhosttyMods = 0
        var x: Float
        var y: Float
        /// Whether any button is down once this event has happened.
        var anyButtonPressed: Bool
    }

    /// Where the grid sits in the pane, in pixels: the encoders turn a pane
    /// position into a cell with it. The grid is the session's, not the
    /// pane's, so a point past its last column is outside the terminal.
    struct PixelLayout: Equatable {
        var cellWidth: UInt32
        var cellHeight: UInt32
        var paddingLeft: UInt32
        var paddingTop: UInt32
    }

    /// Whether the program asked for mouse reports, in which case clicks and
    /// the wheel are its, not the pane's.
    var tracksMouse: Bool {
        locked {
            var tracking = false
            _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking)
            return tracking
        }
    }

    /// The report a mouse event sends, in the format the program chose. Empty
    /// when it asked for none, or for none of this kind.
    func encode(_ input: MouseInput, layout: PixelLayout) -> Data {
        locked { encodeLocked(input, layout: layout) }
    }

    private func encodeLocked(_ input: MouseInput, layout: PixelLayout) -> Data {
        var rows: UInt16 = 0
        var cols: UInt16 = 0
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ROWS, &rows)
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLS, &cols)
        var size = GhosttyMouseEncoderSize()
        size.size = MemoryLayout<GhosttyMouseEncoderSize>.size
        size.screen_width = UInt32(cols) * layout.cellWidth + layout.paddingLeft
        size.screen_height = UInt32(rows) * layout.cellHeight + layout.paddingTop
        size.cell_width = max(1, layout.cellWidth)
        size.cell_height = max(1, layout.cellHeight)
        size.padding_left = layout.paddingLeft
        size.padding_top = layout.paddingTop
        ghostty_mouse_encoder_setopt_from_terminal(mouseEncoder, terminal)
        ghostty_mouse_encoder_setopt(mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size)
        var pressed = input.anyButtonPressed
        ghostty_mouse_encoder_setopt(mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &pressed)
        ghostty_mouse_event_set_action(mouseEvent, input.action)
        if let button = input.button {
            ghostty_mouse_event_set_button(mouseEvent, button)
        } else {
            ghostty_mouse_event_clear_button(mouseEvent)
        }
        ghostty_mouse_event_set_mods(mouseEvent, input.mods)
        ghostty_mouse_event_set_position(mouseEvent, GhosttyMousePosition(x: input.x, y: input.y))
        return Self.encoded { buffer, capacity, length in
            ghostty_mouse_encoder_encode(mouseEncoder, mouseEvent, buffer, capacity, length)
        }
    }

    /// A wheel turned by `rows` (negative is up), the way Ghostty routes it: a
    /// program tracking the mouse gets wheel buttons; one on the alternate
    /// screen with alternate scroll (mode 1007) gets arrow keys; otherwise the
    /// view moves through scrollback, and nothing is sent.
    func scroll(rows: Int, at input: MouseInput, layout: PixelLayout) -> Data {
        guard rows != 0 else { return Data() }
        return locked {
            var tracking = false
            _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking)
            var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
            _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)
            var bytes = Data()
            if tracking {
                var wheel = input
                wheel.action = GHOSTTY_MOUSE_ACTION_PRESS
                wheel.button = rows < 0 ? GHOSTTY_MOUSE_BUTTON_FOUR : GHOSTTY_MOUSE_BUTTON_FIVE
                for _ in 0 ..< abs(rows) { bytes += encodeLocked(wheel, layout: layout) }
            } else if screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE,
                      (try? mode(ghostty_mode_new(1007, false))) == true {
                let arrow = KeyInput(key: rows < 0 ? GHOSTTY_KEY_ARROW_UP : GHOSTTY_KEY_ARROW_DOWN)
                for _ in 0 ..< abs(rows) { bytes += encodeLocked(arrow) }
            } else {
                var behavior = GhosttyTerminalScrollViewport()
                behavior.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA
                behavior.value.delta = rows
                ghostty_terminal_scroll_viewport(terminal, behavior)
            }
            return bytes
        }
    }

    /// Pasted text as the program should receive it: wrapped when it asked for
    /// bracketed paste (mode 2004), with newlines as returns when it did not,
    /// and with control bytes that could end the paste early replaced.
    func encodePaste(_ text: String) -> Data {
        locked {
            let bracketed = (try? mode(ghostty_mode_new(2004, false))) ?? false
            var input = Array(text.utf8).map { CChar(bitPattern: $0) }
            let bytes = input.withUnsafeMutableBufferPointer { input in
                Self.encoded { buffer, capacity, length in
                    ghostty_paste_encode(input.baseAddress, input.count, bracketed, buffer, capacity, length)
                }
            }
            if !bytes.isEmpty { scrollToBottomLocked() }
            return bytes
        }
    }

    /// The focus report, for a program that asked for one (mode 1004).
    func encodeFocus(_ gained: Bool) -> Data {
        locked {
            guard (try? mode(ghostty_mode_new(1004, false))) == true else { return Data() }
            return Self.encoded { buffer, capacity, length in
                ghostty_focus_encode(gained ? GHOSTTY_FOCUS_GAINED : GHOSTTY_FOCUS_LOST, buffer, capacity, length)
            }
        }
    }

    /// The active screen as plain text, one line per row, whatever part of
    /// scrollback the view shows: what `termio sessions read` reports.
    func activeText() throws -> String {
        try locked {
            var rows: UInt16 = 0
            var cols: UInt16 = 0
            try get(GHOSTTY_TERMINAL_DATA_ROWS, &rows)
            try get(GHOSTTY_TERMINAL_DATA_COLS, &cols)
            guard rows > 0, cols > 0 else { return "" }
            func reference(_ x: UInt16, _ y: UInt16) throws -> GhosttyGridRef {
                var point = GhosttyPoint()
                point.tag = GHOSTTY_POINT_TAG_ACTIVE
                point.value.coordinate = GhosttyPointCoordinate(x: x, y: UInt32(y))
                var reference = GhosttyGridRef()
                reference.size = MemoryLayout<GhosttyGridRef>.size
                try Self.check(ghostty_terminal_grid_ref(terminal, point, &reference), "ghostty_terminal_grid_ref")
                return reference
            }
            var selection = GhosttySelection()
            selection.size = MemoryLayout<GhosttySelection>.size
            selection.start = try reference(0, 0)
            selection.end = try reference(cols - 1, rows - 1)
            return try withUnsafePointer(to: &selection) { selection in
                var options = GhosttyFormatterTerminalOptions()
                options.size = MemoryLayout<GhosttyFormatterTerminalOptions>.size
                options.extra.size = MemoryLayout<GhosttyFormatterTerminalExtra>.size
                options.extra.screen.size = MemoryLayout<GhosttyFormatterScreenExtra>.size
                options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
                options.unwrap = false
                options.trim = true
                options.selection = selection
                return String(decoding: try format(options), as: UTF8.self)
            }
        }
    }

    /// Back to the live screen, as a keystroke does in Ghostty.
    func scrollToBottom() {
        locked { scrollToBottomLocked() }
    }

    /// The cursor's cell on the active screen.
    var cursorPosition: (x: UInt16, y: UInt16)? {
        locked {
            var x: UInt16 = 0
            var y: UInt16 = 0
            guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_X, &x) == GHOSTTY_SUCCESS,
                  ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &y) == GHOSTTY_SUCCESS
            else { return nil }
            return (x, y)
        }
    }

    private func scrollToBottomLocked() {
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM
        ghostty_terminal_scroll_viewport(terminal, behavior)
    }

    /// Runs an encoder that writes into a buffer and reports the length it
    /// needed when the buffer was too small, as all of libghostty's do.
    private static func encoded(
        _ encode: (UnsafeMutablePointer<CChar>?, Int, UnsafeMutablePointer<Int>) -> GhosttyResult
    ) -> Data {
        var capacity = 128
        while true {
            var buffer = [CChar](repeating: 0, count: capacity)
            var length = 0
            let result = buffer.withUnsafeMutableBufferPointer { encode($0.baseAddress, capacity, &length) }
            switch result {
            case GHOSTTY_SUCCESS:
                return Data(buffer.prefix(length).map { UInt8(bitPattern: $0) })
            case GHOSTTY_OUT_OF_SPACE where length > capacity:
                capacity = length
            default:
                Log.termiod.error("stream input encoding failed: \(result.rawValue, privacy: .public)")
                return Data()
            }
        }
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
        return try format(options)
    }

    private func format(_ options: GhosttyFormatterTerminalOptions) throws -> Data {
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
