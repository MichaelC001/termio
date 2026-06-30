import AppKit
import Foundation
import SwiftUI

// MARK: - Models

/// Which inspector pane the trailing column is showing — the file tree or the git
/// changes list. Drives the segmented switch at the top of `FileBrowserView`.
enum InspectorTab: Hashable, Sendable {
    case files, changes
}

/// One changed file in the working tree, as reported by `git status`. `path` is
/// POSIX, relative to the repo root (so it may contain `/`); `name` is just the
/// last component for the row label.
struct GitChange: Identifiable, Hashable, Sendable {
    let path: String
    let status: GitFileStatus
    let isUntracked: Bool
    var additions: Int = 0
    var deletions: Int = 0

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

/// The change kind shown as a single-letter badge, colored after GitHub Desktop /
/// swifty-diff: modified blue, added green, deleted red, renamed/copied orange,
/// untracked grey, conflicted yellow.
enum GitFileStatus: Hashable, Sendable {
    case modified, added, deleted, renamed, copied, untracked, conflicted

    init(code: Character) {
        switch code {
        case "M", "T": self = .modified
        case "A": self = .added
        case "D": self = .deleted
        case "R": self = .renamed
        case "C": self = .copied
        case "U": self = .conflicted
        case "?": self = .untracked
        default: self = .modified
        }
    }

    var letter: String {
        switch self {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .conflicted: return "U"
        case .untracked: return "?"
        }
    }

    var tint: Color {
        switch self {
        case .added: return .green
        case .deleted: return .red
        case .renamed, .copied: return .orange
        case .conflicted: return .yellow
        case .untracked: return .gray
        case .modified: return .blue
        }
    }
}

/// A request to show the diff of one changed file over the terminal — the git
/// counterpart of `TermioStore.openFileURL`. Carries the repo root so the overlay
/// can run `git diff` for the file without re-deriving it.
struct GitDiffRequest: Hashable, Sendable {
    let repoRoot: String
    let change: GitChange

    var name: String { change.name }
}

/// One rendered line of a unified diff: an added/removed/context line (with its old
/// and/or new line number), or a hunk header (`@@ … @@`). The file-header lines of
/// the raw diff are dropped during parsing — the overlay shows the filename itself.
struct DiffRow: Identifiable, Sendable {
    enum Kind: Sendable { case addition, deletion, context, hunk }
    let id: Int
    let kind: Kind
    let text: String
    let oldLine: Int?
    let newLine: Int?
}

// MARK: - Git

/// Thin wrapper over the `git` CLI for the changes list and diff overlay. Every call
/// runs off the main thread (via `offMain`) and degrades to empty on any failure —
/// the same no-trap stance as `BranchModel`.
enum GitService {
    /// Changed files for a repo root, with their `+`/`−` counts filled in. Empty when
    /// the folder is not a git work tree.
    static func changes(in repoRoot: String) async -> [GitChange] {
        await offMain { loadChanges(repoRoot) }
    }

    /// The unified-diff rows for one changed file (staged + unstaged vs `HEAD`, or the
    /// whole file for an untracked one).
    static func diffRows(for change: GitChange, in repoRoot: String) async -> [DiffRow] {
        await offMain { parseDiff(loadDiffText(change, repoRoot)) }
    }

    // MARK: Loading

    private static func loadChanges(_ repoRoot: String) -> [GitChange] {
        guard run(["rev-parse", "--is-inside-work-tree"], in: repoRoot)?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "true",
            let raw = run(["status", "--porcelain=v2", "-z", "--untracked-files=all"], in: repoRoot)
        else { return [] }

        var changes = parseStatus(raw)
        applyCounts(&changes, repoRoot: repoRoot)
        return changes
    }

