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
        let contents = FileNode.readContents(of: url)
        loadedChildren = contents
        return contents
    }

    /// Directory entries, folders first then files, each alphabetized the way the
    /// Finder orders names. Dotfiles are shown (the VS Code explorer default); only the
    /// VCS/OS metadata in `ignoredNames` is dropped — matching VS Code's own default
    /// `files.exclude`, which likewise leaves `node_modules`/build folders visible.
    private static func readContents(of url: URL) -> [FileNode] {
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
                return FileNode(url: entry, isDirectory: isDirectory)
            }
            .sorted { left, right in
                if left.isDirectory != right.isDirectory { return left.isDirectory }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
    }

    /// VCS and OS metadata that is always noise, dropped even though dotfiles are
    /// otherwise shown. Mirrors VS Code's default `files.exclude`
    /// (`.git`/`.svn`/`.hg`/`.DS_Store`/`Thumbs.db`); like VS Code it does *not* hide
    /// `node_modules` or build output — those stay visible, loaded lazily on expand.
    private static let ignoredNames: Set<String> = [".git", ".svn", ".hg", ".DS_Store", "Thumbs.db"]
}
