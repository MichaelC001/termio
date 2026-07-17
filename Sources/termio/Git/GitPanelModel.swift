import SwiftUI

// MARK: - Git-pane state

/// Owns the mutable state of the git pane: the working-tree change list, the commit
/// history, and which of the two the pane is showing. termio's git pane is a *reading*
/// surface — you review working-tree diffs and read history; committing, pushing, and
/// pull requests all live in the terminal (`git commit` / `git push` / `gh`), where the
/// user already works. Discarding a file is the one working-tree edit it offers.
///
/// One instance lives per repo root (the view is given a fresh identity via `.id(repoRoot)`
/// when the selected project changes), so `repoRoot` is fixed for the model's lifetime.
@MainActor
final class GitPanelModel: ObservableObject {
    let repoRoot: String

    @Published var changes: [GitChange] = []
    @Published var isLoading = true

    /// The commit history, loaded lazily the first time the History tab is shown.
    @Published var commits: [GitCommit] = []
    @Published var isLoadingHistory = false
    private var didLoadHistory = false

    init(repoRoot: String) { self.repoRoot = repoRoot }

    // MARK: Loading

    /// Reloads the working-tree change list.
    func load() async {
        changes = await GitService.changes(in: repoRoot)
        isLoading = false
    }

    /// Loads the commit history on demand (first time the History tab opens), and can be
    /// re-run by the refresh button.
    func loadHistory(force: Bool = false) async {
        guard force || !didLoadHistory else { return }
        didLoadHistory = true
        isLoadingHistory = true
        commits = await GitService.log(in: repoRoot)
        isLoadingHistory = false
    }
}
