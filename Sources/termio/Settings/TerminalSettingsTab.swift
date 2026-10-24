import SwiftUI

/// Everything about the terminal itself: the font it draws, its cursor, the window
/// around the grid, and how it keeps and copies text.
///
/// Grouped by the thing being changed rather than by whether a setting is about
/// looks. Font, cursor and padding used to sit under Appearance as "how it looks",
/// which left this tab two rows long and sent anyone wanting to change the
/// terminal's cursor to a tab not named after the terminal. Appearance now holds
/// only the app's own chrome.
struct TerminalSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                FontFamilyField(
                    title: localized("Family"),
                    prompt: localized("System monospace"),
                    families: InstalledFonts.monospaced,
                    previewSize: settings.fontSize,
                    monospacedDefault: true,
                    family: $settings.fontFamily
                )
                SettingsStepper(
                    title: localized("Size"), value: $settings.fontSize, range: 8...32, step: 1,
                    display: localized("\(Int(settings.fontSize)) pt"))
                SettingsStepper(
                    title: localized("Line height"), value: $settings.codeLineHeight, range: 1.0...2.0, step: 0.1,
                    display: String(format: "%.1f×", settings.codeLineHeight))
                Toggle(localized("Thicken glyphs"), isOn: $settings.fontThicken)
            } header: {
                SectionHeaderLabel(title: localized("Font"))
            } footer: {
                if settings.inheritsGhosttyDefaults {
                    Text(localized("Line height applies to the file editor and diffs; the terminal keeps the font’s own. Font and theme values you haven’t set here follow your Ghostty config."))
                        .font(.settingsDetail)
                        .foregroundStyle(.secondary)
                } else {
                    Text(localized("Line height applies to the file editor and diffs; the terminal keeps the font’s own."))
                        .font(.settingsDetail)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Picker(localized("Style"), selection: $settings.cursorStyle) {
                    ForEach(CursorStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                Toggle(localized("Blink"), isOn: $settings.cursorBlink)
            } header: {
                SectionHeaderLabel(title: localized("Cursor"))
            }
            Section {
                SettingsStepper(
                    title: localized("Padding"), value: $settings.windowPadding, range: 0...40, step: 2,
                    display: localized("\(settings.windowPadding) pt"))
                LabeledContent(localized("Opacity")) {
                    HStack(spacing: 8) {
                        Slider(value: $settings.backgroundOpacity, in: 0.2...1.0)
                            .frame(width: 160)
                        Text(settings.backgroundOpacity.formatted(.percent.precision(.fractionLength(0))))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                SettingsStepper(
                    title: localized("Blur"), value: $settings.backgroundBlur, range: 0...60, step: 5,
                    display: "\(settings.backgroundBlur)")
                .disabled(settings.backgroundOpacity >= 1.0)
            } header: {
                SectionHeaderLabel(title: localized("Window"))
            }
            Section {
                SettingsStepper(
                    title: localized("Scrollback"), value: $settings.scrollbackMegabytes, range: 1...500, step: 1,
                    display: "\(settings.scrollbackMegabytes) MB")
                Toggle(localized("Copy on select"), isOn: $settings.copyOnSelect)
            } header: {
                SectionHeaderLabel(title: localized("Behavior"))
            }
        }
        .formStyle(.grouped)
    }
}
