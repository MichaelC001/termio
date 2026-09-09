import XCTest
@testable import termio

/// The reconcile's sweep of registrations whose checkouts are gone, against a
/// real repository — it deregisters without anyone asking, so what it will and
/// will not touch is worth holding down.
final class WorktreeSweepTests: XCTestCase {
    private var root: URL!
    private var repo: URL { root.appendingPathComponent("repo") }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("worktree-sweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "--quiet"])
        try git(["commit", "--quiet", "--allow-empty", "-m", "init"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A checkout whose folder is simply gone is deregistered, so the path can be
    /// used again. Nothing else is: a folder still holding files, an emptied one,
    /// and one git is holding with `lock` all stay for the user's own Remove to
    /// decide on — and the sweep never deletes a file to get there.
    func testOnlyAVanishedCheckoutIsSweptAway() async throws {
        for name in ["gone", "work", "empty", "locked"] {
            try git(["worktree", "add", "--quiet", "-b", name, worktree(name).path, "HEAD"])
        }
        try FileManager.default.removeItem(at: worktree("gone"))
        // Its `.git` gitfile deleted with the work still there: git calls this
        // prunable, and those files are exactly what must survive.
        try "uncommitted".write(to: worktree("work").appendingPathComponent("draft.txt"),
                                atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: worktree("work").appendingPathComponent(".git"))
        try FileManager.default.removeItem(at: worktree("empty"))
        try FileManager.default.createDirectory(at: worktree("empty"), withIntermediateDirectories: true)
        try git(["worktree", "lock", worktree("locked").path])
        try FileManager.default.removeItem(at: worktree("locked"))

        _ = await WorktreeService.reconcile(in: repo.path, against: [])

        // Compared canonically, because git prints realpaths and the temporary
        // directory these live under is reached through a symlink.
        let registered = try registeredPaths()
        XCTAssertFalse(registered.contains(key("gone")), "a vanished checkout is let go of")
        XCTAssertTrue(registered.contains(key("work")), "work nobody inspected stays registered")
        XCTAssertTrue(registered.contains(key("empty")), "an emptied folder is the user's call")
        XCTAssertTrue(registered.contains(key("locked")), "a locked worktree is git's to hold")

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: worktree("work").appendingPathComponent("draft.txt").path),
            "the sweep deletes no files")
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree("empty").path))

        // The point of letting go: the path is usable again. Before this, the
        // registration leaked and a later add at the same path was refused.
        try git(["worktree", "add", "--quiet", "-b", "again", worktree("gone").path, "HEAD"])

        // The branch is left alone — deleting a ref is not something a pass
        // nobody asked for should do.
        XCTAssertTrue(try branches().contains("gone"))
    }

    /// The sweep leaves what it cannot see. A path whose volume is not mounted
    /// answers "no such file" for everything on it, and `/Volumes` with the
    /// volume directory absent is what that looks like.
    func testAnUnmountedVolumeIsNotMistakenForADeletedCheckout() {
        XCTAssertEqual(
            WorktreeService.folderEvidence(at: "/Volumes/TermioNoSuchVolume/repo-wt"),
            .unreadable)
    }

    // MARK: Helpers

    private func worktree(_ name: String) -> URL {
        root.appendingPathComponent("wt-\(name)")
    }

    private func key(_ name: String) -> String {
        WorktreeService.canonicalPath(worktree(name).path)
    }

    private func registeredPaths() throws -> [String] {
        (WorktreeService.records(in: repo.path) ?? []).map { WorktreeService.canonicalPath($0.path) }
    }

    private func branches() throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo.path, "branch", "--format=%(refname:short)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func git(_ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = repo
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(args.joined(separator: " ")) failed")
    }
}
