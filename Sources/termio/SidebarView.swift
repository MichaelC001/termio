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
    // The terminal theme is split light/dark and libghostty tracks the system
    // appearance; the chrome borrows whichever side is currently showing.
    @Environment(\.colorScheme) private var colorScheme
    // Which projects are folded shut. Held here, not in ProjectHeader, because the
    // header and the session rows are sibling parts of the same Section — only the
    // parent can both toggle the chevron and omit the collapsed project's rows.
    @State private var collapsedProjects: Set<Project.ID> = []

    // Chrome colors borrowed from the selected terminal theme; `nil` keeps the
    // default system look untouched.
    private var chrome: ChromeTheme? { settings.chromeTheme(for: colorScheme) }

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
        // Drop SwiftUI's automatic sidebar toggle: on macOS 26 it carries a resting
        // Liquid Glass capsule that reads as a permanent filled background. A flat
        // replacement is supplied below that fires the same `toggleSidebar:` action,
        // so the collapse animation is unchanged.
        .toolbar(removing: .sidebarToggle)
        .toolbar { sidebarToggleToolbar }
    }

    /// The sidebar toggle, pinned to the trailing edge of the sidebar's own title-bar
    /// region (top-right of the column, just left of the divider) rather than over in
    /// the terminal pane's title bar.
    /// On macOS 26 `sharedBackgroundVisibility(.hidden)` drops the default Liquid
    /// Glass capsule so it sits flat over the sidebar material, matching the title
    /// beside it.
    @ToolbarContentBuilder
    private var sidebarToggleToolbar: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .primaryAction) { sidebarToggle }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) { sidebarToggle }
        }
    }

    /// Replacement for SwiftUI's automatic sidebar toggle (removed above). It sends
    /// the standard `toggleSidebar:` up the responder chain so the native
    /// `NSSplitViewController` still drives the collapse — only the styling differs:
    /// no resting Liquid Glass capsule, just the hover highlight.
    private var sidebarToggle: some View {
        Button {
            NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
        } label: {
            Image(systemName: "sidebar.left")
        }
        .help("Toggle Sidebar")
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

/// A project's section header. The agent quick-add buttons float in a trailing
/// overlay rather than the row's flow, so at rest the label gets the full row width
/// (no premature truncation) and the buttons only paint over the trailing edge on
/// hover — like VSCode's explorer header actions. Each button immediately creates a
/// session of that agent type.
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
            // header label lines up with the session titles). The folder itself is
            // the open/closed affordance — an open folder when the project's sessions
            // are showing, a closed one when folded — so no separate chevron is
            // needed (clicking the header still toggles it).
            HugeIconView(
                icon: isCollapsed ? .folder : .folderOpen,
                size: 15,
                color: chrome?.foreground ?? .primary
            )
            .frame(width: 16)
            // A section header, but kept at the standard text color (not the muted
            // grey VSCode uses) so the project name reads clearly; the smaller,
            // uppercase, letter-spaced styling still sets it apart from session rows.
            Text(project.name)
                .font(.system(size: 11, weight: .medium))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(chrome.map { AnyShapeStyle($0.foreground) } ?? AnyShapeStyle(.primary))
            Spacer(minLength: 4)
        }
        // The hover actions sit in an overlay, not the HStack above, so they reserve
        // no width while hidden — the label keeps the whole row at rest. One brand
        // icon per enabled agent (a single click opens that agent, instantly
        // recognizable — the agents are few and visually distinct, so direct icons
        // beat a dropdown). The project's own rarer actions (Reveal in Finder, Remove
        // Project) live in the right-click context menu below rather than an inline
        // button, keeping the hover row to just the agent icons.
        .overlay(alignment: .trailing) {
            HStack(spacing: 3) {
                ForEach(enabledAgentPresets(settings)) { preset in
                    AgentQuickAddButton(preset: preset, chrome: chrome) {
                        store.addSession(to: project.id, agent: preset)
                    }
                }
            }
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { toggleCollapsed() }
        // Right-click mirrors the hover controls, so every action is reachable both
        // ways (the menus' contents are factored out so the two never drift).
        .contextMenu {
            NewSessionMenuItems(project: project)
            Divider()
            ProjectActionMenuItems(project: project)
        }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .animation(.easeInOut(duration: 0.18), value: isCollapsed)
    }
}

