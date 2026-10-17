import XCTest
@testable import termio

/// Dragging a tab in the horizontal layout reorders the group's roster (`movingTab`). A split
/// group is one tab, so its members must move together and stay together, or the sidebar's
/// bracket would break in the vertical layout.
final class TabReorderTests: XCTestCase {
    private let a = Session.ID()
    private let b = Session.ID()
    private let c = Session.ID()
    private let d = Session.ID()
    private let e = Session.ID()

    func testLoneTabMovesRight() {
        let rows = movingTab(in: [a, b, c, d], splits: [], from: 0, to: 2)
        XCTAssertEqual(rows, [b, c, a, d])
    }

    func testLoneTabMovesLeft() {
        let rows = movingTab(in: [a, b, c, d], splits: [], from: 3, to: 0)
        XCTAssertEqual(rows, [d, a, b, c])
    }

    /// Tabs: [a] [b c] [d]. Moving the split to the end keeps b before c, in roster order.
    func testSplitGroupMovesAsOneTab() {
        let rows = movingTab(in: [a, b, c, d], splits: [[c, b]], from: 1, to: 2)
        XCTAssertEqual(rows, [a, d, b, c])
    }

    /// Tabs: [a] [b c d] [e]. A lone tab dropped past the split lands after all of it.
    func testLoneTabMovesPastASplitGroup() {
        let rows = movingTab(in: [a, b, c, d, e], splits: [[b, c, d]], from: 0, to: 1)
        XCTAssertEqual(rows, [b, c, d, a, e])
    }

    func testOutOfRangeLeavesTheRowsAlone() {
        XCTAssertEqual(movingTab(in: [a, b], splits: [], from: 5, to: 0), [a, b])
        XCTAssertEqual(movingTab(in: [a, b], splits: [], from: 0, to: 9), [b, a])
    }
}
