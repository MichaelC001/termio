import AppKit
import SwiftUI

// MARK: - Git pane

/// The git pane, split into two tabs after GitHub Desktop: **Changes** (the working
/// tree's files, with a checkbox that stages/unstages each one for real and a click that
/// opens its diff over the terminal) and **History** (past commits and their diffs).
/// Committing and pushing are deliberately left to the terminal — the GUI is for staging,
/// reviewing, and reading, not authoring commits. The list rows match the file tree (same
/// interface font and `SidebarRowHighlight`). All state lives in `GitPanelModel`.
struct GitChangesView: View {
    @EnvironmentObject var store: TermioStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    let repoRoot: String
    /// Lifted up to `FileBrowserView` so the switcher's Changes badge stays in step.
    @Binding var changeCount: Int

    @StateObject private var model: GitPanelModel

    /// Which of the two tabs is showing.
    @State private var mode: GitPaneMode = .changes

    /// The file a "Discard Changes…" action is waiting to confirm — non-nil while the
    /// destructive alert is up, so the actual `git restore`/delete only fires on "OK".
    @State private var pendingDiscard: GitChange?

    init(repoRoot: String, changeCount: Binding<Int>) {
        self.repoRoot = repoRoot
        self._changeCount = changeCount
        self._model = StateObject(wrappedValue: GitPanelModel(repoRoot: repoRoot))
    }

    private var chrome: ChromeTheme? { settings.chromeTheme(for: colorScheme) }

    var body: some View {
        VStack(spacing: 0) {
            switch mode {
            case .changes: changesBody
            case .history: GitHistoryView(model: model, repoRoot: repoRoot, chrome: chrome, font: settings.interfaceFont)
            }
            bottomBar
        }
        .task(id: repoRoot) { await model.load() }
        .task(id: mode) { if mode == .history { await model.loadHistory() } }
        .onChange(of: model.changes.count) { _, count in changeCount = count }
        // Re-read when a diff overlay closes — the user may have just acted on it.
        .onChange(of: store.openDiff) { _, request in
            if request == nil { Task { await model.load() } }
        }
        .alert("Discard Changes?", isPresented: discardAlertPresented, presenting: pendingDiscard) { change in
            Button("Discard Changes", role: .destructive) { performDiscard(change) }
            Button("Cancel", role: .cancel) { pendingDiscard = nil }
        } message: { change in
            Text("All changes to “\(change.name)” will be lost. This cannot be undone.")
        }
    }

    // MARK: Changes tab

    @ViewBuilder
    private var changesBody: some View {
        if model.isLoading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.changes.isEmpty {
            // Fill the pane (like the loading state) rather than sizing to the compact empty
            // view — otherwise the enclosing `VStack` shrinks to content height and the host
            // centers the whole pane instead of pinning the header to the top.
            ContentUnavailableView(
                "No Changes",
                systemImage: "checkmark.circle",
                description: Text("The working tree is clean.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            changeList
        }
    }

    /// The pane's mode switch, pinned at the *bottom* (Xcode's version-editor jump bar):
    /// `Changes | History` on the left with the active mode lit in the chrome accent, and
    /// refresh on the right — above a full-width hairline that splits it from the content.
    private var bottomBar: some View {
        HStack(spacing: 8) {
            switchButton("Changes", .changes)
            Divider().frame(height: 12)
            switchButton("History", .history)
            Spacer(minLength: 8)
            TreeHeaderButton(systemName: "arrow.clockwise", help: "Refresh") {
                Task {
                    if mode == .changes { await model.load() }
                    else { await model.loadHistory(force: true) }
                }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
    }

    private func switchButton(_ title: String, _ value: GitPaneMode) -> some View {
        let active = mode == value
        return Button {
            mode = value
        } label: {
            Text(title)
                .font(.system(size: 11.5, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? AnyShapeStyle(chrome?.accent ?? Color.accentColor) : AnyShapeStyle(.secondary))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var changeList: some View {
        // A native `List` with a `selection:` binding — the same shape as the file tree
        // (`FileTreeList`). Selection drives "open the diff", which is what lets each row be
        // `.draggable` at the same time: a SwiftUI tap gesture would strangle the drag, but
        // List's AppKit-level selection coexists with it. The checkbox is a `Button`, so it
        // toggles staging without also opening the diff.
        List(model.changes, selection: selectedPath) { change in
            GitChangeRow(
                change: change,
                fileURL: fileURL(for: change),
                font: settings.interfaceFont,
                chrome: chrome,
                isSelected: store.openDiff?.change.path == change.path && store.openDiff?.commit == nil,
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
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
    }

    private func open(_ change: GitChange) {
        // An image/SVG/PDF has no meaningful text diff, so show the file itself in the preview
        // overlay. A deleted file is gone from disk, so fall back to the diff (its empty result
        // is the honest one).
        let url = fileURL(for: change)
        if FileActivation.previewsRatherThanDiff(url), FileManager.default.fileExists(atPath: url.path) {
            store.openFileInEditor(url)
        } else {
            store.openDiff = GitDiffRequest(repoRoot: repoRoot, change: change)
        }
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
            await model.load()
        }
    }

    private var discardAlertPresented: Binding<Bool> {
        Binding(get: { pendingDiscard != nil }, set: { if !$0 { pendingDiscard = nil } })
    }

    /// The absolute on-disk URL for a change — `git status` paths are repo-relative.
    private func fileURL(for change: GitChange) -> URL {
        URL(fileURLWithPath: repoRoot).appendingPathComponent(change.path)
    }

    /// Bridges List selection to the open diff: the selected row is whichever change is
    /// currently open, and selecting a row opens it. Bound by `GitChange.ID` (the path) —
    /// List tags rows with the element's `id`, so a selection binding of any other type
    /// never fires. Deselection is ignored — closing the diff is the overlay's own job.
    private var selectedPath: Binding<String?> {
        Binding(
            get: {
                if let diff = store.openDiff, diff.commit == nil { return diff.change.path }
                // Image/SVG/PDF changes open in the preview overlay, not the diff — match the
                // open file back to its row so the selection stays put while it's up.
                if let open = store.openFileURL?.standardizedFileURL,
                   let change = model.changes.first(where: { fileURL(for: $0).standardizedFileURL == open }) {
                    return change.path
                }
                return nil
            },
            set: { path in
                if let change = model.changes.first(where: { $0.path == path }) { open(change) }
            }
        )
    }
}

/// A single row in the changes list: a colored status letter, the file name (dimmed when
/// deleted), and right-aligned `+adds −dels`. `.draggable` out as the file's URL. Opening
/// is the List's own `selection:` binding, not a tap gesture, which is what keeps the drag
/// immediate; the discard control is a `Button`, so it acts without triggering the row's
/// open-diff selection.
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
