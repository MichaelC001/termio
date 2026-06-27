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
        .navigationTitle("")
        .toolbar { titleToolbar }
        // Hide the toolbar's opaque fill so the title bar is fully transparent: over
        // the sidebar the vibrant material shows through (no grey strip / seam above
        // the first row), and over the terminal the surface shows through. Without
        // this, the unified toolbar paints an opaque band across the whole top that
        // doesn't match the translucent sidebar beneath it.
        .toolbarBackground(.hidden, for: .windowToolbar)
        .onChange(of: store.selectedSessionID, initial: true) { _, id in
            if let id, !activated.contains(id) {
                activated.append(id)
            }
            focusedSession = id
        }
    }

    /// The project title and branch, shown at the leading edge of the title bar.
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
}
