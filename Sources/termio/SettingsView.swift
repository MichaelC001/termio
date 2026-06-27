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

/// The leading row icon, rendered as a bare glyph with no backing square. Section
/// and feature symbols stay neutral grey to keep the settings calm and scannable;
/// agent brand marks carry their vendor color so they read as real product logos.
private struct IconBadge: View {
    let icon: AgentIcon

    init(_ icon: AgentIcon) { self.icon = icon }
    init(symbol: String) { self.icon = .systemSymbol(symbol) }

    var body: some View {
        glyph
            .frame(width: 22, height: 22)
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

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.primary)
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

/// A font-family editor: a native pop-up menu of installed families above a live
/// preview, matching the other grouped-form rows (Style, Theme). An empty value
/// is the valid "system default" state. A trailing "Custom…" item reveals an
/// inline text field so any name libghostty accepts — including faces this list
/// does not enumerate — can still be entered; the preview flags a custom name the
/// system cannot resolve rather than letting it fail silently.
private struct FontFamilyField: View {
    let title: String
    let prompt: String
    let families: [String]
    /// Size to render the preview at, mirroring the live setting so the preview
    /// reflects what the terminal or sidebar will actually show.
    let previewSize: CGFloat
    /// Whether the default (empty value) is the system *monospaced* font. Drives
    /// which face the preview falls back to so it matches the real default.
    let monospacedDefault: Bool
    @Binding var family: String

    /// Set when the user picks "Custom…" so the text field stays open even while
    /// its value is still empty (which on its own would read as the default).
    @State private var editingCustom = false
    @FocusState private var customFieldFocused: Bool

    private static let sample = "The quick brown fox 0Oo1Il|·{}[]() => != <= ->"

    /// A menu tag that cannot collide with a real font family name, used for the
    /// "Custom…" item.
    private static let customTag = "\u{1}termio.custom"

    /// True when the current value is a custom name (non-empty and not one of the
    /// installed families the pop-up lists).
    private var hasCustomValue: Bool {
        !family.isEmpty && !families.contains(family)
    }

    /// Whether the inline custom field should be shown.
    private var showingCustomField: Bool { editingCustom || hasCustomValue }

    /// Maps the pop-up selection to and from `family`, routing the "Custom…"
    /// sentinel through `editingCustom` rather than the stored value.
    private var selection: Binding<String> {
        Binding(
            get: { showingCustomField ? Self.customTag : family },
            set: { newValue in
                if newValue == Self.customTag {
                    editingCustom = true
                    customFieldFocused = true
                } else {
                    editingCustom = false
                    family = newValue
                }
            }
        )
    }

    /// Resolves the selected family to a concrete font for the preview. An empty
    /// value is the valid "use the default" state, not a failure; a non-empty
    /// name the system cannot resolve flags `isFallback` so the caption can tell
    /// the user it did not take.
    private var preview: (font: NSFont, isFallback: Bool) {
        let size = min(max(previewSize, 9), 22)
        let fallback = monospacedDefault
            ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            : NSFont.systemFont(ofSize: size)
        let trimmed = family.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return (fallback, false) }
        if let font = NSFont(name: trimmed, size: size) {
            return (font, false)
        }
        return (fallback, true)
    }

