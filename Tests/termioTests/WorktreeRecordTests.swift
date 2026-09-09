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
