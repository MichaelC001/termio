import SwiftUI
import AppKit
import GhosttyTheme

/// The preferences window, opened from the app menu (⌘,). The tabs mirror the
/// settings groups: terminal appearance, the app's own interface chrome, terminal
/// behaviour, the agent presets, and worktree isolation. Controls bind straight to
/// `AppSettings`, which persists on change, so there is no separate save step.
///
/// The visual language follows Dia's settings: a top icon-tab toolbar for the
/// top-level groups, grouped rounded cards in the body, and Dia's signature
/// leading colored icon badges (`IconBadge`) to give each section and feature
/// row a distinct identity.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var selection: SettingsTab = .appearance

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: $selection)
            Divider()
            Group {
                switch selection {
                case .appearance: AppearanceSettingsTab(settings: settings)
                case .interface: InterfaceSettingsTab(settings: settings)
                case .terminal: TerminalSettingsTab(settings: settings)
                case .agents: AgentSettingsTab(settings: settings)
                case .worktrees: WorktreeSettingsTab(settings: settings)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 540, height: 520)
    }
}

/// The top-level settings groups. Each is one icon-over-label button in the
/// `SettingsTabBar`.
private enum SettingsTab: String, CaseIterable, Identifiable {
    case appearance
    case interface
    case terminal
    case agents
    case worktrees

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .interface: return "Interface"
        case .terminal: return "Terminal"
        case .agents: return "Agents"
        case .worktrees: return "Worktrees"
        }
    }

    var symbol: String {
        switch self {
        case .appearance: return "paintbrush"
        case .interface: return "sidebar.left"
        case .terminal: return "terminal"
        case .agents: return "sparkles"
        case .worktrees: return "arrow.triangle.branch"
        }
    }
}

/// Dia's settings navigation: a horizontal row of icon-over-label buttons sitting
/// just under the title bar. The selected tab tints its icon and label with the
/// accent color and floats a soft rounded highlight behind them.
private struct SettingsTabBar: View {
    @Binding var selection: SettingsTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases) { tab in
                TabButton(tab: tab, isSelected: tab == selection) {
                    selection = tab
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 0)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
    }

    private struct TabButton: View {
        let tab: SettingsTab
        let isSelected: Bool
        let action: () -> Void

        @State private var isHovering = false

        var body: some View {
            Button(action: action) {
                VStack(spacing: 3) {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 17, weight: .regular))
                        .frame(height: 22)
                    Text(tab.title)
                        .font(.system(size: 11))
                }
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 84, height: 48)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(backgroundFill)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
        }

        /// Selected tab keeps its accent wash; an unselected tab picks up Dia's
        /// faint gray hover fill so the whole hit area lights up under the cursor.
        private var backgroundFill: Color {
            if isSelected { return Color.accentColor.opacity(0.12) }
            if isHovering { return Color.primary.opacity(0.06) }
            return .clear
        }
    }
}

/// The leading row icon on a soft, translucent grey "glass" square. Section and
/// feature symbols stay neutral grey to keep the settings calm and scannable;
/// agent brand marks carry their vendor color so they read as real product logos.
private struct IconBadge: View {
    let icon: AgentIcon

    init(_ icon: AgentIcon) { self.icon = icon }
    init(symbol: String) { self.icon = .systemSymbol(symbol) }

    var body: some View {
        glyph
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.quaternary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 0.5)
            )
    }

    @ViewBuilder
    private var glyph: some View {
        switch icon {
        case .systemSymbol(let name):
            Image(systemName: name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        case .hugeIcon(let hugeIcon):
            HugeIconView(icon: hugeIcon, size: 14, color: .secondary)
        case .brand(let logo):
            BrandLogoShape(logo: logo)
                .fill(logo.tint, style: FillStyle(eoFill: logo.usesEvenOddFill))
                .frame(width: 13, height: 13)
        case .brandImage(let asset):
            BrandImageView(asset: asset, size: 18)
        }
    }
}

