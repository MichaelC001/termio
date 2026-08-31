import XCTest
import TermioShared
@testable import termio

/// The ordering and routing rules a device git watch lives by, pinned without
/// a connection: the ledger that keeps a racing batch from being erased by its
/// own gap reset, and the routing table that re-keys a subscription under the
/// device's canonical resource id and retires a watch only with its last
/// subscriber.
final class DeviceGitWatchTests: XCTestCase {

    private func batch(seq: UInt64, truncated: Bool = false) -> Termiod.GitChangedPayload {
        Termiod.GitChangedPayload(
            seq: seq, updatedStatuses: [], removedPaths: [],
            branch: nil, head: nil, ahead: 0, behind: 0, conflicts: [],
            truncated: truncated)
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

    func testAnInterruptedRetryCannotOutliveAStoppedWatch() {
        var ledger = DeviceWatchLedger()
        let interrupted = ledger.begin()
        ledger.stop()

        XCTAssertFalse(ledger.isCurrent(interrupted))
    }

    func testAStartDuringAnOldHandshakeRequestsAReplacementWatch() {
        var ledger = DeviceWatchLedger()
        let old = ledger.begin()
        ledger.stop()

        // `startDeviceWatch()` cannot open another subscription until the old
        // async call leaves its defer, so it invalidates the old one and asks
        // that cleanup to begin the visible pane's replacement.
        ledger.requestRestart()
        XCTAssertNil(ledger.settle(generation: old))
        XCTAssertTrue(ledger.consumeRestartRequest())
        XCTAssertFalse(ledger.consumeRestartRequest())

        let replacement = ledger.begin()
        XCTAssertNotNil(ledger.settle(generation: replacement))
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
        XCTAssertFalse(table.unregister(ObjectIdentifier(first)))
        XCTAssertTrue(table.unregister(ObjectIdentifier(second)))
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
        XCTAssertFalse(table.unregister(ObjectIdentifier(first)))
        XCTAssertTrue(table.unregister(ObjectIdentifier(second)))
    }

    func testASubscriberSweptByCloseReportsNotLast() {
        var table = Termiod.ResourceRoutingTable<Subscriber>()
        let subscriber = Subscriber()
        table.register(subscriber, resource: "git:/repo", request: 1)
        XCTAssertTrue(table.removeAll().first === subscriber)
        XCTAssertTrue(table.isEmpty)
        // A cancel arriving after the channel died has nothing to retire.
        XCTAssertFalse(table.unregister(ObjectIdentifier(subscriber)))
    }

    func testAFailedSubscribeClearsItsPendingAck() {
        var table = Termiod.ResourceRoutingTable<Subscriber>()
        let subscriber = Subscriber()
        table.register(subscriber, resource: "git:/repo", request: 9)
        XCTAssertTrue(table.unregister(ObjectIdentifier(subscriber)))
        XCTAssertFalse(table.isAwaiting(request: 9))
        // A late ack for the dead request must not resurrect anything.
        XCTAssertNil(table.acknowledged(request: 9, canonical: "git:/real"))
    }

    /// The table routes events; it does not own subscriptions. Owning them
    /// would keep every one alive as long as the channel — and the channel
    /// alive as long as the subscription, since a subscribed channel is never
    /// reaped — so a pane released without an explicit cancel would leave a
    /// `git status` loop running on the device with nobody reading it.
    func testTheTableDoesNotKeepASubscriberAlive() {
        var table = Termiod.ResourceRoutingTable<Subscriber>()
        weak var released: Subscriber?
        do {
            let subscriber = Subscriber()
            released = subscriber
            table.register(subscriber, resource: "git:/repo", request: 1)
            XCTAssertNotNil(released)
        }
        XCTAssertNil(released, "the routing table must hold subscribers weakly")
        XCTAssertTrue(table.listeners(for: "git:/repo").isEmpty)
    }

    /// A subscriber that deallocated still has to be removable, because the
    /// removal is what tells the device to retire the watch — and it runs from
    /// `deinit`, by which point every weak reference to it already reads nil.
    func testADeallocatedSubscriberStillUnregistersByIdentity() {
        var table = Termiod.ResourceRoutingTable<Subscriber>()
        let survivor = Subscriber()
        var identity: ObjectIdentifier?
        do {
            let subscriber = Subscriber()
            identity = ObjectIdentifier(subscriber)
            table.register(subscriber, resource: "git:/repo", request: 1)
            table.register(survivor, resource: "git:/repo", request: 2)
        }
        guard let identity else { return XCTFail("no identity recorded") }
        XCTAssertFalse(table.unregister(identity), "the survivor still reads it")
        XCTAssertTrue(table.unregister(ObjectIdentifier(survivor)))
        XCTAssertTrue(table.isEmpty)
    }
}
