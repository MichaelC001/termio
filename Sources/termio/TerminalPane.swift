import AppKit
import SwiftUI
import GhosttyTerminal

extension Notification.Name {
    /// Posted by the toolbar's close button to dismiss whichever content overlay (file editor,
    /// diff, or preview) covers the terminal. `TerminalPane` handles it, running the same teardown
    /// — clear the store, hand focus back to the terminal — the overlays' own Esc / close use, so
    /// the toolbar and in-overlay close paths stay identical.
    static let termioCloseContentOverlay = Notification.Name("termio.closeContentOverlay")
}

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
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedSession: Session.ID?
    @State private var activated: [Session.ID] = []
    @State private var isDropTargeted = false

    /// The wash painted over the terminal while a file is dragged onto it. The old fill was a flat
    /// `accentColor.opacity(0.18)`, which read as a heavy, saturated blue. This is a much softer,
    /// desaturated blue-grey: barely-there in light mode, a touch stronger in dark so it still
    /// registers over a dark terminal without looking like a solid panel.
    private var dropTint: Color {
        colorScheme == .dark
            ? Color(.sRGB, red: 0.62, green: 0.70, blue: 0.82, opacity: 0.10)
            : Color(.sRGB, red: 0.40, green: 0.52, blue: 0.68, opacity: 0.09)
    }

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
        // Paint the terminal's own background behind the pane, extending up under the toolbar so
        // the system toolbar material picks up a terminal tint instead of a flat grey band.
        .background(paneBackground.ignoresSafeArea(.container, edges: .top))
        // A VSCode-style drop overlay: just a translucent accent wash over the whole
        // terminal while a file is dragged over it (their `terminal-dropBackground`) —
        // no border, only the background tint, fading in and out.
        .overlay {
            if isDropTargeted {
                dropTint
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
        // Double-clicking a file in the inspector covers the terminal pane with it (the surface
        // keeps running underneath): an image/PDF/HTML in a read-only preview, anything else in the
        // editor. Escape or the close button clears it and hands focus back to the selected session.
        .overlay {
            if let url = store.openFileURL {
                let onClose = {
                    store.openFileURL = nil
                    focusedSession = store.selectedSessionID
                }
                Group {
                    if FileActivation.isPreviewable(url) {
                        FilePreviewView(url: url, settings: settings, onClose: onClose)
                    } else {
                        FileEditorView(url: url, settings: settings,
                                       readOnly: store.openFileReadOnly, onClose: onClose)
                    }
                }
                .id(url)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: store.openFileURL)
        // Clicking a row in the inspector's Changes pane covers the terminal with that file's
        // unified diff (the surface keeps running underneath), the git counterpart of the editor
        // overlay above. Escape or the close button clears it.
        .overlay {
            if let request = store.openDiff {
                GitDiffView(request: request, settings: settings, onClose: {
                    store.openDiff = nil
                    focusedSession = store.selectedSessionID
                })
                .id(request)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: store.openDiff)
        // Dropping a file (dragged from the file-tree inspector or the Finder) inserts
        // its shell-quoted path at the prompt — the prebuilt libghostty surface does not
        // register for file drops itself, so the pane catches them and feeds the path to
        // the selected session's surface. No trailing return, so the path is inserted for
        // the user (or the agent) to act on rather than run.
        .dropDestination(for: URL.self) { urls, _ in
            sendPaths(urls)
        } isTargeted: { isDropTargeted = $0 }
        .onChange(of: store.selectedSessionID, initial: true) { _, id in
            if let id, !activated.contains(id) {
                activated.append(id)
            }
            // Switching sessions returns to the terminal: dismiss any open file editor so the
            // newly selected session's surface is what's shown (the overlay's `.onDisappear`
            // flushes any pending auto-save first). The diff overlay is dismissed for the same reason.
            store.openFileURL = nil
            store.openDiff = nil
            focusedSession = id
        }
        // The toolbar's close button posts this; tear the overlay down the same way the overlay's
        // own Esc / close does (clear the store, return focus to the selected session's terminal).
        .onReceive(NotificationCenter.default.publisher(for: .termioCloseContentOverlay)) { _ in
            store.openFileURL = nil
            store.openDiff = nil
            focusedSession = store.selectedSessionID
        }
    }

    /// Inserts the dropped files' paths into the selected session's terminal,
    /// space-separated and each shell-quoted so spaces and other special characters
    /// survive. Focuses the session first (VSCode's focus-on-drop), and if its shell
    /// isn't attached yet, activates the session so its surface mounts and retries
    /// once it has come up. Returns whether a drop was accepted at all.
    private func sendPaths(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty,
              let id = store.selectedSessionID,
              let session = store.session(id),
              let project = store.project(for: id) else { return false }
        focusedSession = id
        let text = urls.map { Self.shellQuoted($0.path) }.joined(separator: " ") + " "
        if store.surface(for: session, in: project).send(text) { return true }

        // The shell may not be attached yet (a freshly opened session whose surface
        // hasn't mounted). Activating it mounts the surface; retry a moment later, once.
        store.selectedSessionID = id
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            if !store.surface(for: session, in: project).send(text) {
                NSLog("termio: dropped path could not be sent — %@ has no live terminal", session.title)
            }
        }
        return true
    }

    /// Single-quotes a path for the shell, escaping any embedded single quote the
    /// POSIX way (`'\''`), so a dropped path is always one safe token.
    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