    /// Parses `git status --porcelain=v2 -z`. Records are NUL-separated; the path is
    /// always the *current* path, so renames (type `2`) carry the original path in the
    /// following NUL field, which is consumed and ignored.
    private static func parseStatus(_ raw: String) -> [GitChange] {
        let tokens = raw.components(separatedBy: "\0").filter { !$0.isEmpty }
        var result: [GitChange] = []
        var i = 0
        while i < tokens.count {
            let rec = tokens[i]
            i += 1
            guard let kind = rec.first else { continue }
            switch kind {
            case "1":
                let f = rec.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard f.count == 9 else { continue }
                result.append(make(xy: Array(f[1]), path: String(f[8]), untracked: false))
            case "2":
                let f = rec.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard f.count == 10 else { continue }
                if i < tokens.count { i += 1 } // skip the original path
                result.append(make(xy: Array(f[1]), path: String(f[9]), untracked: false))
            case "u":
                let f = rec.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard f.count == 11 else { continue }
                result.append(GitChange(path: String(f[10]), status: .conflicted, isUntracked: false))
            case "?":
                result.append(GitChange(path: String(rec.dropFirst(2)), status: .untracked, isUntracked: true))
            default:
                continue // "!" ignored entries
            }
        }
        return result
    }

    /// Builds a change from a porcelain-v2 `XY` field, where `.` means unmodified — the
    /// worktree side (`Y`) wins, falling back to the index side (`X`).
    private static func make(xy: [Character], path: String, untracked: Bool) -> GitChange {
        let x = xy.first ?? "."
        let y = xy.count > 1 ? xy[1] : "."
        let primary: Character = (y != ".") ? y : x
        return GitChange(path: path, status: GitFileStatus(code: primary), isUntracked: untracked)
    }

