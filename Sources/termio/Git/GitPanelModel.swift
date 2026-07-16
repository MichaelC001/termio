import SwiftUI

// MARK: - Changes-pane state

/// Owns the mutable state of the git "Changes" pane: the change list, which files are
/// checked for the next commit, the draft message, and the push / pull-request status.
/// The reads in `GitService`/`GHService` stay stateless — this is the one place that
/// holds the "ship it" workflow together.
///
/// One instance lives per repo root (the view is given a fresh identity via `.id(repoRoot)`
/// when the selected project changes), so `repoRoot` is fixed for the model's lifetime.
@MainActor
final class GitPanelModel: ObservableObject {
    let repoRoot: String

    @Published var changes: [GitChange] = []
    /// Repo-relative paths checked to go into the next commit. New files arrive checked;
    /// a file the user unchecks stays unchecked across reloads until it disappears.
    @Published var selected: Set<String> = []
    @Published var isLoading = true

    @Published var message = ""
    @Published var isCommitting = false

    /// Whether an agent CLI (claude/codex) is available to write commit messages — gates
    /// the ✨ button, which is simply absent otherwise.
    @Published var aiAvailable = false
    @Published var isGenerating = false

    @Published var upstream: GitUpstream = .none
    @Published var isPushing = false

    /// Whether `gh` is installed and authenticated. Everything PR-related is hidden when
    /// this is false — no nag, just absent.
    @Published var ghAvailable = false
    @Published var pullRequest: PullRequestInfo?
    @Published var defaultBranch = "main"

    /// A transient one-line status shown under the commit box — an error from a failed
    /// action, or a success note. Cleared on the next action.
    @Published var banner: Banner?

    struct Banner: Equatable { enum Kind { case error, success }; let kind: Kind; let text: String }

    /// Tracks which paths we have already seen, so a reload can tell genuinely-new files
    /// (auto-checked) from ones the user deliberately unchecked (left unchecked).
    private var knownPaths: Set<String> = []
    private var didLoadOnce = false

    init(repoRoot: String) { self.repoRoot = repoRoot }

    var selectedCount: Int { selected.count }
    var canCommit: Bool {
        !isCommitting && !selected.isEmpty && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func isChecked(_ change: GitChange) -> Bool { selected.contains(change.path) }

    func toggle(_ change: GitChange) {
        if selected.contains(change.path) { selected.remove(change.path) }
        else { selected.insert(change.path) }
    }

    // MARK: Loading

    /// Reloads the change list and, in the background, the push and PR status. Selection is
    /// preserved: kept boxes stay checked, vanished files drop out, and files that appeared
    /// since the last load start checked.
    func load() async {
        let loaded = await GitService.changes(in: repoRoot)
        let paths = Set(loaded.map(\.path))
        if !didLoadOnce {
            selected = paths                       // first load: everything checked
            didLoadOnce = true
        } else {
            let appeared = paths.subtracting(knownPaths)
            selected = selected.intersection(paths).union(appeared)
        }
        knownPaths = paths
        changes = loaded
        isLoading = false

        upstream = await GitService.upstreamState(in: repoRoot)
        if !aiAvailable { aiAvailable = await AICommitMessage.isAvailable() }
        let available = await GHService.isAvailable(in: repoRoot)
        ghAvailable = available
        guard available else { pullRequest = nil; return }
        async let pr = GHService.pullRequest(in: repoRoot)
        async let base = GHService.defaultBranch(in: repoRoot)
        pullRequest = await pr
        defaultBranch = await base
    }

    /// Refreshes only the push/PR status — after a commit or push, without re-scanning the
    /// (now-changed) working tree twice.
    func refreshRemoteState() async {
        upstream = await GitService.upstreamState(in: repoRoot)
        guard ghAvailable else { return }
        pullRequest = await GHService.pullRequest(in: repoRoot)
    }

    // MARK: Actions

    func commit() async {
        let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canCommit else { return }
        isCommitting = true
        banner = nil
        let result = await GitService.commit(message: msg, paths: Array(selected), in: repoRoot)
        isCommitting = false
        switch result {
        case .success:
            message = ""
            await load()
            banner = Banner(kind: .success, text: "Committed.")
        case .failure(let error):
            banner = Banner(kind: .error, text: error)
        }
    }

    /// Fills the message box from the checked files' diffs via the agent CLI. The result
    /// is editable — never committed automatically.
    func generateMessage() async {
        guard !isGenerating, !selected.isEmpty else { return }
        isGenerating = true
        banner = nil
        let picked = changes.filter { selected.contains($0.path) }
        var parts: [String] = []
        for change in picked {
            parts.append(await GitService.diffText(for: change, in: repoRoot))
        }
        let result = await AICommitMessage.generate(diff: parts.joined(separator: "\n"))
        isGenerating = false
        switch result {
        case .success(let text): message = text
        case .failure(let error): banner = Banner(kind: .error, text: error)
        }
    }

    func push() async {
        guard !isPushing else { return }
        isPushing = true
        banner = nil
        let result = await GitService.push(in: repoRoot)
        isPushing = false
        switch result {
        case .success:
            await refreshRemoteState()
            banner = Banner(kind: .success, text: "Pushed.")
        case .failure(let error):
            banner = Banner(kind: .error, text: error)
        }
    }
}
