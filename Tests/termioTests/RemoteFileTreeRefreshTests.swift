import XCTest
import TermioShared
@testable import termio

/// What a refresh of a device's file tree asks for, and what it does with the
/// answer.
///
/// The tree used to drop every node it held and re-list the root alone, leaving
/// each still-expanded folder to fetch itself from the `children` getter — one
/// SSH round trip per open folder, on every app focus. It now names them all in
/// one `fs.list` and grafts the replies onto the nodes already on screen. Both
/// halves are checkable without a device: the paths it asks for, and whether the
/// subtree under an open folder survives.
@MainActor
final class RemoteFileTreeRefreshTests: XCTestCase {
    private let root = "/srv/api"

    private func model() -> RemoteFileBrowserModel {
        // A route nothing will answer on: every assertion here is about what the
        // model does with listings it is handed, never about fetching them.
        RemoteFileBrowserModel(
            checkout: Checkout(
                device: KnownDevice(alias: "test-box", deviceID: nil), root: root),
            root: root)
    }

    private func listing(
        _ path: String, _ entries: [(String, FileEntry.Kind)], error: String? = nil
    ) -> Termiod.DirectoryListing {
        Termiod.DirectoryListing(
            path: path,
            entries: entries.map { FileEntry(name: $0.0, kind: $0.1) },
            error: error)
    }

    /// The ask: the root plus every directory whose contents the tree is holding,
    /// parents before children so a graft never runs ahead of the node it hangs
    /// off.
    func testARefreshNamesEveryDirectoryTheTreeIsShowing() {
        let tree = model()
        tree.apply([listing(root, [("src", .directory), ("README.md", .file)])])
        XCTAssertEqual(tree.loadedDirectories(), [], "nothing under the root is open yet")

        tree.apply([listing("\(root)/src", [("deep", .directory)])])
        tree.apply([listing("\(root)/src/deep", [("x.swift", .file)])])

        XCTAssertEqual(
            tree.loadedDirectories(), ["\(root)/src", "\(root)/src/deep"],
            "shallowest first, so a parent's rows exist before its child's land")
    }

    /// The graft: a folder that is still there keeps the node it had, and so
    /// keeps everything loaded underneath it. Minting a fresh node would leave
    /// the outline expanded over an empty folder and send the tree back to
    /// fetching each level again — the exact cost this refresh removes.
    func testAnOpenFolderKeepsItsSubtreeAcrossARefresh() {
        let tree = model()
        tree.apply([listing(root, [("src", .directory)])])
        tree.apply([listing("\(root)/src", [("x.swift", .file)])])

        let before = try? XCTUnwrap(tree.node(at: "\(root)/src"))
        tree.apply([listing(root, [("src", .directory), ("new.md", .file)])])
        let after = try? XCTUnwrap(tree.node(at: "\(root)/src"))

        XCTAssertTrue(before === after, "the surviving folder keeps its node")
        XCTAssertEqual(after?.children?.map(\.name), ["x.swift"])
        XCTAssertEqual(tree.rootNodes.map(\.name), ["src", "new.md"])
        XCTAssertEqual(tree.loadedDirectories(), ["\(root)/src"],
                       "and is still counted as loaded, so it re-lists in the batch")
    }

    /// A name that changed kind is a different thing wearing the same path, and
    /// must not inherit the old node's children.
    func testAPathThatChangedKindIsRebuilt() {
        let tree = model()
        tree.apply([listing(root, [("src", .directory)])])
        tree.apply([listing("\(root)/src", [("x.swift", .file)])])
        let directory = tree.node(at: "\(root)/src")

        tree.apply([listing(root, [("src", .file)])])

        let file = tree.node(at: "\(root)/src")
        XCTAssertFalse(directory === file)
        XCTAssertNil(file?.children, "a file has no children to inherit")
    }

    /// `fs.list` fails one path at a time. A folder the device refused keeps the
    /// rows it had rather than blanking, so one deleted directory does not empty
    /// the pane around it.
    func testAPathTheDeviceRefusedLeavesItsRowsAlone() {
        let tree = model()
        tree.apply([listing(root, [("src", .directory)])])
        tree.apply([listing("\(root)/src", [("x.swift", .file)])])

        tree.apply([
            listing(root, [("src", .directory)]),
            listing("\(root)/src", [], error: "No such file or directory"),
        ])

        XCTAssertEqual(tree.node(at: "\(root)/src")?.children?.map(\.name), ["x.swift"])
    }

    /// A folder that is gone takes its subtree with it, or the paths a refresh
    /// asks for would grow for the life of the pane.
    func testAFolderThatDisappearedStopsBeingAskedFor() {
        let tree = model()
        tree.apply([listing(root, [("src", .directory), ("docs", .directory)])])
        tree.apply([listing("\(root)/src", [("x.swift", .file)])])
        tree.apply([listing("\(root)/docs", [("y.md", .file)])])
        XCTAssertEqual(tree.loadedDirectories().count, 2)

        tree.apply([listing(root, [("docs", .directory)])])

        XCTAssertNil(tree.node(at: "\(root)/src"))
        XCTAssertEqual(tree.loadedDirectories(), ["\(root)/docs"])
    }
}
