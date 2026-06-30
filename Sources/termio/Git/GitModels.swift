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