    var body: some View {
        let preview = preview
        VStack(alignment: .leading, spacing: 6) {
            Picker(title, selection: selection) {
                Text(prompt).tag("")
                Divider()
                ForEach(families, id: \.self) { name in
                    Text(name).tag(name)
                }
                Divider()
                Text("Custom…").tag(Self.customTag)
            }
            if showingCustomField {
                TextField("Font name", text: $family, prompt: Text("e.g. JetBrains Mono"))
                    .textFieldStyle(.roundedBorder)
                    .focused($customFieldFocused)
            }
            Text(Self.sample)
                .font(Font(preview.font))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(preview.isFallback ? .tertiary : .secondary)
            if preview.isFallback {
                Text("“\(family)” isn’t installed — showing the system default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A graphical light/dark/system switcher, styled like macOS System Settings:
/// three tiles, each a small window rendered in that appearance, with a radio and
/// label beneath and an accent ring on the selection.
private struct AppearanceModePicker: View {
    @Binding var selection: AppearanceMode

    var body: some View {
        HStack(spacing: 20) {
            ForEach(AppearanceMode.allCases) { mode in
                Tile(mode: mode, isSelected: mode == selection) {
                    selection = mode
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private struct Tile: View {
        let mode: AppearanceMode
        let isSelected: Bool
        let action: () -> Void

        var body: some View {
            VStack(spacing: 8) {
                Button(action: action) {
                    WindowMock(mode: mode)
                        .frame(width: 116, height: 74)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(
                                    isSelected ? Color.accentColor : Color.primary.opacity(0.15),
                                    lineWidth: isSelected ? 3 : 1
                                )
                        )
                }
                .buttonStyle(.plain)
                Label {
                    Text(mode.displayName).font(.system(size: 12))
                } icon: {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                }
                .labelStyle(.titleAndIcon)
            }
        }
    }
}

/// A miniature window drawn in a fixed light or dark appearance for the
/// `AppearanceModePicker` tiles. `.system` shows both, divided by a diagonal, the
/// way the macOS "Auto" swatch does.
private struct WindowMock: View {
    let mode: AppearanceMode

    var body: some View {
        switch mode {
        case .light:
            pane(dark: false)
        case .dark:
            pane(dark: true)
        case .system:
            ZStack {
                pane(dark: false)
                pane(dark: true).clipShape(DiagonalSplit())
            }
        }
    }

    private func pane(dark: Bool) -> some View {
        let body = dark ? Color(white: 0.13) : Color.white
        let bar = dark ? Color(white: 0.22) : Color(white: 0.93)
        let line = dark ? Color(white: 0.32) : Color(white: 0.82)
        return VStack(spacing: 0) {
            HStack(spacing: 3) {
                Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34)).frame(width: 5, height: 5)
                Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18)).frame(width: 5, height: 5)
                Circle().fill(Color(red: 0.24, green: 0.79, blue: 0.33)).frame(width: 5, height: 5)
                Spacer()
            }
            .padding(.horizontal, 7)
            .frame(height: 17)
            .frame(maxWidth: .infinity)
            .background(bar)
            ZStack(alignment: .topLeading) {
                body
                VStack(alignment: .leading, spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(line).frame(width: 54, height: 5)
                    RoundedRectangle(cornerRadius: 2).fill(line).frame(width: 38, height: 5)
                    RoundedRectangle(cornerRadius: 2).fill(line).frame(width: 46, height: 5)
                }
                .padding(9)
            }
        }
    }
}

/// The trailing region of the "Auto" swatch: a slightly slanted vertical split so
/// the dark pane occupies the right side over the light pane.
private struct DiagonalSplit: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.58, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.width * 0.42, y: rect.maxY))
        path.closeSubpath()
        return path
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
                AppearanceModePicker(selection: $settings.appearanceMode)
            } header: {
                SectionHeaderLabel(title: "Appearance")
            } footer: {
                Text("Pin termio to a light or dark look, or follow the system. The light and dark terminal themes below apply to the matching appearance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                FontFamilyField(
                    title: "Family",
                    prompt: "System monospace",
                    families: InstalledFonts.monospaced,
                    previewSize: settings.fontSize,
                    monospacedDefault: true,
                    family: $settings.fontFamily
                )
                Stepper(value: $settings.fontSize, in: 8...32, step: 1) {
                    Text("Size: \(Int(settings.fontSize)) pt")
                }
                Toggle("Thicken glyphs", isOn: $settings.fontThicken)
            } header: {
                SectionHeaderLabel(title: "Font")
            }
            Section {
                Picker("Style", selection: $settings.cursorStyle) {
                    ForEach(CursorStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                Toggle("Blink", isOn: $settings.cursorBlink)
            } header: {
                SectionHeaderLabel(title: "Cursor")
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
                SectionHeaderLabel(title: "Window")
            } footer: {
                Text("Opacity below 100% lets the desktop show through; blur softens it. The window stays solid at full opacity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                themePicker(title: "Light", selection: $settings.lightThemeName)
                themePicker(title: "Dark", selection: $settings.darkThemeName)
            } header: {
                SectionHeaderLabel(title: "Theme")
            } footer: {
                Text("termio switches between these as macOS changes appearance. Leave a slot on the default for termio's own light or dark canvas.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func themePicker(title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("Terminal default").tag("")
            Divider()
            ForEach(themeNames, id: \.self) { name in
                Text(name).tag(name)
            }
        }
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
                    previewSize: settings.interfaceFontSize,
                    monospacedDefault: false,
                    family: $settings.interfaceFontFamily
                )
                Stepper(value: $settings.interfaceFontSize, in: 9...20, step: 1) {
                    Text("Size: \(Int(settings.interfaceFontSize)) pt")
                }
            } header: {
                SectionHeaderLabel(title: "Sidebar font")
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
                SectionHeaderLabel(title: "Density")
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
                SectionHeaderLabel(title: "History")
            } footer: {
                Text("How much output each session keeps for scrolling back. Agents are verbose, so the default is generous.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Copy on select", isOn: $settings.copyOnSelect)
            } header: {
                SectionHeaderLabel(title: "Selection")
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
            Section {
                Toggle(isOn: $settings.agentHooksEnabled) {
                    HStack(spacing: 10) {
                        IconBadge(symbol: "dot.radiowaves.left.and.right")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Live agent status")
                                .font(.headline)
                            Text("Installs hooks for Claude Code, Codex, OpenCode, and Pi so termio can tell when an agent is working or waiting on you — shown as the spinning sidebar icon and the menu-bar pulse. Adds termio's own entries to each agent's config; turning this off removes them. (Codex needs a one-time /hooks trust.)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .toggleStyle(.switch)
                if settings.agentHooksEnabled {
                    // For re-applying after the user (or another tool) has edited
                    // ~/.claude/settings.json; install is idempotent.
                    Button("Reinstall hooks") { AgentStatusHooks.sync(enabled: true) }
                }
            } header: {
                SectionHeaderLabel(title: "Status")
            }
            Section {
                Toggle(isOn: $settings.sessionControlEnabled) {
                    HStack(spacing: 10) {
                        IconBadge(symbol: "arrow.triangle.branch")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Session control")
                                .font(.headline)
                            Text("Lets an agent see and drive its sibling sessions in the same project with the `termio sessions` command (list, send a prompt, answer a menu, start, stop). Scoped to the current project. Adds a short awareness note to the agents' instruction files; turning this off removes it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .toggleStyle(.switch)
                if settings.sessionControlEnabled {
                    Button("Reinstall note") { SessionSkillInstaller.sync(enabled: true) }
                }
            } header: {
                SectionHeaderLabel(title: "Orchestration")
            }
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
                SectionHeaderLabel(title: "Location")
            }
            .disabled(!settings.worktreeEnabled)
        }
        .formStyle(.grouped)
    }
}
