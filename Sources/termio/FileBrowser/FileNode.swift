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

    /// Directory entries per the tree's shared listing conventions (folders first,
    /// Finder-ordered, VCS/OS metadata dropped — see `FileEntry.ignoredNames`), read
    /// through the local provider so this stays the one `FileManager` walk in the tree.
    private static func readContents(of url: URL) -> [FileNode] {
        LocalFileSystemProvider.listSync(url).map { entry in
            FileNode(
                url: url.appendingPathComponent(entry.name, isDirectory: entry.isDirectory),
                isDirectory: entry.isDirectory
            )
        }
    }
}
