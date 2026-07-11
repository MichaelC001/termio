import AppKit
import SwiftUI

// MARK: - Changes list

/// The git "Changes" pane: a flat list of every changed file in the selected
/// session's repo, each a status badge + name + `+`/`−` counts. Clicking a row opens
/// its diff over the terminal (`store.openDiff`). Styled to match the file tree — the
/// same interface font and `SidebarRowHighlight` — so the two panes read as one.
struct GitChangesView: View {
    @EnvironmentObject var store: TermioStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    let repoRoot: String
    /// Lifted up to `FileBrowserView` so the switcher's Changes badge stays in step.
    @Binding var changeCount: Int

    @State private var changes: [GitChange] = []
    @State private var isLoading = true
    /// The file a "Discard Changes…" action is waiting to confirm — non-nil while the
    /// destructive alert is up, so the actual `git restore`/delete only fires on "OK".
    @State private var pendingDiscard: GitChange?

    private var chrome: ChromeTheme? { settings.chromeTheme(for: colorScheme) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if changes.isEmpty {
                // Fill the pane (like the loading state) rather than sizing to the compact empty
                // view — otherwise the enclosing `VStack` shrinks to content height and the host
                // centers the whole pane, dropping the "CHANGES" header into the middle of the
                // inspector instead of pinning it to the top.
                ContentUnavailableView(
                    "No Changes",
                    systemImage: "checkmark.circle",
                    description: Text("The working tree is clean.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // A native `List` with a `selection:` binding — the same shape as the file
                // tree (`FileTreeList`). Selection drives "open the diff", which is what lets
                // each row be `.draggable` at the same time: a SwiftUI tap gesture would
                // strangle the drag, but List's AppKit-level selection coexists with it.
                List(changes, selection: selectedPath) { change in
                    GitChangeRow(
                        change: change,
                        fileURL: fileURL(for: change),
                        font: settings.interfaceFont,
                        chrome: chrome,
                        isSelected: store.openDiff?.change.path == change.path,
                        onDiscard: { pendingDiscard = change }
                    )
                    .contextMenu {
                        Button("Open in Editor") { openInEditor(change) }
                        Button("Reveal in Finder") { revealInFinder(change) }
                        Divider()
                        Button("Copy Path") { copyPath(change) }
                        Button("Copy Relative Path") { copyToPasteboard(change.path) }
                        Button("Copy Diff") { copyDiff(change) }
                        Divider()
                        Button("Discard Changes…", role: .destructive) { pendingDiscard = change }
                    }
                }
                // `.plain`, not `.sidebar`: the sidebar style pads every row with its own
                // leading margin (on top of our zeroed `listRowInsets`), pushing the rows
                // out of line with the header above. This list is flat — no disclosure
                // chevrons to make room for — so plain keeps row text at the same 14pt
                // leading edge as the header.
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 1)
            }
        }
        .task(id: repoRoot) { await reload() }
        // Re-read when a diff overlay closes — the user may have just acted on it.
        .onChange(of: store.openDiff) { _, request in
            if request == nil { Task { await reload() } }
        }
        .alert("Discard Changes?", isPresented: discardAlertPresented, presenting: pendingDiscard) { change in
            Button("Discard Changes", role: .destructive) { performDiscard(change) }
            Button("Cancel", role: .cancel) { pendingDiscard = nil }
        } message: { change in
            Text("All changes to “\(change.name)” will be lost. This cannot be undone.")
        }
    }

    /// The current branch (from the live `BranchModel`) and a refresh button, mirroring
    /// the file tree's own header.
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(store.branchModel.branch(for: repoRoot) ?? "Changes")
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            TreeHeaderButton(systemName: "arrow.clockwise", help: "Refresh") {
                Task { await reload() }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
    }

    private func reload() async {
        let loaded = await GitService.changes(in: repoRoot)
        changes = loaded
        changeCount = loaded.count
        isLoading = false
    }

    private func open(_ change: GitChange) {
        store.openDiff = GitDiffRequest(repoRoot: repoRoot, change: change)
    }

    // MARK: Row actions

