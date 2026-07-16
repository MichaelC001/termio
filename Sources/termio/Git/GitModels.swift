import Foundation
import SwiftUI

// MARK: - Models

/// Which inspector pane the trailing column is showing — the file tree, the file
/// search, the git changes list, or the session Info pane. Drives the segmented
/// switch at the top of `FileBrowserView`.
enum InspectorTab: Hashable, Sendable {
    case files, search, changes, info
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
        case .conflicted: return "!"
        case .untracked: return "U"
        }
    }

    var tint: Color {
        switch self {
        case .added: return .green
        case .deleted: return .red
        case .renamed, .copied: return .orange
        case .conflicted: return .yellow
        // An untracked file is a brand-new file, so it reads as additive — green,
        // like its `+` line count and the way VS Code marks a `U` in the explorer —
        // rather than a noisy grey `?` that looks like an error down the whole list.
        case .untracked: return .green
        case .modified: return .blue
        }
    }
}

/// The branch's position relative to its remote tracking branch, parsed from the
/// header line of `git status -sb`. `hasUpstream == false` means the branch has never
/// been pushed, so the first push needs `-u origin HEAD`; `ahead` is how many local
/// commits the remote is missing — the count the Push button sends.
struct GitUpstream: Equatable, Sendable {
    var hasUpstream: Bool
    var ahead: Int
    var behind: Int

    static let none = GitUpstream(hasUpstream: false, ahead: 0, behind: 0)
    /// Something to push: either commits ahead of the remote, or a branch that has
    /// never been pushed at all.
    var canPush: Bool { ahead > 0 || !hasUpstream }
}

/// The outcome of a mutating git/gh action. On failure it carries a one-line, already
/// trimmed message from stderr, suitable for the inline banner in the changes pane.
enum GitActionResult: Sendable, Equatable {
    case success
    case failure(String)
}

/// The outcome of `gh pr create`: the new PR's URL on success (to open in the browser),
/// or a one-line failure message for the sheet.
enum CreatePRResult: Sendable, Equatable {
    case success(String)
    case failure(String)
}

/// The rolled-up CI state of a pull request, from `gh pr view … statusCheckRollup`.
enum PRChecks: Equatable, Sendable { case none, pending, passing, failing }

/// An existing GitHub pull request for the checked-out branch, as reported by
/// `gh pr view --json`. Absent (`nil`) when the branch has no PR yet — that is when the
/// pane offers "Create Pull Request" instead of showing this status.
struct PullRequestInfo: Equatable, Sendable {
    let number: Int
    let url: String
    let title: String
    let state: String        // OPEN / MERGED / CLOSED
    let checks: PRChecks
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
