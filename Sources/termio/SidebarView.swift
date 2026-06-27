import SwiftUI
import AppKit

extension AppSettings {
    /// The sidebar text font built from the interface preferences. An empty family
    /// falls back to the system UI font at the chosen size, so a font the user
    /// doesn't have installed is never forced.
    var interfaceFont: Font {
        interfaceFontFamily.isEmpty
            ? .system(size: interfaceFontSize)
            : .custom(interfaceFontFamily, size: interfaceFontSize)
    }
}

private extension View {
    /// Paints the themed sidebar panel color, hiding the native list background so
    /// the theme color reads instead of the vibrant material. With no theme the view
    /// is returned untouched so the native `.sidebar` material shows through.
    @ViewBuilder
    func themedSidebarBackground(_ chrome: ChromeTheme?) -> some View {
        if let chrome {
            scrollContentBackground(.hidden)
                .background(chrome.panelBackground.ignoresSafeArea())
        } else {
            self
        }
    }
}

/// Left column: projects, each a section containing its sessions. Hovering a
/// project header reveals VSCode-style quick-add buttons (one per agent preset).
struct SidebarView: View {
    @EnvironmentObject var store: TermioStore
    @EnvironmentObject var settings: AppSettings
    // Which projects are folded shut. Held here, not in ProjectHeader, because the
    // header and the session rows are sibling parts of the same Section — only the
    // parent can both toggle the chevron and omit the collapsed project's rows.
    @State private var collapsedProjects: Set<Project.ID> = []

    // Chrome colors borrowed from the selected terminal theme; `nil` keeps the
    // default system look untouched.
    private var chrome: ChromeTheme? { settings.chromeTheme }

    var body: some View {
        // Selection is driven by row taps rather than List's `selection:` binding
        // so we can paint our own frosted-grey highlight. The system selection
        // forces an edge-to-edge accent fill (and white text) that can't be
        // restyled without also draining the row's other accent-tinted controls.
        // A flat list rather than `Section`s: the sidebar's section spacing leaves
        // a big empty band between a collapsed project's header and the next, and
        // macOS has no `listSectionSpacing`. The header carries its own grouping
        // weight (small-caps label + folder mark), so folded projects stack tight.
        List {
            ForEach(store.projects) { project in
                ProjectHeader(
                    project: project,
                    isCollapsed: collapsedProjects.contains(project.id),
                    toggleCollapsed: { toggleCollapsed(project.id) },
                    chrome: chrome
                )
                if !collapsedProjects.contains(project.id) {
                    ForEach(project.sessions) { session in
                        SessionRow(session: session, chrome: chrome)
                    }
                }
            }
        }
        // Hosted via NSHostingController (see App.swift), so this is a standard
        // macOS source list — exactly NetNewsWire's layout: the window's toolbar row
        // holds the traffic lights and the system sidebar toggle, and the list sits
        // naturally below it. The sidebar material (native vibrancy, or a theme's
        // panel color) runs full-height and bleeds behind the traffic lights. No
        // safe-area juggling: the toolbar row is simply the top of the window.
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 1)
        .themedSidebarBackground(chrome)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
    }

    private func toggleCollapsed(_ id: Project.ID) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if collapsedProjects.contains(id) {
                collapsedProjects.remove(id)
            } else {
                collapsedProjects.insert(id)
            }
        }
    }
}

/// A project's section header. The agent quick-add buttons are always laid out
/// but stay invisible until the row is hovered (revealed via opacity, not
/// insertion, so the hover region never shifts) — like VSCode's explorer header
/// actions. Each button immediately creates a session of that agent type.
private struct ProjectHeader: View {
    @EnvironmentObject var store: TermioStore
    @EnvironmentObject var settings: AppSettings
    let project: Project
    let isCollapsed: Bool
    let toggleCollapsed: () -> Void
    let chrome: ChromeTheme?
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            // Same 16-wide icon slot and spacing as SessionRow, so the folder mark
            // and the session icons below it share one vertical column (and the
            // header label lines up with the session titles).
            HugeIconView(icon: .folder, size: 13, color: chrome?.secondaryForeground ?? .secondary)
                .frame(width: 16)
            // VSCode's section headers are the quietest text on screen — small,
            // uppercase, letter-spaced and muted — so the eye lands on the
            // sessions, not the group labels.
            Text(project.name)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(chrome.map { AnyShapeStyle($0.secondaryForeground) } ?? AnyShapeStyle(.secondary))
            // Disclosure chevron, right after the name like Codex's project rows:
            // points down when open, right when folded. The whole header toggles
            // too, so this is the visible affordance rather than the only hit area.
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(chrome.map { AnyShapeStyle($0.foreground.opacity(0.4)) } ?? AnyShapeStyle(.tertiary))
                .rotationEffect(.degrees(isCollapsed ? -90 : 0))
            Spacer(minLength: 4)
            HStack(spacing: 3) {
                ForEach(AgentPreset.allCases.filter(settings.isAgentEnabled)) { preset in
                    AgentQuickAddButton(preset: preset, chrome: chrome) {
                        store.addSession(to: project.id, agent: preset)
                    }
                }
            }
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { toggleCollapsed() }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .animation(.easeInOut(duration: 0.18), value: isCollapsed)
    }
}

