import Foundation

/// A node in the project file tree. A class (not a struct) so SwiftUI's
/// `List(_:children:)` can lazily realize a folder's contents the first time it is
/// expanded — the `children` getter reads the directory on demand and caches it —
/// rather than walking the whole repo up front. Identity is the file URL, so the
/// outline keeps its expansion state across a refresh even though the nodes are
/// rebuilt.
final class FileNode: Identifiable {
    let url: URL
    let isDirectory: Bool
    var id: URL { url }
    var name: String { url.lastPathComponent }

    private var loadedChildren: [FileNode]?

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    /// `nil` for a file (so the outline draws no disclosure triangle); a folder's
    /// contents — read lazily and cached — for a directory. SwiftUI only asks for
    /// the children of an *expanded* node, so this stays cheap on a large tree.
    var children: [FileNode]? {
        guard isDirectory else { return nil }
        if let loadedChildren { return loadedChildren }
        let contents = FileNode.listContents(of: url)
            .map { FileNode(url: $0.url, isDirectory: $0.isDirectory) }
        loadedChildren = contents
        return contents
    }

    /// Whether this directory's contents have been realized (first expansion, or a
    /// prior reload). An unrealized directory has nothing on screen to go stale, so
    /// the watcher path skips it — the next expansion reads the disk fresh anyway.
    var isLoaded: Bool { loadedChildren != nil }

    /// The realized node at `path` (itself or a descendant), walking only realized
    /// children — never triggering a directory read. Nil when `path` isn't part of
    /// the realized tree, which is what lets a high-churn root (a home directory)
    /// drop events for folders nobody ever expanded.
    func loadedNode(for path: String) -> FileNode? {
        if url.path == path { return self }
        guard isDirectory, let loadedChildren else { return nil }
        for child in loadedChildren
        where path == child.url.path || path.hasPrefix(child.url.path + "/") {
            return child.loadedNode(for: path)
        }
        return nil
    }

    /// Replaces this directory's realized contents with `entries` (a fresh disk
    /// listing), adopting the existing child node — realized subtree, and with it
    /// the outline's expansion state — wherever the entry survived.
    func applyReloaded(_ entries: [(url: URL, isDirectory: Bool)]) {
        guard isDirectory, let current = loadedChildren else { return }
        var existing = [URL: FileNode]()
        for child in current { existing[child.url] = child }
        loadedChildren = entries.map { entry in
            // Same URL but a different kind (a file replaced by a folder, or the
            // reverse) is a new entry — `isDirectory` is immutable on the node.
            if let node = existing[entry.url], node.isDirectory == entry.isDirectory {
                return node
            }
            return FileNode(url: entry.url, isDirectory: entry.isDirectory)
        }
    }

    /// Directory entries, folders first then files, each alphabetized the way the
    /// Finder orders names. Dotfiles are shown (the VS Code explorer default); only the
    /// VCS/OS metadata in `ignoredNames` is dropped — matching VS Code's own default
    /// `files.exclude`, which likewise leaves `node_modules`/build folders visible.
    /// Plain values (not nodes) so callers can list on a background thread and build
    /// or merge nodes back on main (`FileNode` itself is main-thread state).
    static func listContents(of url: URL) -> [(url: URL, isDirectory: Bool)] {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return [] }

        return entries
            .filter { !ignoredNames.contains($0.lastPathComponent) }
            .map { entry in
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return (url: entry, isDirectory: isDirectory)
            }
            .sorted { left, right in
                if left.isDirectory != right.isDirectory { return left.isDirectory }
                return left.url.lastPathComponent
                    .localizedStandardCompare(right.url.lastPathComponent) == .orderedAscending
            }
    }

    /// VCS and OS metadata that is always noise, dropped even though dotfiles are
    /// otherwise shown. Mirrors VS Code's default `files.exclude`
    /// (`.git`/`.svn`/`.hg`/`.DS_Store`/`Thumbs.db`); like VS Code it does *not* hide
    /// `node_modules` or build output — those stay visible, loaded lazily on expand.
    private static let ignoredNames: Set<String> = [".git", ".svn", ".hg", ".DS_Store", "Thumbs.db"]
}
