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
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(changes) { change in
                            GitChangeRow(
                                change: change,
                                font: settings.interfaceFont,
                                chrome: chrome,
                                isSelected: store.openDiff?.change.path == change.path,
                                onOpen: { open(change) }
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .task(id: repoRoot) { await reload() }
        // Re-read when a diff overlay closes — the user may have just acted on it.
        .onChange(of: store.openDiff) { _, request in
            if request == nil { Task { await reload() } }
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
}

/// A single row in the changes list: a colored status letter, the file name (dimmed
/// when deleted), and right-aligned `+adds −dels`. Plain SwiftUI hover/tap — unlike
/// the file tree, these rows are not `.draggable`, so a tap gesture is safe.
private struct GitChangeRow: View {
    let change: GitChange
    let font: Font
    let chrome: ChromeTheme?
    let isSelected: Bool
    let onOpen: () -> Void

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
            if change.additions > 0 || change.deletions > 0 {
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
        .background(
            SidebarRowHighlight(isSelected: isSelected, isHovering: isHovering, chrome: chrome)
                .animation(.easeInOut(duration: 0.12), value: isSelected)
                .animation(.easeInOut(duration: 0.12), value: isHovering)
        )
        .onHover { isHovering = $0 }
        .onTapGesture { onOpen() }
        .help(change.path)
    }
}
