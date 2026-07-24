import Foundation

/// The one walk-up-for-`.git` in the editor, shared by the header's repo-relative path and the
/// LSP workspace root so the two can never disagree about which repo a file belongs to.
enum GitRoot {
    /// The work-tree root containing `url`, or `nil` outside a repo. Matches any `.git` entry —
    /// a directory in a normal clone, a *file* in linked worktrees and submodules.
    static func find(for url: URL) -> URL? {
        var dir = url.standardizedFileURL.deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}