/// A grouped-section header rendered as a badge plus title, replacing the default
/// uppercased gray caption so each card reads as a labeled group (Dia style).
private struct SectionHeaderLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 8) {
            IconBadge(symbol: symbol)
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
        }
        .textCase(nil)
        .padding(.bottom, 2)
    }
}

/// The font families installed on this Mac, used to populate the font pickers.
/// Enumerating the font manager is not free, so each list is computed once and
/// reused for the lifetime of the process.
enum InstalledFonts {
    /// Fixed-pitch families, for the terminal where a proportional font would
    /// break column alignment.
    static let monospaced: [String] = families(fixedPitchOnly: true)

    /// All families, for the app's own chrome where proportional fonts are fine.
    static let all: [String] = families(fixedPitchOnly: false)

    private static func families(fixedPitchOnly: Bool) -> [String] {
        // Drop the dot-prefixed hidden system faces; they are not meant to be
        // selected by name and only clutter the menu.
        let visible = NSFontManager.shared.availableFontFamilies
            .filter { !$0.hasPrefix(".") }
        guard fixedPitchOnly else { return visible.sorted() }
        return visible.filter { family in
            guard let font = NSFont(name: family, size: 12) else { return false }
            return font.isFixedPitch
        }.sorted()
    }
}

/// A font-family editor: a free-text field paired with a menu of installed
/// families. The text field stays the source of truth so any name libghostty
/// accepts (including ones not enumerated here) can still be typed; the menu is
/// purely for discovery and fills the field on selection.
private struct FontFamilyField: View {
    let title: String
    let prompt: String
    let families: [String]
    @Binding var family: String

