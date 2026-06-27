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
struct TerminalPane: View {
    @EnvironmentObject var store: TermioStore
    @EnvironmentObject var settings: AppSettings
    @FocusState private var focusedSession: Session.ID?
    @State private var activated: [Session.ID] = []

    var body: some View {
        ZStack {
            if mounted.isEmpty {
                ContentUnavailableView("No session selected", systemImage: "terminal")
            }
            ForEach(mounted, id: \.session.id) { item in
                let isSelected = store.selectedSessionID == item.session.id
                TerminalSurfaceView(context: store.surface(for: item.session, in: item.project))
                    .terminalFocused($focusedSession, equals: item.session.id)
                    .opacity(isSelected ? 1 : 0)
                    .allowsHitTesting(isSelected)
            }
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
    }

    /// The project title and branch at the leading edge of the title bar. The sidebar
    /// toggle lives over the sidebar column (see `SidebarView`), so the title bar
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
            Text(selectedProject?.name ?? "Termio")
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
