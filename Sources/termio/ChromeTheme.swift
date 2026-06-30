import AppKit
import SwiftUI
import GhosttyTheme

/// App-chrome colors borrowed from the selected terminal theme.
///
/// termio keeps a single source of color truth — the Ghostty theme the user picks
/// for the terminal. Rather than maintain a second palette for the sidebar and
/// window (which would drift from the terminal's), the chrome derives its colors
/// from that same theme. When no terminal theme is selected this type isn't built
/// at all and the chrome falls back to the system appearance.
struct ChromeTheme {
    /// The terminal background, so the chrome can sit flush with the terminal.
    let background: Color
    /// The sidebar fill: a subtle step off the terminal background so the seam
    /// between the columns reads without a hard divider.
    let panelBackground: Color
    /// Primary chrome text (session titles).
    let foreground: Color
    /// Muted chrome text (project labels, icons).
    let secondaryForeground: Color
    /// Selection/hover tint for sidebar rows.
    let accent: Color
    /// Whether the theme reads as dark, so the window can match its system
    /// appearance (traffic lights, scrollbars) to the theme.
    let isDark: Bool

    init?(_ definition: GhosttyThemeDefinition) {
        guard let background = Color(hex: definition.background),
              let foreground = Color(hex: definition.foreground)
        else { return nil }
        let dark = definition.isDark
        self.background = background
        self.foreground = foreground
        // Lift the sidebar a touch off the terminal background — lighter in a dark
        // theme, darker in a light one, like VSCode's activity bar.
        self.panelBackground = background.blended(
            with: dark ? .white : .black,
            amount: dark ? 0.06 : 0.04
        )
        self.secondaryForeground = foreground.opacity(0.6)
        // The active row reads as accent-tinted (VSCode's active list item), so
        // prefer the theme's blue (palette slot 4) over its quieter text-selection
        // grey; fall back through both to the foreground so it always resolves.
        let accentHex = definition.palette[4] ?? definition.selectionBackground
        self.accent = accentHex.flatMap(Color.init(hex:)) ?? foreground
        self.isDark = dark
    }
}

extension AppSettings {
    /// Chrome colors derived from the terminal theme that applies in `colorScheme`,
    /// or `nil` to keep the system appearance when that slot is left on the default.
    /// The light and dark slots are independent — the chrome tracks whichever theme
    /// libghostty is currently rendering. Recomputes when the theme names change
    /// because `AppSettings` republishes on every appearance edit.
    func chromeTheme(for colorScheme: ColorScheme) -> ChromeTheme? {
        let name = colorScheme == .dark ? darkThemeName : lightThemeName
        guard !name.isEmpty,
              let definition = ThemeLibrary.theme(named: name)
        else { return nil }
        return ChromeTheme(definition)
    }

    /// The terminal surface's background color, so the window chrome and the
    /// terminal pane can paint the exact fill the terminal renders. Returned as a
    /// dynamic color that resolves per appearance: each side uses its chosen theme's
    /// background, or the default when that slot is empty — pure white in light mode
    /// (crisper than libghostty's Alabaster #F7F7F7, which reads as an unstyled grey
    /// under termio's mostly-empty canvas) and Afterglow #212121 in dark. Both sides
    /// are resolved up front on the main actor so the dynamic closure captures only
    /// plain colors.
    var terminalBackgroundColor: NSColor {
        let lightBackground = chromeTheme(for: .light)?.background
        let darkBackground = chromeTheme(for: .dark)?.background
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            if isDark {
                return darkBackground.map(NSColor.init)
                    ?? NSColor(srgbRed: 0x21 / 255.0, green: 0x21 / 255.0, blue: 0x21 / 255.0, alpha: 1)
            }
            return lightBackground.map(NSColor.init) ?? NSColor.white
        }
    }
}

extension Color {
    /// Parses a six-digit RGB hex string (with or without a leading `#`) — the form
    /// `GhosttyThemeDefinition` stores its colors in. Used by the chrome theme and the
    /// theme picker's swatches.
    init?(hex: String) {
        let raw = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard raw.count == 6, let value = UInt32(raw, radix: 16) else { return nil }
        self = Color(
            .sRGB,
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }

    /// A linear mix toward `other` in sRGB. `amount` is clamped to 0...1; on a color
    /// that can't be resolved into sRGB components the receiver is returned as-is
    /// rather than trapping.
    func blended(with other: Color, amount: Double) -> Color {
        guard let base = NSColor(self).usingColorSpace(.sRGB),
              let target = NSColor(other).usingColorSpace(.sRGB)
        else { return self }
        let t = max(0, min(1, amount))
        return Color(
            .sRGB,
            red: base.redComponent + (target.redComponent - base.redComponent) * t,
            green: base.greenComponent + (target.greenComponent - base.greenComponent) * t,
            blue: base.blueComponent + (target.blueComponent - base.blueComponent) * t
        )
    }
}