    /// Fills each change's add/delete counts: `git diff --numstat` (unstaged) merged
    /// with `--cached` (staged) for tracked files, and a line count for untracked ones.
    private static func applyCounts(_ changes: inout [GitChange], repoRoot: String) {
        var counts: [String: (Int, Int)] = [:]
        for args in [["diff", "--numstat"], ["diff", "--numstat", "--cached"]] {
            guard let out = run(args, in: repoRoot) else { continue }
            for line in out.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 2)
                guard parts.count == 3 else { continue }
                let adds = Int(parts[0]) ?? 0   // "-" for binary → 0
                let dels = Int(parts[1]) ?? 0
                let path = String(parts[2])
                let existing = counts[path] ?? (0, 0)
                counts[path] = (existing.0 + adds, existing.1 + dels)
            }
        }
        for idx in changes.indices {
            if changes[idx].isUntracked {
                let abs = (repoRoot as NSString).appendingPathComponent(changes[idx].path)
                if let content = try? String(contentsOfFile: abs, encoding: .utf8), !content.isEmpty {
                    changes[idx].additions = content.split(separator: "\n", omittingEmptySubsequences: false).count
                }
            } else if let c = counts[changes[idx].path] {
                changes[idx].additions = c.0
                changes[idx].deletions = c.1
            }
        }
    }

    private static func loadDiffText(_ change: GitChange, _ repoRoot: String) -> String {
        if change.isUntracked {
            // `--no-index` exits non-zero when the files differ, which is the normal
            // case here, so the status is ignored.
            return run(["diff", "--no-index", "--", "/dev/null", change.path],
                       in: repoRoot, ignoreStatus: true) ?? ""
        }
        // `diff HEAD` shows staged and unstaged together. Fall back to the split views
        // for a repo with no commit yet, or a fully-staged change.
        if let d = run(["diff", "HEAD", "--", change.path], in: repoRoot), !d.isEmpty { return d }
        let unstaged = run(["diff", "--", change.path], in: repoRoot) ?? ""
        if !unstaged.isEmpty { return unstaged }
        return run(["diff", "--cached", "--", change.path], in: repoRoot) ?? ""
    }

    /// Parses unified-diff text into rows, tracking old/new line numbers from each
    /// hunk header and dropping the file-header lines (`diff --git`, `+++`, …).
    private static func parseDiff(_ text: String) -> [DiffRow] {
        var rows: [DiffRow] = []
        var id = 0
        var oldNo = 0
        var newNo = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("@@") {
                if let (o, n) = parseHunkHeader(line) { oldNo = o; newNo = n }
                rows.append(DiffRow(id: id, kind: .hunk, text: line, oldLine: nil, newLine: nil)); id += 1
                continue
            }
            if isFileHeader(line) { continue }
            guard let first = line.first else { continue }
            let body = String(line.dropFirst())
            switch first {
            case "+":
                rows.append(DiffRow(id: id, kind: .addition, text: body, oldLine: nil, newLine: newNo)); id += 1; newNo += 1
            case "-":
                rows.append(DiffRow(id: id, kind: .deletion, text: body, oldLine: oldNo, newLine: nil)); id += 1; oldNo += 1
            case " ":
                rows.append(DiffRow(id: id, kind: .context, text: body, oldLine: oldNo, newLine: newNo)); id += 1; oldNo += 1; newNo += 1
            default:
                continue
            }
        }
        return rows
    }

    private static func isFileHeader(_ line: String) -> Bool {
        for prefix in ["diff ", "index ", "--- ", "+++ ", "new file", "deleted file",
                       "old mode", "new mode", "similarity ", "dissimilarity ",
                       "rename ", "copy ", "\\ "] where line.hasPrefix(prefix) {
            return true
        }
        return false
    }

    /// Pulls the starting old and new line numbers out of `@@ -a,b +c,d @@`.
    private static func parseHunkHeader(_ line: String) -> (Int, Int)? {
        let parts = line.split(separator: " ")
        guard parts.count >= 3 else { return nil }
        func start(_ s: Substring) -> Int? {
            Int(s.dropFirst().split(separator: ",").first ?? s.dropFirst())
        }
        guard let o = start(parts[1]), let n = start(parts[2]) else { return nil }
        return (o, n)
    }

    // MARK: Process

    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }

    /// Runs `git -C <dir> <args>` and returns stdout, or `nil` on launch failure (or a
    /// non-zero exit unless `ignoreStatus`). stdout is drained *before* `waitUntilExit`
    /// because a diff can exceed the 64 KB pipe buffer and otherwise deadlock the child;
    /// stderr is sent to the null device so it can never fill either.
    private static func run(_ args: [String], in dir: String, ignoreStatus: Bool = false) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", dir] + args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if !ignoreStatus, process.terminationStatus != 0 { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Tab switch

/// The inspector's pane switch: a native segmented `Picker` (which adopts the system
/// Liquid Glass material on macOS 26) flipping between Files and Changes. It sits at
/// the *left* edge of the inspector in the toolbar — pinned there by an inspector
/// tracking separator (see `MainToolbarDelegate`) — while the collapse button sits at
/// the far right. Picking a pane also opens the inspector if it is closed.
struct InspectorTabsToolbar: View {
    @EnvironmentObject var store: TermioStore

    var body: some View {
        Picker("", selection: Binding(
            get: { store.inspectorTab },
            set: { store.inspectorTab = $0 }
        )) {
            Image(systemName: "list.bullet.indent")
                .help("Project Files")
                .tag(InspectorTab.files)
            Image(systemName: "arrow.triangle.branch")
                .help("Changes")
                .tag(InspectorTab.changes)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        // Bound the hosting view to a fixed, standard toolbar height — an unconstrained segmented
        // Picker can report a tall intrinsic height that grows the unified toolbar (and, with
        // `.fullSizeContentView`, nudges the window frame) the moment the item is inserted.
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: 24)
    }
}

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
                ContentUnavailableView(
                    "No Changes",
                    systemImage: "checkmark.circle",
                    description: Text("The working tree is clean.")
                )
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

// MARK: - Diff overlay

