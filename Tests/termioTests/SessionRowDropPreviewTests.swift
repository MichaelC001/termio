import XCTest
@testable import termio

/// While a sidebar row is dragged, the rows are drawn in the order a drop would leave them
/// (`previewingRowDrop`), so the gap the rows make room around is the drop position. A preview
/// that disagreed with `reorderSession` would land the row somewhere other than the gap.
final class SessionRowDropPreviewTests: XCTestCase {
    private let a = Session(title: "a")
    private let b = Session(title: "b")
    private let c = Session(title: "c")
    private let d = Session(title: "d")

    private func titles(_ rows: [Session]) -> [String] { rows.map(\.title) }

    func testMovingDownPutsTheRowBelowTheTarget() {
        let rows = previewingRowDrop([a, b, c, d], moved: a.id, beside: c.id, insert: .below)
        XCTAssertEqual(titles(rows), ["b", "c", "a", "d"])
    }

    func testMovingUpPutsTheRowAboveTheTarget() {
        let rows = previewingRowDrop([a, b, c, d], moved: d.id, beside: b.id, insert: .above)
        XCTAssertEqual(titles(rows), ["a", "d", "b", "c"])
    }

    /// The gap already beside the target: nothing moves.
    func testAGapAlreadyThereLeavesTheOrder() {
        let rows = previewingRowDrop([a, b, c, d], moved: b.id, beside: c.id, insert: .above)
        XCTAssertEqual(titles(rows), ["a", "b", "c", "d"])
    }

    /// Each list in the sidebar asks for its own order; a drag over another list leaves it alone.
    func testAListWithoutTheDraggedRowIsUnchanged() {
        let other = Session(title: "x")
        XCTAssertEqual(titles(previewingRowDrop([a, b], moved: other.id, beside: a.id, insert: .below)),
                       ["a", "b"])
        XCTAssertEqual(titles(previewingRowDrop([a, b], moved: a.id, beside: other.id, insert: .below)),
                       ["a", "b"])
    }

    /// A gap drawn between two rows of a group is not where the row lands: the commit gathers
    /// the group back into one run, so the preview has to as well.
    func testAGapInsideAGroupLandsAfterTheGroup() {
        let rows = committedRowDrop([a, b, c, d], moved: d.id, beside: b.id, insert: .above,
                                    groups: [[a.id, b.id]])
        XCTAssertEqual(titles(rows), ["a", "b", "d", "c"])
    }

    func testAGapOutsideEveryGroupIsTheGapItself() {
        let rows = committedRowDrop([a, b, c, d], moved: a.id, beside: c.id, insert: .below,
                                    groups: [])
        XCTAssertEqual(titles(rows), ["b", "c", "a", "d"])
    }
}