    var body: some View {
        HStack(spacing: 8) {
            TextField(title, text: $family, prompt: Text(prompt))
            Menu {
                if !family.isEmpty {
                    Button("Use default") { family = "" }
                    Divider()
                }
                ForEach(families, id: \.self) { name in
                    Button(name) { family = name }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

private struct AppearanceSettingsTab: View {
    @ObservedObject var settings: AppSettings

    /// Ghostty's bundled theme names. `search("")` matches everything, giving the
    /// full catalog; sorted for a stable, scannable picker.
    private let themeNames = GhosttyThemeCatalog.search("").map(\.name).sorted()

    var body: some View {
        Form {
            Section {
                FontFamilyField(
                    title: "Family",
                    prompt: "System monospace",
                    families: InstalledFonts.monospaced,
                    family: $settings.fontFamily
                )
                Stepper(value: $settings.fontSize, in: 8...32, step: 1) {
                    Text("Size: \(Int(settings.fontSize)) pt")
                }
                Toggle("Thicken glyphs", isOn: $settings.fontThicken)
            } header: {
                SectionHeaderLabel(title: "Font", symbol: "textformat")
            }
            Section {
                Picker("Style", selection: $settings.cursorStyle) {
                    ForEach(CursorStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                Toggle("Blink", isOn: $settings.cursorBlink)
            } header: {
                SectionHeaderLabel(title: "Cursor", symbol: "cursorarrow")
            }
            Section {
                Stepper(value: $settings.windowPadding, in: 0...40, step: 2) {
                    Text("Padding: \(settings.windowPadding) pt")
                }
                LabeledContent("Opacity") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.backgroundOpacity, in: 0.2...1.0)
                            .frame(width: 160)
                        Text(settings.backgroundOpacity.formatted(.percent.precision(.fractionLength(0))))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                Stepper(value: $settings.backgroundBlur, in: 0...60, step: 5) {
                    Text("Blur: \(settings.backgroundBlur)")
                }
                .disabled(settings.backgroundOpacity >= 1.0)
            } header: {
                SectionHeaderLabel(title: "Window", symbol: "macwindow")
            } footer: {
                Text("Opacity below 100% lets the desktop show through; blur softens it. The window stays solid at full opacity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Theme", selection: $settings.themeName) {
                    Text("Terminal default").tag("")
                    Divider()
                    ForEach(themeNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
            } header: {
                SectionHeaderLabel(title: "Theme", symbol: "paintpalette")
            }
        }
        .formStyle(.grouped)
    }
}

/// The app's own chrome (currently the project/session sidebar): a VSCode-style
/// font and density control, kept separate from the terminal's font so the two
/// can be tuned independently.
private struct InterfaceSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                FontFamilyField(
                    title: "Family",
                    prompt: "System",
                    families: InstalledFonts.all,
                    family: $settings.interfaceFontFamily
                )
                Stepper(value: $settings.interfaceFontSize, in: 9...20, step: 1) {
                    Text("Size: \(Int(settings.interfaceFontSize)) pt")
                }
            } header: {
                SectionHeaderLabel(title: "Sidebar font", symbol: "textformat")
            } footer: {
                Text("Applies to the project and session list. Need not be monospaced.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Row padding") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.interfaceRowPadding, in: 0...12, step: 1)
                            .frame(width: 160)
                        Text("\(Int(settings.interfaceRowPadding)) pt")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            } header: {
                SectionHeaderLabel(title: "Density", symbol: "arrow.up.and.down")
            }
        }
        .formStyle(.grouped)
    }
}

/// Terminal behaviour that isn't about how it looks: how much history to keep and
/// what selecting text does.
private struct TerminalSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Stepper(value: $settings.scrollbackMegabytes, in: 1...500, step: 1) {
                    Text("Scrollback: \(settings.scrollbackMegabytes) MB")
                }
            } header: {
                SectionHeaderLabel(title: "History", symbol: "clock.arrow.circlepath")
            } footer: {
                Text("How much output each session keeps for scrolling back. Agents are verbose, so the default is generous.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Copy on select", isOn: $settings.copyOnSelect)
            } header: {
                SectionHeaderLabel(title: "Selection", symbol: "selection.pin.in.out")
            } footer: {
                Text("When on, selecting text copies it straight to the clipboard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AgentSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            ForEach(AgentPreset.allCases) { preset in
                Section {
                    // The Dia "Sync row": a badge + title + subtitle on the left,
                    // its switch on the right. The switch controls whether the
                    // agent appears in the sidebar's new-session quick-add row.
                    Toggle(isOn: Binding(
                        get: { settings.isAgentEnabled(preset) },
                        set: { settings.setAgent(preset, enabled: $0) }
                    )) {
                        HStack(spacing: 10) {
                            IconBadge(preset.icon)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(preset.displayName)
                                    .font(.headline)
                                Text(subtitle(for: preset))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.switch)

                    // The plain terminal launches the login shell — there is no
                    // command to override, so only agent presets get a field.
                    if preset != .terminal {
                        TextField(
                            "Command",
                            text: Binding(
                                get: { settings.agentCommandOverrides[preset.rawValue] ?? "" },
                                set: { settings.agentCommandOverrides[preset.rawValue] = $0 }
                            ),
                            prompt: Text(preset.command ?? "")
                        )
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Subtitle under each agent name: the command it runs, so the row is
    /// self-describing even before the override field below it.
    private func subtitle(for preset: AgentPreset) -> String {
        preset.command ?? "Login shell"
    }
}

private struct WorktreeSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.worktreeEnabled) {
                    HStack(spacing: 10) {
                        IconBadge(symbol: "arrow.triangle.branch")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Git worktree per session")
                                .font(.headline)
                            Text("Isolates an agent's edits on a branch instead of mutating the project's working tree. Non-git projects fall back to running in place.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .toggleStyle(.switch)
            }
            Section {
                TextField("Directory", text: $settings.worktreeBaseDirectory)
                TextField("Branch prefix", text: $settings.worktreeBranchPrefix)
            } header: {
                SectionHeaderLabel(title: "Location", symbol: "folder")
            }
            .disabled(!settings.worktreeEnabled)
        }
        .formStyle(.grouped)
    }
}
