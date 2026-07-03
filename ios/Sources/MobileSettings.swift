import UIKit

/// App-wide user preferences — the mobile counterpart of the Mac app's
/// `AppSettings`, pared down to the knobs that matter on a phone: appearance
/// mode, the light/dark terminal theme pair, and font size. UserDefaults-
/// backed the same way (every write persists immediately); changes post
/// `didChange` so live surfaces restyle in place instead of waiting for a
/// relaunch.
final class MobileSettings {
    static let shared = MobileSettings()
    static let didChange = Notification.Name("MobileSettingsDidChange")

    /// Same trio as the Mac's Appearance setting: follow the device, or pin
    /// the whole app (shell, sheets, and the terminal's theme slot) to one
    /// side — applied as the window's interface-style override.
    enum AppearanceMode: String, CaseIterable {
        case system, light, dark

        var uiStyle: UIUserInterfaceStyle {
            switch self {
            case .system: .unspecified
            case .light: .light
            case .dark: .dark
            }
        }

        var label: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
    }

    /// The Catppuccin pair matches what the app shipped with before themes
    /// were configurable, so existing installs look unchanged.
    static let defaultLightThemeName = "Catppuccin Latte"
    static let defaultDarkThemeName = "Catppuccin Mocha"
    static let defaultFontSize = 13.0
    static let fontSizeRange = 8.0 ... 24.0

    private enum Key {
        static let appearanceMode = "appearance.mode"
        static let lightThemeName = "appearance.lightThemeName"
        static let darkThemeName = "appearance.darkThemeName"
        static let fontSize = "appearance.fontSize"
        static let terminalKeys = "terminalKeyboard.keys"
    }

    private let defaults = UserDefaults.standard

    var appearanceMode: AppearanceMode {
        didSet {
            defaults.set(appearanceMode.rawValue, forKey: Key.appearanceMode)
            notify()
        }
    }

    var lightThemeName: String {
        didSet {
            defaults.set(lightThemeName, forKey: Key.lightThemeName)
            notify()
        }
    }

    var darkThemeName: String {
        didSet {
            defaults.set(darkThemeName, forKey: Key.darkThemeName)
            notify()
        }
    }

    var fontSize: Double {
        didSet {
            defaults.set(fontSize, forKey: Key.fontSize)
            notify()
        }
    }

    /// Which catalog keys join the terminal keyboard's control zone, in
    /// catalog order (esc, numbers, arrows, and return are fixed core, not
    /// stored here).
    var terminalKeyIDs: [String] {
        didSet {
            defaults.set(terminalKeyIDs, forKey: Key.terminalKeys)
            notify()
        }
    }

    private init() {
        defaults.register(defaults: [
            Key.appearanceMode: AppearanceMode.system.rawValue,
            Key.lightThemeName: Self.defaultLightThemeName,
            Key.darkThemeName: Self.defaultDarkThemeName,
            Key.fontSize: Self.defaultFontSize,
            Key.terminalKeys: TerminalKeyCatalog.defaultIDs,
        ])
        appearanceMode = AppearanceMode(
            rawValue: defaults.string(forKey: Key.appearanceMode) ?? ""
        ) ?? .system
        lightThemeName = defaults.string(forKey: Key.lightThemeName) ?? Self.defaultLightThemeName
        darkThemeName = defaults.string(forKey: Key.darkThemeName) ?? Self.defaultDarkThemeName
        fontSize = defaults.double(forKey: Key.fontSize)
        terminalKeyIDs = defaults.stringArray(forKey: Key.terminalKeys)
            ?? TerminalKeyCatalog.defaultIDs
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}

extension UIColor {
    /// Ghostty theme colors are bare RGB hex, with or without a leading `#`.
    convenience init?(ghosttyHex hex: String) {
        var value: UInt64 = 0
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard cleaned.count == 6, Scanner(string: cleaned).scanHexInt64(&value) else {
            return nil
        }
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