/// The agents a project header offers as new sessions: every preset the user has
/// left enabled, in preset order.
@MainActor
private func enabledAgentPresets(_ settings: AppSettings) -> [AgentPreset] {
    AgentPreset.allCases.filter(settings.isAgentEnabled)
}

/// The "New … Session" buttons shared by the header's agent picker (the split
/// button's chevron) and its right-click menu, so the two lists can never diverge.
private struct NewSessionMenuItems: View {
    @EnvironmentObject var store: TermioStore
    @EnvironmentObject var settings: AppSettings
    let project: Project

    var body: some View {
        ForEach(enabledAgentPresets(settings)) { preset in
            Button("New \(preset.displayName) Session") {
                store.addSession(to: project.id, agent: preset)
            }
        }
    }
}

/// The project's own actions, shared by the header's overflow (⋯) menu and its
/// right-click menu. "Remove Project" drops only the sidebar entry — the folder and
/// any worktrees stay on disk (see `TermioStore.removeProject`), so it is safe to
/// offer inline.
private struct ProjectActionMenuItems: View {
    @EnvironmentObject var store: TermioStore
    let project: Project

    var body: some View {
        Button("Reveal in Finder") {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path)
        }
        Divider()
        Button("Remove Project") { store.removeProject(project.id) }
    }
}

/// One agent quick-add button in a project header. It carries its own hover state
/// so only the button under the cursor lifts a rounded background — the same
/// per-control feedback VSCode/Finder give their inline header actions. A single
/// click immediately creates a session of that agent type.
private struct AgentQuickAddButton: View {
    let preset: AgentPreset
    let chrome: ChromeTheme?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            AgentIconView(agent: preset, size: 15)
                .frame(width: 22, height: 20)
                .background(hoverBackground(chrome, isHovering: isHovering))
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.1), value: isHovering)
        .help("New \(preset.displayName) session")
    }
}

/// The rounded hover lift shared by the header's inline action controls: a faint
/// fill of the theme foreground (or the system primary) under the cursor only.
private func hoverBackground(_ chrome: ChromeTheme?, isHovering: Bool) -> some View {
    RoundedRectangle(cornerRadius: 5, style: .continuous)
        .fill((chrome?.foreground ?? .primary).opacity(isHovering ? 0.12 : 0))
}

