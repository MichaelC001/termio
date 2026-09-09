import XCTest
@testable import termio

/// `WorktreeService.records(from:)` is what `removeWorktree` decides on: which
/// checkout git still knows, whether git itself judges it gone (`prunable`),
/// whether git refuses to let go of it (`locked`), and which branch to tidy.
/// The fixtures are verbatim `git worktree list --porcelain` output.
final class WorktreeRecordTests: XCTestCase {
    func testRecordsCarryEveryAttributeTheRemovalDecidesOn() {
        let listing = """
        worktree /Users/u/repo
        HEAD b5ff2439a788da78e1b548099d6b69c828bc45d3
        branch refs/heads/main

        worktree /Users/u/wt-healthy
        HEAD b5ff2439a788da78e1b548099d6b69c828bc45d3
        branch refs/heads/feature-1

        worktree /Users/u/wt-locked
        HEAD b5ff2439a788da78e1b548099d6b69c828bc45d3
        branch refs/heads/feature-2
        locked

        worktree /Users/u/wt-gone
        HEAD b5ff2439a788da78e1b548099d6b69c828bc45d3
        branch refs/heads/feature-3
        prunable gitdir file points to non-existent location

        worktree /Users/u/wt-detached
        HEAD b5ff2439a788da78e1b548099d6b69c828bc45d3
        detached
        """
        let records = WorktreeService.records(from: listing)
        XCTAssertEqual(records.count, 5)
        XCTAssertEqual(records[0].path, "/Users/u/repo")
        XCTAssertEqual(records[0].branch, "main")

        XCTAssertEqual(records[1].branch, "feature-1")
        XCTAssertFalse(records[1].prunable)
        XCTAssertFalse(records[1].locked)

        XCTAssertTrue(records[2].locked)
        XCTAssertFalse(records[2].prunable)

        XCTAssertTrue(records[3].prunable)
        XCTAssertEqual(records[3].branch, "feature-3")

        // A detached HEAD has no branch to tidy — nil, not a sentinel string.
        XCTAssertNil(records[4].branch)
    }

    /// Verbatim output for a locked worktree whose folder was deleted (git 2.47):
    /// git marks it `locked` and *not* `prunable`, which is why `removeWorktree`
    /// has to test `locked` before it branches on `prunable` — inside that branch
    /// the check could never fire, and a checkout on unplugged removable media
    /// would take the deregistration path instead of the locked message.
    func testALockedWorktreeIsNeverMarkedPrunableEvenWithItsFolderGone() {
        let listing = """
        worktree /Users/u/repo
        HEAD 1a96c165970cec53355f4dc6c1b58b2fa79850ae
        branch refs/heads/main

        worktree /Users/u/w1
        HEAD 1a96c165970cec53355f4dc6c1b58b2fa79850ae
        branch refs/heads/b1
        locked
        """
        let records = WorktreeService.records(from: listing)
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records[1].locked)
        XCTAssertFalse(records[1].prunable)
    }

    /// The disk is the only witness left once git cannot inspect a checkout, so
    /// this probe decides whether a worktree may be deregistered and its sessions
    /// closed. Every failure has to land on the refusing side: a folder nothing
    /// could read is not a folder known to be empty.
    func testFolderEvidenceFailsClosedOnAFolderItCannotRead() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("worktree-evidence-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let unreadable = root.appendingPathComponent("denied")
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
        try "uncommitted work".write(
            to: unreadable.appendingPathComponent("draft.swift"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unreadable.path) }

        // Running as root defeats the permission bits, so the denial this asserts
        // on would not happen; the case is real for the user the app runs as.
        try XCTSkipIf(getuid() == 0, "root reads a 000 directory")
        XCTAssertEqual(WorktreeService.folderEvidence(at: unreadable.path), .unreadable)
    }

    func testFolderEvidenceSeparatesAnEmptyCheckoutFromOneHoldingWork() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("worktree-evidence-shapes-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Deleted out from under git: nothing to lose.
        XCTAssertEqual(
            WorktreeService.folderEvidence(at: root.appendingPathComponent("gone").path),
            .nothingToProtect
        )

        // Emptied and recreated, including the one Finder leaves behind.
        let emptied = root.appendingPathComponent("emptied")
        try FileManager.default.createDirectory(at: emptied, withIntermediateDirectories: true)
        XCTAssertEqual(WorktreeService.folderEvidence(at: emptied.path), .nothingToProtect)
        try "".write(to: emptied.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        XCTAssertEqual(WorktreeService.folderEvidence(at: emptied.path), .nothingToProtect)

        // The `.git` gitfile deleted with the work still there: git marks this
        // prunable, and the files are exactly what must not be let go of.
        let working = root.appendingPathComponent("working")
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        try "uncommitted".write(
            to: working.appendingPathComponent("draft.swift"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(WorktreeService.folderEvidence(at: working.path), .mayHoldWork)

        // A path that is no longer a directory holds no checkout.
        let replaced = root.appendingPathComponent("replaced")
        try "not a checkout".write(to: replaced, atomically: true, encoding: .utf8)
        XCTAssertEqual(WorktreeService.folderEvidence(at: replaced.path), .nothingToProtect)
    }

    func testABareEntryIsMarkedAndALockReasonStillReadsAsLocked() {
        let listing = """
        worktree /Users/u/repo.git
        bare

        worktree /Users/u/wt
        HEAD b5ff2439a788da78e1b548099d6b69c828bc45d3
        branch refs/heads/main
        locked on an external drive
        """
        let records = WorktreeService.records(from: listing)
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records[0].bare)
        XCTAssertNil(records[0].branch)
        XCTAssertTrue(records[1].locked)
    }
}
