import AppKit
import SwiftUI
import GhosttyTerminal

/// Right column. Every session that has been opened stays *mounted* here for the
/// app's lifetime; switching sessions only flips opacity and keyboard focus.
///
/// The earlier design swapped the visible terminal with `.id(session.id)`, which
/// made SwiftUI destroy the old surface view and build a fresh one on every
/// switch. A fresh `TerminalView` lays out from a zero frame, so libghostty calls
/// `ghostty_surface_set_size` — a SIGWINCH the shell answers by repainting its
/// prompt. That resize-on-every-switch was the visible flicker. Keeping each
/// surface mounted and only toggling visibility means the view is never
/// reparented or resized, so the shell never repaints and switching is instant.
///
/// Split view preserves that invariant: it never moves surfaces between containers
/// (which would reparent and resize them). Every surface is laid out by hand in one
/// `ZStack` — the visible one or two get an explicit frame, the rest stay full-size
/// behind them at zero opacity. So a plain session switch still changes no frame and
/// stays flicker-free; only entering or leaving a split — an explicit action —
/// intentionally resizes the two affected panes.
struct TerminalPane: View {
    @EnvironmentObject var store: TermioStore
    @EnvironmentObject var settings: AppSettings
    @FocusState private var focusedSession: Session.ID?
    @State private var activated: [Session.ID] = []
    /// Fraction of the pane width given to the left split pane, dragged via the
    /// divider. Clamped so neither side can be squeezed to nothing.
    @State private var splitFraction: CGFloat = 0.5

