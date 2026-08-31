import TermioShared
import AppKit
import Combine
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
    /// The machine `repoRoot` lives on, when it is not this Mac. A device
    /// checkout is driven the other way round from a local one: the box already
    /// watches its own workspace and publishes status deltas, so the pane
    /// subscribes and applies them instead of running `git status` on a timer.
    /// This is the shape Zed pushes as `UpdateRepository` and VS Code gets by
    /// running the git extension on the remote — nobody polls a remote checkout.
    let device: TermiodRoute?

    @Published var changes: [GitChange] = []
    @Published var isLoading = true

    /// Whether `repoRoot` is a git work tree. A loose terminal's cwd follows the shell,
    /// so the pane is regularly pointed at a folder git knows nothing about; without
    /// this the empty change list would render as "the working tree is clean". Starts
    /// `true` so the first pass shows the spinner rather than flashing the non-repo
    /// state, and is only ever lowered by a completed probe.
    @Published private(set) var isRepository = true

    /// The commit history, loaded lazily the first time the History tab is shown.
    @Published var commits: [GitCommit] = []
    @Published var isLoadingHistory = false
    private var didLoadHistory = false

    /// The branch and the refs it can be compared against, for the Compare tab's base
    /// picker. Nil until that tab is first opened; re-read whenever the git dir changes,
    /// so a checkout in the terminal moves the picker with it.
    @Published var compareContext: GitService.CompareContext?
    /// The base the Compare tab is measuring the branch against.
    @Published private(set) var compareBase: String?
    /// `nil` while a comparison is loading — the Compare tab shows a spinner then, so no
    /// separate loading flag is needed.
    @Published private(set) var compare: GitService.BranchCompare?
    /// Why the comparison couldn't be made, when it couldn't. Held as its own state so the
    /// pane can say so — an empty file list would read as "nothing to review".
    @Published private(set) var compareProblem: GitService.CompareProblem?

    private var watcher: FolderEventStream?
    private var appActiveObserver: AnyCancellable?
    private var refreshDebounce: Task<Void, Never>?
    /// Monotonic ticket for `load()` — only the newest pass may publish.
    private var loadGeneration = 0
    /// One `git status` in flight at a time: `load()` sets `loading` while it runs,
    /// and any call that lands mid-pass (the FSEvents debounce *or* a direct
    /// `model.load()` from the view) sets `loadReentered` to request a single
    /// replay instead of spawning an overlapping, expensive status — the way VS
    /// Code serializes its own status.
    private var loading = false
    private var loadReentered = false

    /// Whether the pane is actually on screen, read live at refresh time. A collapsed
    /// inspector keeps this model alive (the hosting view stays in the hierarchy), and
    /// before this gate the file-system watch kept re-running `git status` — four git
    /// spawns a burst — for a pane nobody could see. `nil` when the caller has no
    /// visibility signal; treated as visible.
    private let isPaneVisible: (() -> Bool)?
    /// A refresh that arrived while hidden, replayed on the next `flushDeferredRefresh`.
    /// Deferred, not dropped — the pane must be correct the moment it shows.
    private var deferredRefreshIncludesHistory: Bool?

    /// Directory names whose events can't change what the pane shows: build products
    /// and package caches that are gitignored in practice. An agent's `swift build`
    /// writes thousands of files under `.build`, and every burst was a full change-list
    /// pass; dropping these keeps the watch quiet through builds. Only components
    /// *below a watched root* count — a repo that itself lives under a directory
    /// named like a build product must not go deaf to every event. A repo that
    /// actually tracks one of these still stays honest — any event outside the list,
    /// and app re-activation, reload from git, the source of truth.
    private nonisolated static let ignoredEventComponents: Set<String> = [
        ".build", "node_modules", "DerivedData", ".venv", ".gradle", ".turbo", ".next",
    ]

    /// Whether an event path sits under a build-product directory *inside* one of the
    /// watched roots. The roots' own ancestry is deliberately not inspected.
    /// `nonisolated` because the FSEvents handler calls it on the watcher's own queue —
    /// it is pure string work over its arguments and touches no actor state.
    private nonisolated static func isBuildProductEvent(_ path: String, underAny roots: [String]) -> Bool {
        for root in roots where path == root || path.hasPrefix(root + "/") {
            return path.dropFirst(root.count).split(separator: "/")
                .contains { ignoredEventComponents.contains(String($0)) }
        }
        // An event outside every watched root (FSEvents shouldn't produce one)
        // stays relevant rather than being silently swallowed.
        return false
    }

    init(repoRoot: String, device: TermiodRoute? = nil, isPaneVisible: (() -> Bool)? = nil) {
        self.repoRoot = repoRoot
        self.device = device
        self.isPaneVisible = isPaneVisible
        // Re-activation catches whatever happened while termio was in the background
        // (a rebase in another app, a pull on another machine's shared folder…).
        // A device checkout needs no such catch-all: its watch runs on the box
        // and kept publishing while this app was not even in front.
        guard device == nil else { return }
        appActiveObserver = NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.scheduleRefresh(includeHistory: true) }
    }

    deinit { refreshDebounce?.cancel() }

    // MARK: The device's own status

    /// The subscription to `git:<root>` on the device, and the cursor into its
    /// batches — so a dropped channel resumes from the replay ring rather than
    /// re-reading a whole status.
    private var gitWatch: Termiod.ResourceSubscription?
    private var gitCursor: UInt64?
    private var resubscribing = false
    /// Orders the pieces of a subscribe handshake that reach the main actor on
    /// different paths — see `DeviceWatchLedger`.
    private var watchLedger = DeviceWatchLedger()
    /// The status the device has published so far, keyed by path. The batches
    /// are **deltas**, so the pane holds the baseline they apply to.
    private var deviceStatuses: [String: GitChange] = [:]
    /// What the device says the checkout's branch is, for a pane that wants to
    /// name it. Absent until the first batch lands.
    @Published private(set) var deviceBranch: String?

    /// Starts (or resumes) the device subscription. Idempotent: the pane calls
    /// it on appear and whenever it becomes visible again.
    func startDeviceWatch() {
        guard let device, gitWatch == nil, !resubscribing else { return }
        resubscribing = true
        let generation = watchLedger.begin()
        Task { [repoRoot] in
            defer { resubscribing = false }
            do {
                let (subscription, gap, seq) = try await Termiod.watchGit(
                    route: device,
                    root: repoRoot,
                    since: gitCursor,
                    onBatch: { [weak self] batch in
                        Task { @MainActor in self?.receive(batch, generation: generation) }
                    },
                    onInterrupted: { [weak self] in
                        Task { @MainActor in
                            self?.deviceWatchInterrupted(generation: generation)
                        }
                    })
                guard let earlyBatches = watchLedger.settle(generation: generation) else {
                    // The pane stopped (or restarted) the watch while this
                    // handshake was in flight; the subscription must not
                    // outlive the interest that asked for it.
                    subscription.cancel()
                    return
                }
                gitWatch = subscription
                // A gap means the ring could not replay from this cursor, so the
                // baseline is not trustworthy: drop it and let the device's
                // synthesized full batch rebuild it. The reset lands *before*
                // any batch applies — batches that raced the ack sat in the
                // ledger and apply below, so the full batch can never be erased
                // by its own gap reset.
                if gap {
                    deviceStatuses = [:]
                    gitCursor = nil
                } else {
                    gitCursor = max(gitCursor ?? 0, seq)
                }
                for batch in earlyBatches { apply(batch) }
                // The ack only says the device accepted the subscription; the
                // baseline follows a beat later (measured at 2 ms behind it).
                // Waiting for it is what keeps a repo with changes from flashing
                // "No Changes" — but a checkout that has nothing to say sends no
                // batch at all, and a spinner that never stops would be the
                // pane's answer to a clean tree. So: wait briefly, then settle.
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, self.watchLedger.generation == generation else { return }
                    self.isLoading = false
                }
            } catch {
                guard watchLedger.generation == generation else { return }
                isLoading = false
                deviceProblem = Self.message(for: error)
            }
        }
    }

    func stopDeviceWatch() {
        watchLedger.stop()
        gitWatch?.cancel()
        gitWatch = nil
    }

    /// Routes one arriving batch through the ledger: applied when the watch is
    /// settled, held when the handshake's baseline decision is still in
    /// flight, dropped when it belongs to a watch that was stopped.
    private func receive(_ batch: Termiod.GitChangedPayload, generation: Int) {
        guard let ready = watchLedger.admit(batch, generation: generation) else { return }
        apply(ready)
    }

    /// Why the device's git pane is empty, when it is empty for a reason. Held
    /// apart from the list so "no changes" and "not a git repository" cannot
    /// read as the same thing.
    @Published private(set) var deviceProblem: String?

    private func deviceWatchInterrupted(generation: Int) {
        guard watchLedger.generation == generation else { return }
        gitWatch = nil
        guard !resubscribing else { return }
        Task {
            // Let the drop settle before the next request reopens the channel.
            try? await Task.sleep(for: .seconds(1))
            startDeviceWatch()
        }
    }

    /// Applies one `git_changed` delta to the baseline the pane holds.
    private func apply(_ batch: Termiod.GitChangedPayload) {
        gitCursor = max(gitCursor ?? 0, batch.seq)
        for path in batch.removedPaths {
            deviceStatuses.removeValue(forKey: path)
        }
        for entry in batch.updatedStatuses {
            if let change = GitChange(device: entry) {
                deviceStatuses[entry.path] = change
            } else {
                // Ignored, or a status this build cannot draw: not a row.
                deviceStatuses.removeValue(forKey: entry.path)
            }
        }
        deviceBranch = batch.branch
        deviceProblem = nil
        changes = Self.sorted(Array(deviceStatuses.values))
        isLoading = false
    }

    /// Conflicts first — the one status that must be acted on — then by path, so
    /// siblings cluster the way the file tree shows them. The same order
    /// `GitService.loadChanges` puts a local list in.
    private static func sorted(_ changes: [GitChange]) -> [GitChange] {
        changes.sorted { first, second in
            if (first.status == .conflicted) != (second.status == .conflicted) {
                return first.status == .conflicted
            }
            return first.path.localizedCaseInsensitiveCompare(second.path) == .orderedAscending
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case DeviceGitError.unsupported:
            return localized("This device’s termiod is too old to read git.")
        case TermiodClientError.requestFailed(let detail) where !detail.isEmpty:
            return detail
        default:
            return localized("The device couldn’t read this checkout.")
        }
    }

    // MARK: Loading

    /// Reloads the working-tree change list. The first successful pass also arms the
    /// file-system watch, so from then on the pane refreshes itself.
    ///
    /// Serialized: only one `git status` runs at a time. Every refresh path funnels
    /// through here — the watcher and the view's direct `model.load()` calls alike —
    /// so a call that arrives mid-pass flags a replay rather than spawning an
    /// overlapping status. (Runs on the main actor, so the flags need no lock.)
    ///
    /// Immediate replays are capped at one. The first pass is suppressed if a reentry
    /// superseded it (its snapshot predates whatever change triggered the reentry —
    /// a discard, ignore, checkout); the single replay always publishes best-effort.
    /// If events *still* arrive through that replay — a continuously churning tree —
    /// we publish anyway and hand off to a debounced refresh instead of looping here,
    /// so the pane can never livelock (spinning `git status`, `isLoading` stuck on).
    func load() async {
        // A device checkout is not loaded, it is subscribed to: running `git` here
        // against a path on another machine would either fail or — worse — answer
        // about a same-named directory on this one.
        if device != nil {
            startDeviceWatch()
            return
        }
        if loading {
            loadReentered = true
            loadGeneration += 1   // supersede the in-flight pass's stale snapshot
            return
        }
        loading = true
        defer { loading = false }
        for attempt in 0...1 {
            loadReentered = false
            loadGeneration += 1
            let generation = loadGeneration
            let loaded = await GitService.changes(in: repoRoot)
            // A non-empty list is itself proof of a work tree, so the extra `rev-parse`
            // only runs for the ambiguous case — a clean repo or a plain folder.
            let repository = loaded.isEmpty ? await GitService.isWorkTree(at: repoRoot) : true
            if generation == loadGeneration || attempt == 1 {
                changes = loaded
                isRepository = repository
                isLoading = false
            }
            if watcher == nil { await armWatcher() }
            if !loadReentered { break }
        }
        if loadReentered {
            loadReentered = false
            scheduleRefresh(includeHistory: false)   // still churning: catch up off-stack
        }
    }

    /// Loads the commit history on demand (first time the History tab opens); re-run
    /// with `force` when the git dir reports a change.
    func loadHistory(force: Bool = false) async {
        // History and Compare are the device's read tier (`git.log`,
        // `git.branches`), which this pane does not ask for yet — so for a
        // device checkout their tabs are hidden rather than shown empty.
        guard device == nil else { return }
        guard force || !didLoadHistory else { return }
        didLoadHistory = true
        isLoadingHistory = commits.isEmpty
        commits = await GitService.log(in: repoRoot)
        isLoadingHistory = false
    }

    // MARK: Branch compare

    /// Re-reads the branch and the bases it can be compared against. Cheap enough to run
    /// on every history refresh: three `git` reads of refs, no diff.
    func loadCompareContext() async {
        guard device == nil else { return }
        compareContext = await GitService.compareContext(in: repoRoot)
    }

    /// Points the Compare tab at a base branch (or `nil` for none) and loads the
    /// comparison. The base itself is remembered by the view, per branch.
    func setCompareBase(_ base: String?) async {
        guard base != compareBase else { return }
        compareBase = base
        compare = nil
        compareProblem = nil
        await loadCompare()
    }

    /// Loads the diff and commits between the branch and its base. A base picked while a
    /// load is in flight wins: the stale result is dropped rather than published under the
    /// new base's label.
    func loadCompare() async {
        guard let base = compareBase else {
            compare = nil
            compareProblem = nil
            return
        }
        let outcome = await GitService.branchCompare(base: base, in: repoRoot)
        guard compareBase == base else { return }
        switch outcome {
        case .ready(let loaded):
            compare = loaded
            compareProblem = nil
        case .problem(let problem):
            compare = nil
            compareProblem = problem
        }
    }

    /// Replays a refresh that was deferred while the pane was hidden. Called by the
    /// view when the pane (re)appears, so the shown list is never stale.
    func flushDeferredRefresh() {
        guard let includeHistory = deferredRefreshIncludesHistory else { return }
        deferredRefreshIncludesHistory = nil
        scheduleRefresh(includeHistory: includeHistory)
    }

    // MARK: Auto-refresh

    /// The pane has no refresh button for the same reason IDEs don't: an invalidation
    /// chain keeps it fresh instead. Any write under the worktree re-reads the changes
    /// list; a write under the git dir (the terminal committing, the agent staging,
    /// a branch flip) also re-reads history; app re-activation is the catch-all. The
    /// git dirs are watched separately because a linked worktree's metadata lives
    /// outside the checkout — see `GitService.watchPaths`.
    private func armWatcher() async {
        guard device == nil else { return }
        let (tree, gitDirs) = await GitService.watchPaths(for: repoRoot)
        guard watcher == nil, !gitDirs.isEmpty else { return }
        // The primary checkout's `.git` sits inside the tree and needs no second watch.
        // Immutable, because the handler below runs off the main actor and captures it.
        let paths = [tree] + gitDirs.filter { !$0.hasPrefix(tree + "/") }
        watcher = FolderEventStream(
            paths: paths, latency: 0.4,
            queue: DispatchQueue(label: "sh.termio.gitpane.fsevents", qos: .utility)
        ) { [weak self] eventPaths, _ in
            // Runs on the FSEvents queue: everything up to the hop below must stay
            // off the main actor. Build-product churn can't change the pane; don't
            // let it spawn git.
            let relevant = eventPaths.filter { path in
                !Self.isBuildProductEvent(path, underAny: paths)
            }
            guard !relevant.isEmpty else { return }
            let touchesGitDir = relevant.contains { path in
                gitDirs.contains { path.hasPrefix($0) } || path.contains("/.git/") || path.hasSuffix("/.git")
            }
            Task { @MainActor [weak self] in
                self?.scheduleRefresh(includeHistory: touchesGitDir)
            }
        }
    }

    /// Coalesces a burst of events (FSEvents latency already batches most) into one
    /// reload a beat later. `git status` no longer echoes back as a git-dir event —
    /// `GIT_OPTIONAL_LOCKS=0` keeps it from writing the index — so the chain ends
    /// after one pass. While the pane is hidden the reload is parked instead (see
    /// `flushDeferredRefresh`).
    private func scheduleRefresh(includeHistory: Bool) {
        if let isPaneVisible, !isPaneVisible() {
            deferredRefreshIncludesHistory = (deferredRefreshIncludesHistory ?? false) || includeHistory
            return
        }
        refreshDebounce?.cancel()
        refreshDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.load()
            if includeHistory, self.didLoadHistory { await self.loadHistory(force: true) }
            // A commit, a checkout, or a fetch all land as git-dir events, and each one
            // moves the comparison: new commits ahead, a different branch, a base that
            // just gained commits. Gated on the Compare tab having been opened at least
            // once (which is what fills `compareContext`), like the log above — a
            // Changes-only session must not pay four `git` spawns an event.
            if includeHistory, self.compareContext != nil {
                await self.loadCompareContext()
                await self.loadCompare()
            }
        }
    }
}

