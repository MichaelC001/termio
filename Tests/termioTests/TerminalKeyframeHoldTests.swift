import TermioShared
import XCTest
@testable import termio

/// What a resize's keyframe is allowed to do to the screen.
///
/// The daemon opens its snapshot barrier before it emits `E resized`, and defers
/// events behind an open barrier, so `S` always reaches a client ahead of the
/// message that tells it what size to become. Every rule below follows from
/// that: a keyframe that arrives early must wait, everything behind it must wait
/// with it and in order, and the wait must end — on the grid, on a flood, or on
/// a deadline. None of it is visible in a screenshot; a wrong answer here shows
/// up only as a terminal that paints twice per resize, or one that goes quiet.
final class TerminalKeyframeHoldTests: XCTestCase {
    private let old = TerminalGrid(rows: 21, cols: 45)
    private let new = TerminalGrid(rows: 21, cols: 60)
    private let limit = 1 << 20

    private func bytes(_ text: String) -> Data { Data(text.utf8) }

    private func joined(_ chunks: [Data]) -> String {
        String(decoding: chunks.reduce(into: Data(), +=), as: UTF8.self)
    }

    /// The common case: nothing was resized, so nothing waits.
    func testAKeyframeAtTheSurfaceGridPaintsStraightThrough() {
        var hold = TerminalKeyframeHold(surfaceGrid: old)
        let paint = hold.receive(keyframe: bytes("repaint"), at: old)
        XCTAssertEqual(joined(paint), "repaint")
        XCTAssertFalse(hold.isHolding)
        XCTAssertEqual(joined(hold.receive(output: bytes("live"), limit: limit)), "live")
    }

    /// The resize case: the keyframe describes the size the pane is about to
    /// become, and painting it now would draw it through the old grid.
    func testAKeyframeAheadOfTheSurfacePaintsOnlyWhenTheSurfaceArrives() {
        var hold = TerminalKeyframeHold(surfaceGrid: old)
        XCTAssertTrue(hold.receive(keyframe: bytes("repaint"), at: new).isEmpty)
        XCTAssertTrue(hold.isHolding)

        // A layout pass that lands somewhere else is not the one being waited on.
        let elsewhere = hold.surfaceReached(TerminalGrid(rows: 21, cols: 50))
        XCTAssertTrue(elsewhere.paint.isEmpty)
        XCTAssertFalse(elsewhere.painted)

        let arrived = hold.surfaceReached(new)
        XCTAssertEqual(joined(arrived.paint), "repaint")
        XCTAssertTrue(arrived.painted)
        XCTAssertFalse(hold.isHolding)
    }

    /// `painted` is what stands down the resync. Reporting it for a grid nobody
    /// was waiting on would suppress the repair the degraded path depends on.
    func testOnlyTheGridThatWasWaitedOnReportsPainted() {
        var hold = TerminalKeyframeHold(surfaceGrid: old)
        XCTAssertFalse(hold.surfaceReached(new).painted)
        XCTAssertEqual(hold.surfaceGrid, new)
    }

    /// Live output behind a held keyframe is a continuation of the screen that
    /// keyframe describes. Letting it overtake would paint it onto the old one.
    func testOutputQueuesBehindAHeldKeyframeAndFollowsItInOrder() {
        var hold = TerminalKeyframeHold(surfaceGrid: old)
        XCTAssertTrue(hold.receive(keyframe: bytes("repaint"), at: new).isEmpty)
        XCTAssertTrue(hold.receive(output: bytes("one"), limit: limit).isEmpty)
        XCTAssertTrue(hold.receive(output: bytes("two"), limit: limit).isEmpty)

        XCTAssertEqual(joined(hold.surfaceReached(new).paint), "repaintonetwo")
        XCTAssertEqual(joined(hold.receive(output: bytes("three"), limit: limit)), "three")
    }

    /// A second keyframe describes a screen the daemon captured past the writes
    /// queued behind the first, so replaying them would double them.
    func testANewerKeyframeSupersedesWhatWasQueuedBehindTheOlderOne() {
        var hold = TerminalKeyframeHold(surfaceGrid: old)
        XCTAssertTrue(hold.receive(keyframe: bytes("first"), at: new).isEmpty)
        XCTAssertTrue(hold.receive(output: bytes("stale"), limit: limit).isEmpty)

        let taller = TerminalGrid(rows: 30, cols: 60)
        XCTAssertTrue(hold.receive(keyframe: bytes("second"), at: taller).isEmpty)
        XCTAssertEqual(joined(hold.surfaceReached(taller).paint), "second")
    }

    /// A program that floods through a resize must not grow this buffer without
    /// bound. Past the cap the keyframe paints early and the resync repairs it.
    func testAFloodBehindAHeldKeyframeEndsTheWait() {
        var hold = TerminalKeyframeHold(surfaceGrid: old)
        XCTAssertTrue(hold.receive(keyframe: bytes("repaint"), at: new).isEmpty)
        XCTAssertTrue(hold.receive(output: bytes("ab"), limit: 4).isEmpty)

        XCTAssertEqual(joined(hold.receive(output: bytes("cde"), limit: 4)), "repaintabcde")
        XCTAssertFalse(hold.isHolding)
    }

    /// The deadline and the teardown both come through `release`, and a hold
    /// that already ended must not paint its keyframe a second time.
    func testReleasingTwicePaintsOnce() {
        var hold = TerminalKeyframeHold(surfaceGrid: old)
        XCTAssertTrue(hold.receive(keyframe: bytes("repaint"), at: new).isEmpty)
        XCTAssertEqual(joined(hold.release()), "repaint")
        XCTAssertTrue(hold.release().isEmpty)
    }

    /// The epoch is how a deadline armed for one keyframe knows it is stale. It
    /// has to move on every open and every close, or a late timer paints a
    /// keyframe the surface has already been given.
    func testEveryOpenAndCloseMovesTheEpoch() {
        var hold = TerminalKeyframeHold(surfaceGrid: old)
        let start = hold.epoch
        XCTAssertTrue(hold.receive(keyframe: bytes("repaint"), at: new).isEmpty)
        let armed = hold.epoch
        XCTAssertNotEqual(armed, start)
        XCTAssertTrue(hold.surfaceReached(new).painted)
        XCTAssertNotEqual(hold.epoch, armed)
    }
}