    private let coordinateSpace = "termio.pane"
    private static let dividerHitWidth: CGFloat = 8
    private static let minFraction: CGFloat = 0.15

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if mounted.isEmpty {
                    ContentUnavailableView("No session selected", systemImage: "terminal")
                }
                ForEach(mounted, id: \.session.id) { item in
                    let layout = paneLayout(for: item.session.id, in: geometry.size)
                    TerminalSurfaceView(context: store.surface(for: item.session, in: item.project))
                        .terminalFocused($focusedSession, equals: item.session.id)
                        .frame(width: layout.width, height: geometry.size.height)
                        .offset(x: layout.xOffset)
                        .opacity(layout.isVisible ? 1 : 0)
                        .allowsHitTesting(layout.isVisible)
                }
                if store.isSplit {
                    SplitDivider(hitWidth: Self.dividerHitWidth, height: geometry.size.height)
                        .offset(x: (geometry.size.width * splitFraction).rounded() - Self.dividerHitWidth / 2)
                        .gesture(
                            DragGesture(coordinateSpace: .named(coordinateSpace))
                                .onChanged { value in
                                    let fraction = value.location.x / geometry.size.width
                                    splitFraction = min(max(fraction, Self.minFraction), 1 - Self.minFraction)
                                }
                        )
                }
            }
            .coordinateSpace(name: coordinateSpace)
        }
        // Paint the terminal's own background behind the pane, extending up under the
        // transparent title bar. The title bar paints nothing of its own, so it
        // borrowed the window's background color — which works in a window but not in
        // native full screen, where AppKit reasserts a system-white toolbar material
        // over the chrome. A real colored surface up to the top edge gives the title
        // bar a matching fill in both modes. Skipped while translucent so a low-opacity
        // background and Ghostty's blur still reveal the desktop.
        .background(paneBackground.ignoresSafeArea(.container, edges: .top))
        .navigationTitle("")
        .toolbar { titleToolbar }
        // Fill the title bar with the terminal background instead of letting the
        // system draw it. When the window is opaque the title bar must read as the
        // exact terminal color so it sits flush with the surface below. Hiding the
        // toolbar fill used to achieve that — the transparent bar revealed the
        // `#F7F7F7` painted up behind it — but on macOS 26 the Liquid Glass title-bar
        // material is no longer suppressed by `.hidden` and resolves to system white,
        // leaving a seam over the terminal. Painting the bar the terminal color
        // overrides that material. Stays `.hidden` while translucent so a low-opacity
        // background and Ghostty's blur still reveal the desktop through the bar.
        .modifier(TitleBarFill(translucent: isTranslucent, fill: paneBackground))
        .onChange(of: store.selectedSessionID, initial: true) { _, id in
            if let id, !activated.contains(id) {
                activated.append(id)
            }
            focusedSession = id
        }
        // Both panes of a split must be mounted, even a companion the user never
        // selected, so its surface exists to render beside the focused one.
        .onChange(of: store.splitSessionIDs, initial: true) { _, split in
            for id in split ?? [] where !activated.contains(id) {
                activated.append(id)
            }
        }
        // Clicking a pane makes its surface first responder; mirror that into the
        // selection so the sidebar highlight and title follow the focused pane.
        .onChange(of: focusedSession) { _, id in
            guard let id, store.splitSessionIDs?.contains(id) == true,
                  store.selectedSessionID != id else { return }
            store.selectedSessionID = id
        }
    }

    /// The project title and branch at the leading edge of the title bar. The
    /// sidebar toggle lives over the sidebar column (see `SidebarView`), and splitting
    /// is driven per-session from the sidebar rows (VSCode-style), so the title bar
    /// carries no controls of its own.
    /// On macOS 26 a toolbar item is wrapped in a Liquid Glass capsule by default;
    /// `sharedBackgroundVisibility(.hidden)` drops that so the title sits flat on the
    /// window surface, matching the terminal content. Earlier systems draw no such
    /// backing, so the plain item is already flat there.
    @ToolbarContentBuilder
    private var titleToolbar: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .navigation) { titleLabel }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) { titleLabel }
        }
    }

    private var titleLabel: some View {
        HStack(spacing: 6) {
            Text(selectedProject?.name ?? "termio")
                .fontWeight(.semibold)
            if let project = selectedProject {
                HugeIconView(icon: .gitBranch, size: 13, color: .secondary)
                Text(project.branch)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 13))
    }

    private struct MountedSession {
        let project: Project
        let session: Session
    }

    /// Where a surface sits in the pane: a full-width single view, one half of a
    /// split, or a hidden full-size surface kept mounted behind the visible ones.
    /// Hidden surfaces keep the full width on purpose — that way toggling a split
    /// never resizes them, only the two panes that actually become visible.
    private struct PaneLayout {
        var width: CGFloat
        var xOffset: CGFloat
        var isVisible: Bool
    }

    private func paneLayout(for id: Session.ID, in size: CGSize) -> PaneLayout {
        guard let split = store.splitSessionIDs, split.count == 2 else {
            return PaneLayout(width: size.width, xOffset: 0, isVisible: store.selectedSessionID == id)
        }
        let gap: CGFloat = 1
        let leftWidth = (size.width * splitFraction).rounded()
        if id == split[0] {
            return PaneLayout(width: max(0, leftWidth), xOffset: 0, isVisible: true)
        }
        if id == split[1] {
            return PaneLayout(width: max(0, size.width - leftWidth - gap), xOffset: leftWidth + gap, isVisible: true)
        }
        return PaneLayout(width: size.width, xOffset: 0, isVisible: false)
    }

    /// The sessions to keep on screen: every activated id that still resolves to a
    /// live session (closed sessions drop out, which unmounts their surface).
    private var mounted: [MountedSession] {
        activated.compactMap { id in
            guard let session = store.session(id), let project = store.project(for: id) else { return nil }
            return MountedSession(project: project, session: session)
        }
    }

    private var selectedProject: Project? {
        store.selectedSessionID.flatMap { store.project(for: $0) }
    }

    /// True when the user has dialed the background below full opacity or enabled
    /// blur, so the surface, window, and title bar must stay see-through.
    private var isTranslucent: Bool {
        settings.backgroundOpacity < 1.0 || settings.backgroundBlur > 0
    }

    /// The terminal background fill, or clear when translucent — then the surface and
    /// window stay see-through.
    private var paneBackground: Color {
        isTranslucent ? .clear : Color(nsColor: settings.terminalBackgroundColor)
    }
}

/// Paints the window title bar to match the terminal: a solid terminal-colored fill
/// when opaque, hidden when translucent so the desktop and Ghostty's blur still show
/// through. See the call site for why `.hidden` alone no longer suffices on macOS 26.
private struct TitleBarFill: ViewModifier {
    let translucent: Bool
    let fill: Color

    func body(content: Content) -> some View {
        if translucent {
            content.toolbarBackground(.hidden, for: .windowToolbar)
        } else {
            content.toolbarBackground(fill, for: .windowToolbar)
        }
    }
}

/// The draggable seam between two split panes: a hairline at rest, brightening and
/// thickening under the cursor, with a resize cursor over its hit area.
private struct SplitDivider: View {
    let hitWidth: CGFloat
    let height: CGFloat
    @State private var isHovering = false

    var body: some View {
        Color.clear
            .frame(width: hitWidth, height: height)
            .overlay(
                Rectangle()
                    .fill(Color.primary.opacity(isHovering ? 0.25 : 0.1))
                    .frame(width: isHovering ? 2 : 1)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .animation(.easeInOut(duration: 0.1), value: isHovering)
    }
}
