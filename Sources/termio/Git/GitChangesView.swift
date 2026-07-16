import AppKit
import SwiftUI

// MARK: - Changes list

/// The git "Changes" pane: the working tree's changed files plus the "ship it" footer —
/// check the files, write a message, commit, push, and open a pull request without
/// leaving the diff you just reviewed. The list rows match the file tree (same interface
/// font and `SidebarRowHighlight`); clicking a row still opens its diff over the terminal.
/// All state lives in `GitPanelModel`; `GitService`/`GHService` stay stateless.
struct GitChangesView: View {
    @EnvironmentObject var store: TermioStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    let repoRoot: String
    /// Lifted up to `FileBrowserView` so the switcher's Changes badge stays in step.
    @Binding var changeCount: Int

    @StateObject private var model: GitPanelModel

    /// The file a "Discard Changes…" action is waiting to confirm — non-nil while the
    /// destructive alert is up, so the actual `git restore`/delete only fires on "OK".
    @State private var pendingDiscard: GitChange?
    @State private var showPRSheet = false

    init(repoRoot: String, changeCount: Binding<Int>) {
        self.repoRoot = repoRoot
        self._changeCount = changeCount
        self._model = StateObject(wrappedValue: GitPanelModel(repoRoot: repoRoot))
    }

    private var chrome: ChromeTheme? { settings.chromeTheme(for: colorScheme) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.changes.isEmpty {
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
                changeList
                CommitFooter(model: model, showPRSheet: $showPRSheet, chrome: chrome) { url in
                    openURL(URL(string: url) ?? URL(fileURLWithPath: "/"))
                }
            }
        }
        .task(id: repoRoot) { await model.load() }
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
        .sheet(isPresented: $showPRSheet) {
            CreatePRSheet(model: model) { url in openURL(URL(string: url) ?? URL(fileURLWithPath: "/")) }
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
                Task { await model.load() }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
    }

    private var changeList: some View {
        // A native `List` with a `selection:` binding — the same shape as the file tree
        // (`FileTreeList`). Selection drives "open the diff", which is what lets each row be
        // `.draggable` at the same time: a SwiftUI tap gesture would strangle the drag, but
        // List's AppKit-level selection coexists with it. The checkbox is a `Button`, so it
        // toggles the commit selection without also opening the diff.
        List(model.changes, selection: selectedPath) { change in
            GitChangeRow(
                change: change,
                fileURL: fileURL(for: change),
                font: settings.interfaceFont,
                chrome: chrome,
                isSelected: store.openDiff?.change.path == change.path,
                isChecked: model.isChecked(change),
                onToggle: { model.toggle(change) },
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
            get: { store.openDiff?.change.path },
            set: { path in
                if let change = model.changes.first(where: { $0.path == path }) { open(change) }
            }
        )
    }
}

/// A single row in the changes list: a commit checkbox, a colored status letter, the file
/// name (dimmed when deleted), and right-aligned `+adds −dels`. `.draggable` out as the
/// file's URL. Opening is the List's own `selection:` binding, not a tap gesture, which is
/// what keeps the drag immediate; the checkbox and discard controls are `Button`s, so they
/// act without triggering the row's open-diff selection.
private struct GitChangeRow: View {
    let change: GitChange
    let fileURL: URL
    let font: Font
    let chrome: ChromeTheme?
    let isSelected: Bool
    let isChecked: Bool
    let onToggle: () -> Void
    /// Fires the discard confirmation for this row (owned by `GitChangesView`).
    let onDiscard: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12))
                    .foregroundStyle(isChecked ? AnyShapeStyle(chrome?.accent ?? .accentColor) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .help(isChecked ? "Exclude from commit" : "Include in commit")

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
