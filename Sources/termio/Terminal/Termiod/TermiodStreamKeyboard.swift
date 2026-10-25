import AppKit
import Carbon.HIToolbox
import GhosttyVt
import TermioShared

/// How a Mac keystroke becomes a key event for a `vt_stream` session: the
/// physical key by Ghostty's name, the modifiers with their sides, and the
/// text the layout typed. termiod encodes it (`Termiod.InputEvent`). Kept to
/// what Ghostty's own AppKit view does, so the program in the terminal cannot
/// tell the stream view from the embedded surface.
enum TermiodStreamKeyboard {
    /// Ghostty's name for the physical key a macOS virtual keycode names,
    /// from its own table (`src/input/keycodes.zig`, the Mac column).
    static func key(forKeycode keycode: UInt16) -> String {
        keys[keycode] ?? "unidentified"
    }

    /// The modifiers held, with the side of each when it is the right one.
    static func mods(_ flags: NSEvent.ModifierFlags) -> UInt16 {
        var mods: GhosttyMods = 0
        let raw = flags.rawValue
        if flags.contains(.shift) { mods |= UInt16(GHOSTTY_MODS_SHIFT) }
        if flags.contains(.control) { mods |= UInt16(GHOSTTY_MODS_CTRL) }
        if flags.contains(.option) { mods |= UInt16(GHOSTTY_MODS_ALT) }
        if flags.contains(.command) { mods |= UInt16(GHOSTTY_MODS_SUPER) }
        if flags.contains(.capsLock) { mods |= UInt16(GHOSTTY_MODS_CAPS_LOCK) }
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= UInt16(GHOSTTY_MODS_SHIFT_SIDE) }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= UInt16(GHOSTTY_MODS_CTRL_SIDE) }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= UInt16(GHOSTTY_MODS_ALT_SIDE) }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= UInt16(GHOSTTY_MODS_SUPER_SIDE) }
        return mods
    }

    /// The key event for `event`. `text` is what the layout or the input
    /// method produced; nil leaves the bytes to the key and its modifiers.
    static func input(
        for event: NSEvent, action: Termiod.InputEvent.Action, text: String?, composing: Bool = false
    ) -> Termiod.InputEvent.Key {
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
        return Termiod.InputEvent.Key(
            action: action, key: key(forKeycode: event.keyCode), mods: mods(event.modifierFlags),
            consumedMods: mods(consumed), text: text.flatMap(typedText), unshifted: unshifted,
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
    static func inputs(for press: SessionKeyPress) -> [Termiod.InputEvent.Key] {
        var mods: UInt16 = 0
        if press.modifiers.contains(.shift) { mods |= UInt16(GHOSTTY_MODS_SHIFT) }
        if press.modifiers.contains(.control) { mods |= UInt16(GHOSTTY_MODS_CTRL) }
        if press.modifiers.contains(.option) { mods |= UInt16(GHOSTTY_MODS_ALT) }
        if press.modifiers.contains(.command) { mods |= UInt16(GHOSTTY_MODS_SUPER) }
        let input = Termiod.InputEvent.Key(
            key: key(forKeycode: UInt16(press.keycode)), mods: mods,
            consumedMods: press.text == nil ? 0 : mods & shift,
            text: press.text, unshifted: press.unshiftedCodepoint
        )
        var release = input
        release.action = .release
        return [input, release]
    }

    /// libghostty's modifier bits, the same on the wire as in its C header.
    static let shift = UInt16(GHOSTTY_MODS_SHIFT)
    static let control = UInt16(GHOSTTY_MODS_CTRL)

    private static let keys: [UInt16: String] = [
        0x00: "a",
        0x01: "s",
        0x02: "d",
        0x03: "f",
        0x04: "h",
        0x05: "g",
        0x06: "z",
        0x07: "x",
        0x08: "c",
        0x09: "v",
        0x0A: "intl_backslash",
        0x0B: "b",
        0x0C: "q",
        0x0D: "w",
        0x0E: "e",
        0x0F: "r",
        0x10: "y",
        0x11: "t",
        0x12: "digit_1",
        0x13: "digit_2",
        0x14: "digit_3",
        0x15: "digit_4",
        0x16: "digit_6",
        0x17: "digit_5",
        0x18: "equal",
        0x19: "digit_9",
        0x1A: "digit_7",
        0x1B: "minus",
        0x1C: "digit_8",
        0x1D: "digit_0",
        0x1E: "bracket_right",
        0x1F: "o",
        0x20: "u",
        0x21: "bracket_left",
        0x22: "i",
        0x23: "p",
        0x24: "enter",
        0x25: "l",
        0x26: "j",
        0x27: "quote",
        0x28: "k",
        0x29: "semicolon",
        0x2A: "backslash",
        0x2B: "comma",
        0x2C: "slash",
        0x2D: "n",
        0x2E: "m",
        0x2F: "period",
        0x30: "tab",
        0x31: "space",
        0x32: "backquote",
        0x33: "backspace",
        0x35: "escape",
        0x36: "meta_right",
        0x37: "meta_left",
        0x38: "shift_left",
        0x39: "caps_lock",
        0x3A: "alt_left",
        0x3B: "control_left",
        0x3C: "shift_right",
        0x3D: "alt_right",
        0x3E: "control_right",
        0x40: "f17",
        0x41: "numpad_decimal",
        0x43: "numpad_multiply",
        0x45: "numpad_add",
        0x47: "num_lock",
        0x48: "audio_volume_up",
        0x49: "audio_volume_down",
        0x4A: "audio_volume_mute",
        0x4B: "numpad_divide",
        0x4C: "numpad_enter",
        0x4E: "numpad_subtract",
        0x4F: "f18",
        0x50: "f19",
        0x51: "numpad_equal",
        0x52: "numpad_0",
        0x53: "numpad_1",
        0x54: "numpad_2",
        0x55: "numpad_3",
        0x56: "numpad_4",
        0x57: "numpad_5",
        0x58: "numpad_6",
        0x59: "numpad_7",
        0x5A: "f20",
        0x5B: "numpad_8",
        0x5C: "numpad_9",
        0x5D: "intl_yen",
        0x5E: "intl_ro",
        0x5F: "numpad_comma",
        0x60: "f5",
        0x61: "f6",
        0x62: "f7",
        0x63: "f3",
        0x64: "f8",
        0x65: "f9",
        0x67: "f11",
        0x69: "f13",
        0x6A: "f16",
        0x6B: "f14",
        0x6D: "f10",
        0x6E: "context_menu",
        0x6F: "f12",
        0x71: "f15",
        0x72: "insert",
        0x73: "home",
        0x74: "page_up",
        0x75: "delete",
        0x76: "f4",
        0x77: "end",
        0x78: "f2",
        0x79: "page_down",
        0x7A: "f1",
        0x7B: "arrow_left",
        0x7C: "arrow_right",
        0x7D: "arrow_down",
        0x7E: "arrow_up",
    ]
}