/// The inline close action on a session row. Like `AgentQuickAddButton`, it owns
/// its hover state so the control lifts a rounded background under the cursor — the
/// per-action highlight VSCode gives the kill button on a terminal tab.
private struct SessionRowActionButton: View {
    let help: String
    let chrome: ChromeTheme?
    var isEnabled: Bool = true
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            // A filled circular glyph reads unambiguously as "remove this session"
            // (rather than the faint hairline x that disappeared into the row). At
            // rest it borrows the row's foreground; on hover it turns red so the
            // destructive action announces itself before the click.
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isHovering ? AnyShapeStyle(.red) : (chrome.map { AnyShapeStyle($0.foreground) } ?? AnyShapeStyle(.secondary)))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.1), value: isHovering)
        .help(help)
        .disabled(!isEnabled)
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
            // While the agent is working, the leading mark becomes a small rotating
            // nine-dot grid — the row's own "thinking" spinner — and reverts to the
            // brand mark when the turn ends. No ambient tint on the brand mark: it
            // must keep its own vendor color (the same full-strength logo the
            // settings page shows), and the plain terminal symbol carries its own
            // muted grey from AgentIconView.
            Group {
                if store.status(for: session.id) == .working {
                    WorkingIndicator(tint: session.agent.tintColor)
                } else {
                    AgentIconView(agent: session.agent, size: 13)
                }
            }
            .frame(width: 16)
            .help(store.statusDescription(for: session.id))
            Text(store.displayTitle(for: session))
                .font(settings.interfaceFont)
                .foregroundStyle(chrome.map { AnyShapeStyle($0.foreground) } ?? AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            // At rest a status dot trails the title only when the session needs the
            // user (working is shown by the leading spinner instead), so the title
            // keeps nearly the whole row width. The hover actions live in the overlay
            // below and reserve no flow width of their own.
            StatusDot(status: store.status(for: session.id))
                .frame(width: 16)
                .opacity(isHovering ? 0 : 1)
                .help(store.statusDescription(for: session.id))
        }
        // VSCode-style trailing action: hovering paints a close button over the
        // trailing edge (where the status dot was), reserving no resting width.
        .overlay(alignment: .trailing) {
            SessionRowActionButton(
                help: "Close session",
                chrome: chrome
            ) {
                store.closeSession(session.id)
            }
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
        }
        .padding(.vertical, settings.interfaceRowPadding)
        // Indent the session content under its project header so the rows read as
        // a child group of the project rather than a flat sibling list. The
        // selection highlight (listRowBackground) stays full-width — the standard
        // macOS source-list look where children inset but the lift spans the row.
        .padding(.leading, 16)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { store.selectedSessionID = session.id }
        .contextMenu {
            Button("Close Session") { store.closeSession(session.id) }
        }
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
            // Working is shown by the leading spinner and idle shows nothing, so
            // only the two resting "your turn" states trail the title as a dot:
            // green when the agent just finished, orange when it's blocked on you.
            .opacity(status == .done || status == .needsAttention ? 1 : 0)
    }

    private var color: Color {
        status == .needsAttention ? .orange : .green
    }
}

/// The "agent is working" mark: a 3×3 grid of dots with a bright comet that orbits
/// the eight perimeter cells, so the small nine-square grid reads as rotating. Sits
/// in place of the session's brand icon while a turn is in flight (see `SessionRow`).
private struct WorkingIndicator: View {
    var tint: Color = .secondary

    /// The eight perimeter cells of the 3×3 grid in clockwise order, as
    /// `(column, row)` with the center at `(1, 1)`. The comet travels this ring.
    private static let ring: [(Int, Int)] = [
        (0, 0), (1, 0), (2, 0), (2, 1), (2, 2), (1, 2), (0, 2), (0, 1),
    ]
    private let dotSize: CGFloat = 2.3
    private let spacing: CGFloat = 3.6
    private let period: Double = 1.1

    var body: some View {
        TimelineView(.animation) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: period) / period
            ZStack {
                // A faint steady center anchors the spinning ring.
                dot(opacity: 0.3)
                ForEach(Array(Self.ring.enumerated()), id: \.offset) { index, cell in
                    dot(opacity: opacity(at: index, phase: phase))
                        .offset(
                            x: CGFloat(cell.0 - 1) * spacing,
                            y: CGFloat(cell.1 - 1) * spacing
                        )
                }
            }
            .frame(width: 13, height: 13)
        }
    }

    private func dot(opacity: Double) -> some View {
        Circle()
            .fill(tint)
            .frame(width: dotSize, height: dotSize)
            .opacity(opacity)
    }

    /// Brightness of a perimeter cell: peaks at the comet's head and fades over the
    /// next few cells, measured as the shorter way around the ring so the tail wraps.
    private func opacity(at index: Int, phase: Double) -> Double {
        let count = Double(Self.ring.count)
        let head = phase * count
        let raw = abs(Double(index) - head)
        let distance = min(raw, count - raw)
        return max(0.22, 1 - distance / 3)
    }
}
