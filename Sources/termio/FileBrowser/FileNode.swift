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
    let showHidden: Bool
    var id: URL { url }
    var name: String { url.lastPathComponent }

    private var loadedChildren: [FileNode]?

    init(url: URL, isDirectory: Bool, showHidden: Bool) {
        self.url = url
        self.isDirectory = isDirectory
        self.showHidden = showHidden
    }

    /// `nil` for a file (so the outline draws no disclosure triangle); a folder's
    /// contents — read lazily and cached — for a directory. SwiftUI only asks for
    /// the children of an *expanded* node, so this stays cheap on a large tree.
    var children: [FileNode]? {
        guard isDirectory else { return nil }
        if let loadedChildren { return loadedChildren }
        let contents = FileNode.readContents(of: url, showHidden: showHidden)
        loadedChildren = contents
        return contents
    }

    /// Directory entries, folders first then files, each alphabetized the way the
    /// Finder orders names. Hidden entries are dropped (`.git`, dotfiles), as are a
    /// few heavy build directories that would only bloat the tree.
    private static func readContents(of url: URL, showHidden: Bool) -> [FileNode] {
        let manager = FileManager.default
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        guard let entries = try? manager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: options
        ) else { return [] }

        return entries
            .filter { entry in
                let name = entry.lastPathComponent
                if alwaysIgnored.contains(name) { return false }
                return !ignoredNames.contains(name)
            }
            .map { entry in
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return FileNode(url: entry, isDirectory: isDirectory, showHidden: showHidden)
            }
            .sorted { left, right in
                if left.isDirectory != right.isDirectory { return left.isDirectory }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
    }

    /// Hidden directories that are always noise and should not be shown even if showing hidden files.
    private static let alwaysIgnored: Set<String> = [".git", ".DS_Store"]

    /// Non-hidden directories that are noise in a project tree (the hidden ones —
    /// `.git`, `.DS_Store` — are already excluded by `.skipsHiddenFiles`).
    private static let ignoredNames: Set<String> = ["node_modules", ".build", "DerivedData"]
}
