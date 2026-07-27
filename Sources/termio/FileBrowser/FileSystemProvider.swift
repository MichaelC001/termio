import Foundation

/// One directory entry as a data source reports it — the seam between the file
/// tree and where its bytes live. `FileNode` (local) and `RemoteFileNode` (SSH)
/// are both built from these, so the tree, icons, and selection logic stay
/// backend-agnostic.
struct FileEntry: Sendable {
    enum Kind: Sendable, Equatable {
        case file
        case directory
        /// A symlink. Remote previews never chase it, even when its target is a
        /// regular file or directory.
        case symlink
        /// FIFOs, sockets, devices, and any other non-previewable filesystem node.
        case other
    }

    let name: String
    let kind: Kind
    var isDirectory: Bool { kind == .directory }
    var isPreviewable: Bool { kind == .file }
    /// Byte size, when a provider reports one. The tree does not draw it yet.
    let size: Int64?
    /// Modification time, when a provider reports one.
    let modified: Date?

    init(name: String, kind: Kind, size: Int64? = nil, modified: Date? = nil) {
        self.name = name
        self.kind = kind
        self.size = size
        self.modified = modified
    }

    init(name: String, isDirectory: Bool, size: Int64? = nil, modified: Date? = nil) {
        self.init(
            name: name, kind: isDirectory ? .directory : .file,
            size: size, modified: modified)
    }
}

extension [FileEntry] {
    /// The tree's shared listing conventions, applied by every provider so a
    /// remote directory reads exactly like a local one: VCS/OS metadata dropped
    /// (see `ignoredNames`), folders first, each group alphabetized the way the
    /// Finder orders names.
    func sortedForTree() -> [FileEntry] {
        filter { !FileEntry.ignoredNames.contains($0.name) }
            .sorted { left, right in
                if left.isDirectory != right.isDirectory { return left.isDirectory }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
    }
}

extension FileEntry {
    /// VCS and OS metadata that is always noise, dropped even though dotfiles are
    /// otherwise shown. Mirrors VS Code's default `files.exclude`
    /// (`.git`/`.svn`/`.hg`/`.DS_Store`/`Thumbs.db`); like VS Code it does *not* hide
    /// `node_modules` or build output — those stay visible, loaded lazily on expand.
    static let ignoredNames: Set<String> = [".git", ".svn", ".hg", ".DS_Store", "Thumbs.db"]
}

/// A file tree data source: the local disk today, an SSH host's filesystem for a
/// remote session. Async throughout because the remote form runs a subprocess per
/// call; the local form answers immediately. Read-only by design — the tree's
/// write gestures (create/rename/delete/drop) stay local-only.
protocol FileSystemProvider: Sendable {
    /// The directory the tree roots at — the project path locally, `$HOME` on a
    /// remote host (resolved over the connection, hence async).
    func root() async throws -> String
    /// The entries of one directory, filtered and ordered per `sortedForTree`.
    func list(_ path: String) async throws -> [FileEntry]
    /// Up to `limit` bytes of one file, for the read-only preview.
    func read(_ path: String, limit: Int) async throws -> Data
}

/// The local disk, wrapping the same `FileManager` enumeration the tree has
/// always used — `FileNode` reads through `listSync` directly (its children
/// getter must stay synchronous for SwiftUI's lazy `List(children:)`), and the
/// async protocol face exists for parity with the remote provider.
struct LocalFileSystemProvider: FileSystemProvider {
    let rootPath: String

    func root() async throws -> String { rootPath }

    func list(_ path: String) async throws -> [FileEntry] {
        Self.listSync(URL(fileURLWithPath: path, isDirectory: true))
    }

    func read(_ path: String, limit: Int) async throws -> Data {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        return try handle.read(upToCount: limit) ?? Data()
    }

    /// Directory entries, shown per the tree's shared conventions. Dotfiles are
    /// shown (the VS Code explorer default); only the metadata in
    /// `FileEntry.ignoredNames` is dropped.
    static func listSync(_ url: URL) -> [FileEntry] {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return [] }

        return entries
            .map { entry in
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return FileEntry(name: entry.lastPathComponent, isDirectory: isDirectory)
            }
            .sortedForTree()
    }
}
