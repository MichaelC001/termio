import Foundation

/// A node in the project file tree. A class (not a struct) so SwiftUI's
/// `List(_:children:)` can lazily realize a folder's contents the first time it is
/// expanded — the `children` getter reads the directory on demand and caches it —
/// rather than walking the whole repo up front. Identity is the file URL, so the
/// outline keeps its expansion state across a refresh even though the nodes are
/// rebuilt.
final class FileNode: Identifiable {
    let url: URL
    /// Whether this browses as a folder — resolved *through* a symlink, so a link to a
    /// directory expands like the directory it points at (what the Finder and the VS Code
    /// explorer both do).
    let isDirectory: Bool
    /// Whether the entry itself is a symlink, so the row can mark it. Independent of
    /// `isDirectory`: a link can point at either kind.
    let isSymbolicLink: Bool
    var id: URL { url }
    var name: String { url.lastPathComponent }

    private var loadedChildren: [FileNode]?

    init(url: URL, isDirectory: Bool, isSymbolicLink: Bool = false) {
        self.url = url
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
    }

    /// Where a symlink points, for the row's tooltip — the one fact about a link an icon
    /// can't carry. Relative to the link's own parent when the target sits inside the
    /// project (`.claude/skills` → `../skills`), absolute when it escapes.
    var symbolicLinkTarget: String? {
        guard isSymbolicLink else { return nil }
        return try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    }

    /// Where a symlink actually lands, absolute — for the row menu's Show Original. Nil
    /// when this isn't a link, or when the link dangles: a target that doesn't exist
    /// can't be revealed, and offering a menu item that silently does nothing is worse
    /// than not offering it.
    var resolvedSymbolicLinkTarget: URL? {
        guard isSymbolicLink else { return nil }
        let resolved = url.resolvingSymlinksInPath()
        guard resolved != url, FileManager.default.fileExists(atPath: resolved.path) else { return nil }
        return resolved
    }

    /// `nil` for a file (so the outline draws no disclosure triangle); a folder's
    /// contents — read lazily and cached — for a directory. SwiftUI only asks for
    /// the children of an *expanded* node, so this stays cheap on a large tree.
    ///
    /// A symlink that points at one of its own ancestors therefore nests forever, one
    /// level per click. That's the Finder's and the VS Code explorer's behavior too:
    /// laziness bounds the recursion by what the user actually opens, so no cycle
    /// detection is worth the bookkeeping.
    var children: [FileNode]? {
        guard isDirectory else { return nil }
        if let loadedChildren { return loadedChildren }
        let contents = FileNode.listContents(of: url)
            .map { FileNode(url: $0.url, isDirectory: $0.isDirectory, isSymbolicLink: $0.isSymbolicLink) }
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
    func applyReloaded(_ entries: [(url: URL, isDirectory: Bool, isSymbolicLink: Bool)]) {
        guard isDirectory, let current = loadedChildren else { return }
        var existing = [URL: FileNode]()
        for child in current { existing[child.url] = child }
        loadedChildren = entries.map { entry in
            // Same URL but a different kind (a file replaced by a folder, a real folder
            // replaced by a link to one) is a new entry — both flags are immutable on
            // the node.
            if let node = existing[entry.url],
               node.isDirectory == entry.isDirectory,
               node.isSymbolicLink == entry.isSymbolicLink {
                return node
            }
            return FileNode(url: entry.url, isDirectory: entry.isDirectory, isSymbolicLink: entry.isSymbolicLink)
        }
    }

    /// Directory entries, folders first then files, each alphabetized the way the
    /// Finder orders names. Dotfiles are shown (the VS Code explorer default); only the
    /// VCS/OS metadata in `ignoredNames` is dropped — matching VS Code's own default
    /// `files.exclude`, which likewise leaves `node_modules`/build folders visible.
    /// Plain values (not nodes) so callers can list on a background thread and build
    /// or merge nodes back on main (`FileNode` itself is main-thread state).
    static func listContents(of url: URL) -> [(url: URL, isDirectory: Bool, isSymbolicLink: Bool)] {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else { return [] }

        return entries
            .filter { !ignoredNames.contains($0.lastPathComponent) }
            .map { entry in
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                let isSymbolicLink = values?.isSymbolicLink ?? false
                // `.isDirectoryKey` describes the link itself, not its target, so a
                // symlink to a folder reports false and would render as a file with no
                // disclosure triangle. `fileExists` follows the link, which is the
                // answer the tree wants — and the same probe `FileBrowserView` already
                // uses to decide whether a double-click opens an editor.
                let isDirectory: Bool
                if isSymbolicLink {
                    var target: ObjCBool = false
                    isDirectory = manager.fileExists(atPath: entry.path, isDirectory: &target) && target.boolValue
                } else {
                    isDirectory = values?.isDirectory ?? false
                }
                return (url: entry, isDirectory: isDirectory, isSymbolicLink: isSymbolicLink)
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
