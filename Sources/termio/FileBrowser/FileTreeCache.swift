import Foundation

/// Realized file trees, kept alive per root directory so returning to one is a
/// handoff rather than a rebuild.
///
/// `FileNode` is a class whose identity is its URL, which is what lets the outline
/// keep its expansion across a refresh *of the same root*. Change the root — switch
/// workspace, select a session in another project — and the view built a whole new
/// tree instead: every folder the user had opened closed itself, and the outline
/// re-diffed from nothing. Coming back paid it again.
///
/// This is the same bargain `TermioStore`'s surface cache already strikes for
/// terminals: the model outlives the view, so switching away and back costs a
/// dictionary read. The view keeps owning *presentation*; only the realized tree
/// lives here.
///
/// Capped, because a realized tree is real memory: a root the user has expanded
/// deeply holds a node per listed entry. The least recently used root is dropped
/// once the cap is passed, which costs that root one rebuild the next time it is
/// opened — the behaviour every root had before this existed.
@MainActor
final class FileTreeCache {
    /// How many roots to keep. A user moves between a handful of checkouts in a
    /// sitting; past that the tail is cold and worth its rebuild.
    private static let capacity = 8

    private var roots: [String: FileNode] = [:]
    /// Least recently used first, so eviction reads off the front.
    private var order: [String] = []

    /// The realized tree for `url`, if one is still held. Touching it marks the
    /// root as recently used, so the tree you keep returning to is the last to be
    /// evicted.
    func tree(for url: URL) -> FileNode? {
        let key = Self.key(url)
        guard let node = roots[key] else { return nil }
        touch(key)
        return node
    }

    /// Hands a realized tree to the cache. Replacing an existing entry is normal:
    /// a refresh rebuilds the root node, and the cache must hold the live one or a
    /// later return would restore a tree the watcher has stopped updating.
    func store(_ node: FileNode, for url: URL) {
        let key = Self.key(url)
        roots[key] = node
        touch(key)
        while order.count > Self.capacity, let oldest = order.first {
            order.removeFirst()
            roots[oldest] = nil
        }
    }

    /// Forgets one root — used when its directory is gone, so a stale tree can
    /// never be handed back for a path that no longer exists.
    func forget(_ url: URL) {
        let key = Self.key(url)
        roots[key] = nil
        order.removeAll { $0 == key }
    }

    func removeAll() {
        roots.removeAll()
        order.removeAll()
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    /// Paths are compared standardized, so `~/code/termio` and `/Users/me/code/termio`
    /// are one root rather than two copies of the same tree.
    private static func key(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}
