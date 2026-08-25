import XCTest
import TermioShared
@testable import termio

/// Which keyframes a termiod attachment is allowed to paint.
///
/// The daemon's `S` payload is a formatted repaint — wrapped rows and all — laid
/// out for the grid the host VT held when it was taken. Painting one into a
/// surface of a different width shifts every wrapped row, and an incrementally
/// redrawing TUI never repairs it, so the damage sits on screen until the next
/// keystroke. The rule has two halves and both have a real failure mode: a
/// writer drops the mismatch because its own resize will produce a correct one,
/// and an observer must paint it anyway because nothing it does will produce
/// another.
final class TermiodKeyframeGridTests: XCTestCase {
    private let surface = TerminalGrid(rows: 40, cols: 100)

    func testWriterSkipsAKeyframeTakenAtAnotherGrid() {
        XCTAssertTrue(TermiodSessionLink.snapshotIsStale(
            payload: TerminalGrid(rows: 37, cols: 54),
            target: surface,
            isWriter: true))
    }

    func testWriterPaintsAKeyframeThatMatchesTheSurface() {
        XCTAssertFalse(TermiodSessionLink.snapshotIsStale(
            payload: surface,
            target: surface,
            isWriter: true))
    }

    /// A single column apart is the case that matters: it is invisible in a log
    /// line and it wraps every full-width row one cell early.
    func testOneColumnOfDriftIsStale() {
        XCTAssertTrue(TermiodSessionLink.snapshotIsStale(
            payload: TerminalGrid(rows: 40, cols: 99),
            target: surface,
            isWriter: true))
    }

    func testObserverPaintsAMismatchedKeyframe() {
        XCTAssertFalse(TermiodSessionLink.snapshotIsStale(
            payload: TerminalGrid(rows: 37, cols: 54),
            target: surface,
            isWriter: false))
    }
}