// MARK: - Device-watch ordering

/// The ordering ledger for one device git watch.
///
/// A subscribe handshake resolves on two paths that both land on the main
/// actor: the ack (with its gap → reset-the-baseline decision) comes back
/// through the async call, while the first batches arrive through the
/// subscription handler — and the daemon queues the synthesized full batch
/// right behind the ack, so a batch can be applied *before* the gap reset that
/// would erase it, rendering a changed checkout clean. The ledger holds batches
/// until the baseline decision has landed, and stamps every attempt with a
/// generation so a watch that was stopped — or restarted — while its handshake
/// was in flight can neither install its subscription nor apply its batches.
struct DeviceWatchLedger {
    private(set) var generation = 0
    private var awaitingBaseline = false
    private var held: [Termiod.GitChangedPayload] = []

    /// A new subscribe attempt begins; everything older is dead.
    mutating func begin() -> Int {
        generation += 1
        awaitingBaseline = true
        held = []
        return generation
    }

    /// The watch was stopped; an in-flight attempt must not land.
    mutating func stop() {
        generation += 1
        awaitingBaseline = false
        held = []
    }

    /// Admits one arriving batch: returns it when the watch is settled and the
    /// batch may apply now, or nil when it was held for `settle` or belongs to
    /// a dead generation.
    mutating func admit(
        _ batch: Termiod.GitChangedPayload, generation: Int
    ) -> Termiod.GitChangedPayload? {
        guard generation == self.generation else { return nil }
        guard !awaitingBaseline else {
            held.append(batch)
            return nil
        }
        return batch
    }

    /// The ack landed and the caller is about to make the baseline decision.
    /// Returns the batches that raced ahead, in arrival order, to apply after
    /// that decision — or nil when the attempt is stale and must be abandoned.
    mutating func settle(generation: Int) -> [Termiod.GitChangedPayload]? {
        guard generation == self.generation else { return nil }
        awaitingBaseline = false
        defer { held = [] }
        return held
    }
}