    /// Opens the file's editable buffer over the terminal (distinct from clicking the
    /// row, which shows its read-only diff).
    private func openInEditor(_ change: GitChange) {
        store.openFileInEditor(fileURL(for: change))
    }

    private func revealInFinder(_ change: GitChange) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL(for: change)])
    }

    private func copyPath(_ change: GitChange) {
        copyToPasteboard(fileURL(for: change).path)
    }

    /// Puts the file's raw unified diff on the pasteboard — ready to paste into an agent
    /// prompt ("fix this") or `git apply`.
    private func copyDiff(_ change: GitChange) {
        Task { copyToPasteboard(await GitService.diffText(for: change, in: repoRoot)) }
    }

    private func copyToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    /// Runs the confirmed discard off the main thread, closes the diff overlay if it was
    /// showing the file we just reverted, then reloads so the row drops out of the list.
    private func performDiscard(_ change: GitChange) {
        pendingDiscard = nil
        Task {
            await GitService.discard(change, in: repoRoot)
            if store.openDiff?.change.path == change.path { store.openDiff = nil }
            await reload()
        }
    }

    private var discardAlertPresented: Binding<Bool> {
        Binding(get: { pendingDiscard != nil }, set: { if !$0 { pendingDiscard = nil } })
    }

    /// The absolute on-disk URL for a change — `git status` paths are repo-relative.
    /// Dragged out of a row and dropped on the terminal, which shell-quotes it at the
    /// prompt (see `TerminalPane.sendPaths`).
    private func fileURL(for change: GitChange) -> URL {
        URL(fileURLWithPath: repoRoot).appendingPathComponent(change.path)
    }

    /// Bridges List selection to the open diff: the selected row is whichever change is
    /// currently open, and selecting a row opens it. Bound by `GitChange.ID` (the path) —
    /// List tags rows with the element's `id`, so a selection binding of any other type
    /// never fires (the original `Binding<GitChange?>` compiled but made rows unclickable).
    /// Deselection is ignored — closing the diff is the overlay's own job, not a click-away.
    private var selectedPath: Binding<String?> {
        Binding(
            get: { store.openDiff?.change.path },
            set: { path in
                if let change = changes.first(where: { $0.path == path }) { open(change) }
            }
        )
    }
}

/// A single row in the changes list: a colored status letter, the file name (dimmed
/// when deleted), and right-aligned `+adds −dels`. `.draggable` out as the file's URL —
/// dropped on the terminal it becomes a shell-quoted path (see `TerminalPane`). Opening
/// is the List's own `selection:` binding, not a tap gesture, which is what keeps the
/// drag immediate (a SwiftUI tap gesture on a `.draggable` row makes it sticky).
private struct GitChangeRow: View {
    let change: GitChange
    let fileURL: URL
    let font: Font
    let chrome: ChromeTheme?
    let isSelected: Bool
    /// Fires the discard confirmation for this row (owned by `GitChangesView`).
    let onDiscard: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(change.status.letter)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(change.status.tint)
                .frame(width: 14)
            Text(change.name)
                .font(font)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(change.status == .deleted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            Spacer(minLength: 6)
            // On hover the trailing +/− counts give way to a single discard button — the
            // one destructive action worth a one-click affordance (everything else lives
            // in the right-click menu). The counts return when the pointer leaves.
            if isHovering {
                Button(action: onDiscard) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Discard Changes…")
            } else if change.additions > 0 || change.deletions > 0 {
                HStack(spacing: 5) {
                    if change.additions > 0 { Text("+\(change.additions)").foregroundStyle(.green) }
                    if change.deletions > 0 { Text("−\(change.deletions)").foregroundStyle(.red) }
                }
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .opacity(0.85)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // Strip the source list's blue selection fill at the AppKit layer, leaving our own
        // `SidebarRowHighlight` as the sole selection cue — the file tree does the same.
        .background(OutlineSelectionStyleStripper())
        .draggable(fileURL)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(
            SidebarRowHighlight(isSelected: isSelected, isHovering: isHovering, chrome: chrome)
                .animation(.easeInOut(duration: 0.12), value: isSelected)
                .animation(.easeInOut(duration: 0.12), value: isHovering)
        )
        .onHover { isHovering = $0 }
        .help(change.path)
    }
}