/// A read-only unified diff that covers the terminal pane — the git counterpart of
/// `FilePreviewView`/`FileEditorView`, driven by `store.openDiff`. Rendered as native
/// SwiftUI rows (the Xcode / CodeEdit / gitdiff pattern — parse the diff, draw line
/// rows with a line-number gutter and per-line green/red backgrounds) rather than a
/// web view, so it needs no syntax-highlighting dependency. Escape or the close
/// button dismisses it back to the terminal.
struct GitDiffView: View {
    let request: GitDiffRequest
    @ObservedObject var settings: AppSettings
    let onClose: () -> Void

    @State private var rows: [DiffRow] = []
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Color(nsColor: settings.terminalBackgroundColor).ignoresSafeArea())
        .onExitCommand(perform: onClose)
        .task(id: request) { await load() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(request.change.status.letter)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(request.change.status.tint)
                .frame(width: 16)
            Text(request.name)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(request.change.path)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 8)
            if request.change.additions > 0 {
                Text("+\(request.change.additions)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.green)
            }
            if request.change.deletions > 0 {
                Text("−\(request.change.deletions)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.red)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: settings.terminalBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if rows.isEmpty {
            ContentUnavailableView(
                "No Diff",
                systemImage: "doc",
                description: Text("No textual changes to show.")
            )
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        DiffLineRow(row: row, font: diffFont,
                                    showOldGutter: hasOldLines, showNewGutter: hasNewLines)
                    }
                }
                .padding(.bottom, 12)
            }
        }
    }

    /// Whether any row carries an old/new line number. A pure-addition file (new file)
    /// has no old numbers, so we collapse that empty gutter rather than show a blank band;
    /// likewise a pure deletion collapses the new gutter.
    private var hasOldLines: Bool { rows.contains { $0.oldLine != nil } }
    private var hasNewLines: Bool { rows.contains { $0.newLine != nil } }

    /// The terminal font, so the diff reads in the same face as the agent's output.
    private var diffFont: Font {
        let size = max(11, settings.fontSize)
        return settings.fontFamily.isEmpty
            ? .system(size: size, design: .monospaced)
            : .custom(settings.fontFamily, size: size)
    }

    private func load() async {
        let parsed = await GitService.diffRows(for: request.change, in: request.repoRoot)
        rows = parsed
        isLoading = false
    }
}

/// One line of the diff: a hunk header on a faint accent band, or a code line with an
/// old/new line-number gutter, a `+`/`−`/space sign, and a green/red/clear background.
/// Long lines soft-wrap (the panel is fixed-width) rather than scroll horizontally,
/// which keeps each line's background spanning the full width.
private struct DiffLineRow: View {
    let row: DiffRow
    let font: Font
    var showOldGutter = true
    var showNewGutter = true

    var body: some View {
        if row.kind == .hunk {
            Text(row.text)
                .font(font)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3)
                .padding(.horizontal, 10)
                .background(Color.accentColor.opacity(0.10))
        } else {
            HStack(alignment: .top, spacing: 0) {
                if showOldGutter { gutter(row.oldLine) }
                if showNewGutter { gutter(row.newLine) }
                Text(sign)
                    .font(font)
                    .foregroundStyle(signColor)
                    .frame(width: 16)
                Text(row.text.isEmpty ? " " : row.text)
                    .font(font)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 10)
            }
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
        }
    }

    private func gutter(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(width: 36, alignment: .trailing)
            .padding(.trailing, 6)
    }

    private var sign: String {
        switch row.kind {
        case .addition: return "+"
        case .deletion: return "-"
        default: return " "
        }
    }

    private var signColor: Color {
        switch row.kind {
        case .addition: return .green
        case .deletion: return .red
        default: return .secondary
        }
    }

    private var background: Color {
        switch row.kind {
        case .addition: return Color.green.opacity(0.13)
        case .deletion: return Color.red.opacity(0.13)
        default: return .clear
        }
    }
}
