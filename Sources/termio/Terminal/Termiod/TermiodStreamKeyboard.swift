import AppKit
import Carbon.HIToolbox
import GhosttyVt

/// How a Mac keystroke becomes a libghostty key event for a `vt_stream`
/// session: the physical key, the modifiers with their sides, and the text the
/// layout typed. Kept to what Ghostty's own AppKit view does, so the program
/// in the terminal cannot tell the stream view from the embedded surface.
enum TermiodStreamKeyboard {
    /// The physical key a macOS virtual keycode names, from Ghostty's own
    /// table (`src/input/keycodes.zig`, the Mac column).
    static func key(forKeycode keycode: UInt16) -> GhosttyKey {
        keys[keycode] ?? GHOSTTY_KEY_UNIDENTIFIED
    }

    /// The modifiers held, with the side of each when it is the right one.
    static func mods(_ flags: NSEvent.ModifierFlags) -> GhosttyMods {
        var mods: GhosttyMods = 0
        let raw = flags.rawValue
        if flags.contains(.shift) { mods |= GhosttyMods(GHOSTTY_MODS_SHIFT) }
        if flags.contains(.control) { mods |= GhosttyMods(GHOSTTY_MODS_CTRL) }
        if flags.contains(.option) { mods |= GhosttyMods(GHOSTTY_MODS_ALT) }
        if flags.contains(.command) { mods |= GhosttyMods(GHOSTTY_MODS_SUPER) }
        if flags.contains(.capsLock) { mods |= GhosttyMods(GHOSTTY_MODS_CAPS_LOCK) }
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GhosttyMods(GHOSTTY_MODS_SHIFT_SIDE) }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GhosttyMods(GHOSTTY_MODS_CTRL_SIDE) }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GhosttyMods(GHOSTTY_MODS_ALT_SIDE) }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GhosttyMods(GHOSTTY_MODS_SUPER_SIDE) }
        return mods
    }

    /// The key event for `event`. `text` is what the layout or the input
    /// method produced; nil leaves the bytes to the key and its modifiers.
    static func input(
        for event: NSEvent, action: GhosttyKeyAction, text: String?, composing: Bool = false
    ) -> TermiodStreamTerminal.KeyInput {
        // Ghostty's split: modifiers the layout spent producing the text are
        // consumed, except Control and Command, which stay the key's own.
        var consumed = event.modifierFlags
        consumed.remove(.control)
        consumed.remove(.command)
        var unshifted: UInt32 = 0
        if event.type == .keyDown || event.type == .keyUp,
           let scalar = event.characters(byApplyingModifiers: [])?.unicodeScalars.first {
            unshifted = scalar.value
        }
        return TermiodStreamTerminal.KeyInput(
            action: action, key: key(forKeycode: event.keyCode), mods: mods(event.modifierFlags),
            consumedMods: mods(consumed), text: text.flatMap(typedText), unshiftedCodepoint: unshifted,
            composing: composing
        )
    }

    /// The text a key event typed, or nil when it typed none the encoder may
    /// take: libghostty derives control characters and function keys from
    /// the key itself and must not be handed either.
    static func typedText(of event: NSEvent) -> String? {
        guard let characters = event.characters, let text = typedText(characters) else {
            // Control turned the character into a control code; what the key
            // types without it is what the encoder wants.
            guard event.modifierFlags.contains(.control) else { return nil }
            var flags = event.modifierFlags
            flags.remove(.control)
            return event.characters(byApplyingModifiers: flags).flatMap(typedText)
        }
        return text
    }

    private static func typedText(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        if text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first,
           scalar.value < 0x20 || scalar.value == 0x7F || (0xF700 ... 0xF8FF).contains(scalar.value) {
            return nil
        }
        return text
    }

    /// Ghostty's "natural text editing" defaults on macOS (`Config.zig`), which
    /// send legacy bytes whatever keyboard protocol the program chose: ⌘← and
    /// ⌘→ to the line's ends, ⌘⌫ to kill it, ⌥← and ⌥→ by word. Nil for every
    /// other key, and for one the app claims for itself.
    @MainActor
    static func naturalEditing(_ event: NSEvent) -> Data? {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let bytes: String?
        switch (flags, Int(event.keyCode)) {
        case (.command, kVK_RightArrow): bytes = "\u{05}"
        case (.command, kVK_LeftArrow): bytes = "\u{01}"
        case (.command, kVK_Delete): bytes = "\u{15}"
        case (.option, kVK_LeftArrow): bytes = "\u{1B}b"
        case (.option, kVK_RightArrow): bytes = "\u{1B}f"
        default: bytes = nil
        }
        guard let bytes else { return nil }
        // The surface unbinds a trigger the app claims, and so does this.
        if let shortcut = Shortcut(event: event),
           KeybindingStore.shared.surfaceUnbindTriggers.contains(shortcut.ghosttyTrigger) {
            return nil
        }
        return Data(bytes.utf8)
    }

    /// A `termio sessions send --key` press and its release, as the embedded
    /// surface's `pressKey` sends them.
    static func inputs(for press: SessionKeyPress) -> [TermiodStreamTerminal.KeyInput] {
        var mods: GhosttyMods = 0
        if press.modifiers.contains(.shift) { mods |= GhosttyMods(GHOSTTY_MODS_SHIFT) }
        if press.modifiers.contains(.control) { mods |= GhosttyMods(GHOSTTY_MODS_CTRL) }
        if press.modifiers.contains(.option) { mods |= GhosttyMods(GHOSTTY_MODS_ALT) }
        if press.modifiers.contains(.command) { mods |= GhosttyMods(GHOSTTY_MODS_SUPER) }
        var input = TermiodStreamTerminal.KeyInput(
            key: key(forKeycode: UInt16(press.keycode)), mods: mods,
            consumedMods: press.text == nil ? 0 : mods & GhosttyMods(GHOSTTY_MODS_SHIFT),
            text: press.text, unshiftedCodepoint: press.unshiftedCodepoint
        )
        var release = input
        release.action = GHOSTTY_KEY_ACTION_RELEASE
        input.action = GHOSTTY_KEY_ACTION_PRESS
        return [input, release]
    }

    private static let keys: [UInt16: GhosttyKey] = [
        0x00: GHOSTTY_KEY_A,
        0x01: GHOSTTY_KEY_S,
        0x02: GHOSTTY_KEY_D,
        0x03: GHOSTTY_KEY_F,
        0x04: GHOSTTY_KEY_H,
        0x05: GHOSTTY_KEY_G,
        0x06: GHOSTTY_KEY_Z,
        0x07: GHOSTTY_KEY_X,
        0x08: GHOSTTY_KEY_C,
        0x09: GHOSTTY_KEY_V,
        0x0A: GHOSTTY_KEY_INTL_BACKSLASH,
        0x0B: GHOSTTY_KEY_B,
        0x0C: GHOSTTY_KEY_Q,
        0x0D: GHOSTTY_KEY_W,
        0x0E: GHOSTTY_KEY_E,
        0x0F: GHOSTTY_KEY_R,
        0x10: GHOSTTY_KEY_Y,
        0x11: GHOSTTY_KEY_T,
        0x12: GHOSTTY_KEY_DIGIT_1,
        0x13: GHOSTTY_KEY_DIGIT_2,
        0x14: GHOSTTY_KEY_DIGIT_3,
        0x15: GHOSTTY_KEY_DIGIT_4,
        0x16: GHOSTTY_KEY_DIGIT_6,
        0x17: GHOSTTY_KEY_DIGIT_5,
        0x18: GHOSTTY_KEY_EQUAL,
        0x19: GHOSTTY_KEY_DIGIT_9,
        0x1A: GHOSTTY_KEY_DIGIT_7,
        0x1B: GHOSTTY_KEY_MINUS,
        0x1C: GHOSTTY_KEY_DIGIT_8,
        0x1D: GHOSTTY_KEY_DIGIT_0,
        0x1E: GHOSTTY_KEY_BRACKET_RIGHT,
        0x1F: GHOSTTY_KEY_O,
        0x20: GHOSTTY_KEY_U,
        0x21: GHOSTTY_KEY_BRACKET_LEFT,
        0x22: GHOSTTY_KEY_I,
        0x23: GHOSTTY_KEY_P,
        0x24: GHOSTTY_KEY_ENTER,
        0x25: GHOSTTY_KEY_L,
        0x26: GHOSTTY_KEY_J,
        0x27: GHOSTTY_KEY_QUOTE,
        0x28: GHOSTTY_KEY_K,
        0x29: GHOSTTY_KEY_SEMICOLON,
        0x2A: GHOSTTY_KEY_BACKSLASH,
        0x2B: GHOSTTY_KEY_COMMA,
        0x2C: GHOSTTY_KEY_SLASH,
        0x2D: GHOSTTY_KEY_N,
        0x2E: GHOSTTY_KEY_M,
        0x2F: GHOSTTY_KEY_PERIOD,
        0x30: GHOSTTY_KEY_TAB,
        0x31: GHOSTTY_KEY_SPACE,
        0x32: GHOSTTY_KEY_BACKQUOTE,
        0x33: GHOSTTY_KEY_BACKSPACE,
        0x35: GHOSTTY_KEY_ESCAPE,
        0x36: GHOSTTY_KEY_META_RIGHT,
        0x37: GHOSTTY_KEY_META_LEFT,
        0x38: GHOSTTY_KEY_SHIFT_LEFT,
        0x39: GHOSTTY_KEY_CAPS_LOCK,
        0x3A: GHOSTTY_KEY_ALT_LEFT,
        0x3B: GHOSTTY_KEY_CONTROL_LEFT,
        0x3C: GHOSTTY_KEY_SHIFT_RIGHT,
        0x3D: GHOSTTY_KEY_ALT_RIGHT,
        0x3E: GHOSTTY_KEY_CONTROL_RIGHT,
        0x40: GHOSTTY_KEY_F17,
        0x41: GHOSTTY_KEY_NUMPAD_DECIMAL,
        0x43: GHOSTTY_KEY_NUMPAD_MULTIPLY,
        0x45: GHOSTTY_KEY_NUMPAD_ADD,
        0x47: GHOSTTY_KEY_NUM_LOCK,
        0x48: GHOSTTY_KEY_AUDIO_VOLUME_UP,
        0x49: GHOSTTY_KEY_AUDIO_VOLUME_DOWN,
        0x4A: GHOSTTY_KEY_AUDIO_VOLUME_MUTE,
        0x4B: GHOSTTY_KEY_NUMPAD_DIVIDE,
        0x4C: GHOSTTY_KEY_NUMPAD_ENTER,
        0x4E: GHOSTTY_KEY_NUMPAD_SUBTRACT,
        0x4F: GHOSTTY_KEY_F18,
        0x50: GHOSTTY_KEY_F19,
        0x51: GHOSTTY_KEY_NUMPAD_EQUAL,
        0x52: GHOSTTY_KEY_NUMPAD_0,
        0x53: GHOSTTY_KEY_NUMPAD_1,
        0x54: GHOSTTY_KEY_NUMPAD_2,
        0x55: GHOSTTY_KEY_NUMPAD_3,
        0x56: GHOSTTY_KEY_NUMPAD_4,
        0x57: GHOSTTY_KEY_NUMPAD_5,
        0x58: GHOSTTY_KEY_NUMPAD_6,
        0x59: GHOSTTY_KEY_NUMPAD_7,
        0x5A: GHOSTTY_KEY_F20,
        0x5B: GHOSTTY_KEY_NUMPAD_8,
        0x5C: GHOSTTY_KEY_NUMPAD_9,
        0x5D: GHOSTTY_KEY_INTL_YEN,
        0x5E: GHOSTTY_KEY_INTL_RO,
        0x5F: GHOSTTY_KEY_NUMPAD_COMMA,
        0x60: GHOSTTY_KEY_F5,
        0x61: GHOSTTY_KEY_F6,
        0x62: GHOSTTY_KEY_F7,
        0x63: GHOSTTY_KEY_F3,
        0x64: GHOSTTY_KEY_F8,
        0x65: GHOSTTY_KEY_F9,
        0x67: GHOSTTY_KEY_F11,
        0x69: GHOSTTY_KEY_F13,
        0x6A: GHOSTTY_KEY_F16,
        0x6B: GHOSTTY_KEY_F14,
        0x6D: GHOSTTY_KEY_F10,
        0x6E: GHOSTTY_KEY_CONTEXT_MENU,
        0x6F: GHOSTTY_KEY_F12,
        0x71: GHOSTTY_KEY_F15,
        0x72: GHOSTTY_KEY_INSERT,
        0x73: GHOSTTY_KEY_HOME,
        0x74: GHOSTTY_KEY_PAGE_UP,
        0x75: GHOSTTY_KEY_DELETE,
        0x76: GHOSTTY_KEY_F4,
        0x77: GHOSTTY_KEY_END,
        0x78: GHOSTTY_KEY_F2,
        0x79: GHOSTTY_KEY_PAGE_DOWN,
        0x7A: GHOSTTY_KEY_F1,
        0x7B: GHOSTTY_KEY_ARROW_LEFT,
        0x7C: GHOSTTY_KEY_ARROW_RIGHT,
        0x7D: GHOSTTY_KEY_ARROW_DOWN,
        0x7E: GHOSTTY_KEY_ARROW_UP,
    ]
}
