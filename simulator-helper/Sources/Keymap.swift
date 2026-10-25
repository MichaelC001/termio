// Adapted from idb's Tools/SimScope/SimScope/Keymap.swift (MIT, Copyright (c) Meta
// Platforms, Inc. and affiliates). Deviation: the NSEvent translation is dropped —
// the app sends characters and key names, never raw key events.

import FBSimulatorControl

/// Text and named keys as USB HID keyboard usages (page 0x07), US layout, which
/// is what a `SimulatorHIDEvent.keyboard` event carries into the simulator.
enum Keymap {
    static let leftShift: UInt32 = 0xE1
    static let leftCommand: UInt32 = 0xE3

    private static let named: [String: UInt32] = [
        "return": 0x28, "enter": 0x28, "escape": 0x29, "esc": 0x29,
        "delete": 0x2A, "backspace": 0x2A, "tab": 0x2B, "space": 0x2C,
        "forward-delete": 0x4C, "right": 0x4F, "left": 0x50, "down": 0x51, "up": 0x52,
        "home": 0x4A, "end": 0x4D, "page-up": 0x4B, "page-down": 0x4E,
    ]

    /// Editing commands, as the hardware-keyboard shortcuts iOS answers to.
    private static let commands: [String: (usage: UInt32, shift: Bool)] = [
        "select-all": (0x04, false), "copy": (0x06, false), "cut": (0x1B, false),
        "paste": (0x19, false), "undo": (0x1D, false), "redo": (0x1D, true),
    ]

    /// One press of `name`, or nil for a name that is not a key. Underscores and
    /// dashes are the same, so `select_all` and `select-all` both work.
    static func press(named name: String) -> [SimulatorHIDEvent]? {
        let name = name.lowercased().replacingOccurrences(of: "_", with: "-")
        if let usage = named[name] { return press(usage, shift: false) }
        guard let command = commands[name] else { return nil }
        var events: [SimulatorHIDEvent] = [.keyboard(direction: .down, keyCode: leftCommand)]
        events.append(contentsOf: press(command.usage, shift: command.shift))
        events.append(.keyboard(direction: .up, keyCode: leftCommand))
        return events
    }

    /// One down/up press per character, wrapped in left shift where the
    /// character needs it. Characters off the US layout are skipped and counted,
    /// so the caller can say what was not typed rather than claim it was.
    static func events(typing text: String) -> (event: SimulatorHIDEvent, skipped: Int) {
        var events: [SimulatorHIDEvent] = []
        var skipped = 0
        for character in text {
            let key: (usage: UInt32, shift: Bool)?
            if character == "\n" || character == "\r" {
                key = (0x28, false)
            } else {
                key = printable[character]
            }
            guard let key else {
                skipped += 1
                continue
            }
            events.append(contentsOf: press(key.usage, shift: key.shift))
        }
        return (.composite(events), skipped)
    }

    static func press(_ usage: UInt32, shift: Bool) -> [SimulatorHIDEvent] {
        var events: [SimulatorHIDEvent] = []
        if shift { events.append(.keyboard(direction: .down, keyCode: leftShift)) }
        events.append(.keyboard(direction: .down, keyCode: usage))
        events.append(.keyboard(direction: .up, keyCode: usage))
        if shift { events.append(.keyboard(direction: .up, keyCode: leftShift)) }
        return events
    }

    private static let printable: [Character: (usage: UInt32, shift: Bool)] = {
        var table: [Character: (UInt32, Bool)] = [:]
        for (offset, lower) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
            let usage = 0x04 + UInt32(offset)
            table[lower] = (usage, false)
            if let upper = lower.uppercased().first { table[upper] = (usage, true) }
        }
        let digitUsages: [UInt32] = [0x1E, 0x1F, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27]
        for (offset, digit) in "1234567890".enumerated() { table[digit] = (digitUsages[offset], false) }
        for (offset, symbol) in "!@#$%^&*()".enumerated() { table[symbol] = (digitUsages[offset], true) }
        table[" "] = (0x2C, false)
        let punctuation: [(Character, Character, UInt32)] = [
            ("-", "_", 0x2D), ("=", "+", 0x2E), ("[", "{", 0x2F), ("]", "}", 0x30),
            ("\\", "|", 0x31), (";", ":", 0x33), ("'", "\"", 0x34), ("`", "~", 0x35),
            (",", "<", 0x36), (".", ">", 0x37), ("/", "?", 0x38),
        ]
        for (base, shifted, usage) in punctuation {
            table[base] = (usage, false)
            table[shifted] = (usage, true)
        }
        return table
    }()
}
