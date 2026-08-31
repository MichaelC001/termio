import XCTest
import TermioShared
@testable import termio

/// The ordering and routing rules a device git watch lives by, pinned without
/// a connection: the ledger that keeps a racing batch from being erased by its
/// own gap reset, and the routing table that re-keys a subscription under the
/// device's canonical resource id and retires a watch only with its last
/// subscriber.
final class DeviceGitWatchTests: XCTestCase {

    private func batch(seq: UInt64) -> Termiod.GitChangedPayload {
        Termiod.GitChangedPayload(
            seq: seq, updatedStatuses: [], removedPaths: [],
            branch: nil, head: nil, ahead: 0, behind: 0, conflicts: [])
    }

    // MARK: - DeviceWatchLedger

    func testABatchRacingTheAckIsHeldUntilTheBaselineDecision() {
        var ledger = DeviceWatchLedger()
        let generation = ledger.begin()
        // The daemon queues the synthesized full batch right behind the ack;
        // applied immediately, the gap reset that follows would erase it.
        XCTAssertNil(ledger.admit(batch(seq: 7), generation: generation))
        let held = ledger.settle(generation: generation)
        XCTAssertEqual(held?.map(\.seq), [7])
        // Settled: later batches apply as they arrive.
        XCTAssertEqual(ledger.admit(batch(seq: 8), generation: generation)?.seq, 8)
    }

    func testHeldBatchesComeBackInArrivalOrder() {
        var ledger = DeviceWatchLedger()
        let generation = ledger.begin()
        XCTAssertNil(ledger.admit(batch(seq: 1), generation: generation))
        XCTAssertNil(ledger.admit(batch(seq: 2), generation: generation))
        XCTAssertEqual(ledger.settle(generation: generation)?.map(\.seq), [1, 2])
    }

    func testStoppingMidHandshakeAbandonsTheAttempt() {
        var ledger = DeviceWatchLedger()
        let generation = ledger.begin()
        ledger.stop()
        // The pane went away before the ack: the subscription must not install.
        XCTAssertNil(ledger.settle(generation: generation))
        // And a batch from that attempt must not apply.
        XCTAssertNil(ledger.admit(batch(seq: 3), generation: generation))
    }

    func testARestartedWatchDropsTheOldGenerationsBatches() {
        var ledger = DeviceWatchLedger()
        let old = ledger.begin()
        let current = ledger.begin()
        XCTAssertNil(ledger.admit(batch(seq: 4), generation: old))
        // The stale batch was dropped, not held for the new attempt.
        XCTAssertEqual(ledger.settle(generation: current)?.map(\.seq), [])
        XCTAssertNil(ledger.settle(generation: old))
    }

    // MARK: - ResourceRoutingTable

    private final class Subscriber {}

    func testTheAckReKeysUnderTheCanonicalId() {
        var table = Termiod.ResourceRoutingTable<Subscriber>()
        let subscriber = Subscriber()
        // The caller spelled the root through a symlink; the daemon
        // canonicalises and stamps every event with the canonical id.
        table.register(subscriber, resource: "git:/link/repo", request: 5)
        XCTAssertTrue(table.isAwaiting(request: 5))
        XCTAssertTrue(table.acknowledged(request: 5, canonical: "git:/real/repo") === subscriber)
        XCTAssertFalse(table.isAwaiting(request: 5))
        XCTAssertTrue(table.listeners(for: "git:/real/repo").first === subscriber)
        XCTAssertTrue(table.listeners(for: "git:/link/repo").isEmpty)
    }

    func testAnAckNamingTheSameIdMovesNothing() {
        var table = Termiod.ResourceRoutingTable<Subscriber>()
        let subscriber = Subscriber()
        table.register(subscriber, resource: "git:/repo", request: 5)
        XCTAssertNil(table.acknowledged(request: 5, canonical: "git:/repo"))
        XCTAssertTrue(table.listeners(for: "git:/repo").first === subscriber)
        XCTAssertFalse(table.isAwaiting(request: 5))
    }

    func testOnlyTheLastUnregisterForAResourceReportsLast() {
        var table = Termiod.ResourceRoutingTable<Subscriber>()
        let first = Subscriber()
        let second = Subscriber()
        table.register(first, resource: "git:/repo", request: 1)
        table.register(second, resource: "git:/repo", request: 2)
        // The daemon tracks interest per connection: an unsubscribe sent while
        // the second pane still reads would take its events too.
        XCTAssertFalse(table.unregister(first))
        XCTAssertTrue(table.unregister(second))
    }

    func testTwoSpellingsOfOneRepoConvergeAfterTheirAcks() {
        var table = Termiod.ResourceRoutingTable<Subscriber>()
        let first = Subscriber()
        let second = Subscriber()
        table.register(first, resource: "git:/link/repo", request: 1)
        table.register(second, resource: "git:/real/repo", request: 2)
        _ = table.acknowledged(request: 1, canonical: "git:/real/repo")
        _ = table.acknowledged(request: 2, canonical: "git:/real/repo")
        XCTAssertEqual(table.listeners(for: "git:/real/repo").count, 2)
        XCTAssertFalse(table.unregister(first))
        XCTAssertTrue(table.unregister(second))
    }

    func testASubscriberSweptByCloseReportsNotLast() {
        var table = Termiod.ResourceRoutingTable<Subscriber>()
        let subscriber = Subscriber()
        table.register(subscriber, resource: "git:/repo", request: 1)
        XCTAssertTrue(table.removeAll().first === subscriber)
        XCTAssertTrue(table.isEmpty)
        // A cancel arriving after the channel died has nothing to retire.
        XCTAssertFalse(table.unregister(subscriber))
    }

    func testAFailedSubscribeClearsItsPendingAck() {
        var table = Termiod.ResourceRoutingTable<Subscriber>()
        let subscriber = Subscriber()
        table.register(subscriber, resource: "git:/repo", request: 9)
        XCTAssertTrue(table.unregister(subscriber))
        XCTAssertFalse(table.isAwaiting(request: 9))
        // A late ack for the dead request must not resurrect anything.
        XCTAssertNil(table.acknowledged(request: 9, canonical: "git:/real"))
    }
}