/// One agent quick-add button in a project header. It carries its own hover state
/// so only the button under the cursor lifts a rounded background — the same
/// per-control feedback VSCode/Finder give their inline header actions.
private struct AgentQuickAddButton: View {
    let preset: AgentPreset
    let chrome: ChromeTheme?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            AgentIconView(agent: preset, size: 15)
                .frame(width: 22, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill((chrome?.foreground ?? .primary).opacity(isHovering ? 0.12 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.1), value: isHovering)
        .help("New \(preset.displayName) session")
    }
}

/// A session row. Hovering reveals a close button on the trailing edge (same
/// opacity-reveal pattern as the project header).
private struct SessionRow: View {
    @EnvironmentObject var store: TermioStore
    @EnvironmentObject var settings: AppSettings
    let session: Session
    let chrome: ChromeTheme?
    @State private var isHovering = false

    private var isSelected: Bool { store.selectedSessionID == session.id }

    var body: some View {
        HStack(spacing: 6) {
            // No ambient tint here: a brand mark must keep its own vendor color
            // (the same full-strength logo the settings page shows), and the plain
            // terminal symbol carries its own muted grey from AgentIconView.
            AgentIconView(agent: session.agent, size: 13)
                .frame(width: 16)
            Text(store.displayTitle(for: session))
                .font(settings.interfaceFont)
                .foregroundStyle(chrome.map { AnyShapeStyle($0.foreground) } ?? AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            // The trailing slot shows the live status dot at rest and swaps to a
            // close button on hover, so both share one fixed-width position.
            ZStack {
                StatusDot(status: store.status(for: session.id))
                    .opacity(isHovering ? 0 : 1)
                Button {
                    store.closeSession(session.id)
                } label: {
                    Image(systemName: "xmark")
                        .imageScale(.small)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Close session")
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
            }
            .frame(width: 18, height: 18)
        }
        .padding(.vertical, settings.interfaceRowPadding)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { store.selectedSessionID = session.id }
        .listRowBackground(
            SidebarRowHighlight(isSelected: isSelected, isHovering: isHovering, chrome: chrome)
                .animation(.easeInOut(duration: 0.12), value: isSelected)
                .animation(.easeInOut(duration: 0.12), value: isHovering)
        )
        .animation(.easeInOut(duration: 0.12), value: isHovering)
    }
}

/// The frosted-grey lift behind a session row. Selection reads as a translucent
/// "liquid glass" material (frosted, not a saturated accent fill) so the row text
/// stays primary and the eye lands on content; hover is a fainter grey, clearly
/// lighter than selection so the two states never blur together.
private struct SidebarRowHighlight: View {
    let isSelected: Bool
    let isHovering: Bool
    let chrome: ChromeTheme?

    var body: some View {
        if let chrome {
            themed(chrome)
        } else {
            system
        }
    }

    /// The default frosted-grey lift. The material reads only faintly over the
    /// already-blurred sidebar, so a grey tint carries most of the lift; selection
    /// sits a clear step above hover. Fill only — no border, so the row reads as a
    /// soft highlight rather than an outlined chip.
    private var system: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(.ultraThinMaterial)
            .opacity(isSelected ? 1 : 0)
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(fillOpacity))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
    }

    /// The themed lift: a translucent wash of the theme's accent so the active
    /// session reads as accent-tinted (VSCode's active list item), with hover a
    /// fainter step below selection. Fill only — no border.
    private func themed(_ chrome: ChromeTheme) -> some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(chrome.accent.opacity(accentOpacity))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
    }

    private var fillOpacity: Double {
        if isSelected { return 0.09 }
        if isHovering { return 0.045 }
        return 0
    }

    private var accentOpacity: Double {
        if isSelected { return 0.22 }
        if isHovering { return 0.10 }
        return 0
    }
}

/// A small coloured dot mirroring the menu-bar pulse: hidden when idle, amber
/// when the session wants attention, blue while working.
private struct StatusDot: View {
    let status: SessionStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(status == .idle ? 0 : 1)
    }

    private var color: Color {
        switch status {
        case .idle: return .clear
        case .working: return .blue
        case .needsAttention: return .orange
        }
    }
}
