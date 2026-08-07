import TermioShared
import XCTest

/// The shared diff model the iOS reader renders from: parsing unified-diff text into
/// numbered lines, folding unchanged runs into bands, and marking the changed span of a
/// modified line. Pure logic, and the place an off-by-one turns into "the phone showed
/// the wrong line number next to the wrong code".
final class DiffParserTests: XCTestCase {
    func testLineNumbersFollowTheHunkHeader() {
        let diff = """
        @@ -10,4 +10,5 @@ func makeThing() {
             let a = 1
        -    let b = 2
        +    let b = 3
        +    let c = 4
             return a
        """
        let lines = DiffParser.lines(from: diff)
        XCTAssertEqual(lines.map(\.kind), [.hunk, .context, .deletion, .addition, .addition, .context])
        // Context at the hunk's start sits on line 10 of both sides.
        XCTAssertEqual(lines[1].oldLine, 10)
        XCTAssertEqual(lines[1].newLine, 10)
        // A deletion advances only the old side, an addition only the new side.
        XCTAssertEqual(lines[2].oldLine, 11)
        XCTAssertNil(lines[2].newLine)
        XCTAssertEqual(lines[3].newLine, 11)
        XCTAssertNil(lines[3].oldLine)
        XCTAssertEqual(lines[4].newLine, 12)
        // The trailing context resumes past both edits.
        XCTAssertEqual(lines[5].oldLine, 12)
        XCTAssertEqual(lines[5].newLine, 13)
    }

    func testMarkersAreStrippedAndPlumbingDropped() {
        let diff = """
        diff --git a/App.swift b/App.swift
        index 1234567..89abcde 100644
        --- a/App.swift
        +++ b/App.swift
        @@ -1,2 +1,2 @@
        -let old = 1
        +let new = 1
        \\ No newline at end of file
        """
        let lines = DiffParser.lines(from: diff)
        XCTAssertEqual(lines.map(\.kind), [.hunk, .deletion, .addition])
        XCTAssertEqual(lines[1].text, "let old = 1")
        XCTAssertEqual(lines[2].text, "let new = 1")
    }

    /// A `+` in column 1 of the *content* (a diff of a diff, or a leading-plus line)
    /// must still read as an addition — the marker is positional, not semantic.
    func testEmptyContextLineSurvives() {
        let diff = """
        @@ -1,3 +1,3 @@
         first
        \u{20}
         third
        """
        let lines = DiffParser.lines(from: diff)
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[2].kind, .context)
        XCTAssertEqual(lines[2].text, "")
    }
}

final class DiffFoldTests: XCTestCase {
    /// One addition buried in a long file: the run before it keeps 3 lines of context
    /// and folds the rest into an expandable band; the run after it does the same.
    func testLongUnchangedRunsCollapseAroundAChange() {
        var rows: [DiffLine] = []
        for i in 0..<30 {
            rows.append(DiffLine(id: i, kind: .context, text: "line \(i)", oldLine: i + 1, newLine: i + 1))
        }
        rows.insert(DiffLine(id: 100, kind: .addition, text: "new", oldLine: nil, newLine: 16), at: 15)

        let items = DiffParser.displayItems(lines: rows, expanded: [])
        guard case .band(let id, let count, let expandable) = items.first else {
            return XCTFail("a 15-line leading run should fold to a band, got \(String(describing: items.first))")
        }
        XCTAssertTrue(expandable)
        // 15 lines, 3 kept facing the change → 12 hidden, keyed by the first of them.
        XCTAssertEqual(count, 12)
        XCTAssertEqual(id, 0)
        XCTAssertEqual(items.count, 1 + 3 + 1 + 3 + 1) // band, context, add, context, band
        XCTAssertEqual(items.filter { if case .band = $0 { return true } else { return false } }.count, 2)
    }

    func testExpandingABandSplicesItsLinesBack() {
        var rows: [DiffLine] = []
        for i in 0..<30 {
            rows.append(DiffLine(id: i, kind: .context, text: "line \(i)", oldLine: i + 1, newLine: i + 1))
        }
        rows.insert(DiffLine(id: 100, kind: .addition, text: "new", oldLine: nil, newLine: 16), at: 15)

        let items = DiffParser.displayItems(lines: rows, expanded: [0])
        // The leading band is gone; its 12 lines are back, so only the trailing one is left.
        XCTAssertEqual(items.filter { if case .band = $0 { return true } else { return false } }.count, 1)
        guard case .line(let first) = items[0] else { return XCTFail("expanded band should start with a line") }
        XCTAssertEqual(first.id, 0)
    }

    func testShortRunsAreNeverFolded() {
        var rows: [DiffLine] = []
        for i in 0..<8 {
            rows.append(DiffLine(id: i, kind: .context, text: "line \(i)", oldLine: i + 1, newLine: i + 1))
        }
        rows.append(DiffLine(id: 100, kind: .addition, text: "new", oldLine: nil, newLine: 9))
        let items = DiffParser.displayItems(lines: rows, expanded: [])
        XCTAssertEqual(items.count, 9)
        XCTAssertFalse(items.contains { if case .band = $0 { return true } else { return false } })
    }

    /// A diff fetched at git's default context has real gaps between hunks. Those become
    /// bands too — but fixed ones: the hidden lines were never sent, so tapping can't
    /// reveal them.
    func testHunkGapBecomesAFixedBand() {
        let diff = """
        @@ -1,2 +1,2 @@
        -one
        +ONE
        @@ -40,2 +40,2 @@
        -forty
        +FORTY
        """
        let items = DiffParser.displayItems(lines: DiffParser.lines(from: diff), expanded: [])
        let bands = items.compactMap { item -> (Int, Bool)? in
            if case .band(_, let count, let expandable) = item { return (count, expandable) }
            return nil
        }
        XCTAssertEqual(bands.count, 1)
        XCTAssertEqual(bands.first?.0, 38) // lines 2…39 of the new side
        XCTAssertEqual(bands.first?.1, false)
    }
}

final class DiffIntralineSpanTests: XCTestCase {
    func testSpanCoversTheChangedWordOnly() {
        let diff = """
        @@ -1,1 +1,1 @@
        -let value = oldName
        +let value = newName
        """
        let lines = DiffParser.lines(from: diff)
        guard let old = lines[1].emphasis, let new = lines[2].emphasis else {
            return XCTFail("a one-word edit should carry an intraline span")
        }
        XCTAssertEqual(String(Array(lines[1].text)[old]), "oldName")
        XCTAssertEqual(String(Array(lines[2].text)[new]), "newName")
    }

    /// The boundary snaps outward to whole words: peeling the shared `alph` prefix
    /// alone would emphasize a bare `a` / `b` and leave the identifier split.
    func testSpanSnapsToWordBoundaries() {
        let diff = """
        @@ -1,1 +1,1 @@
        -call(alpha)
        +call(alphb)
        """
        let lines = DiffParser.lines(from: diff)
        guard let old = lines[1].emphasis else {
            return XCTFail("a near-identical pair should carry a span")
        }
        XCTAssertEqual(String(Array(lines[1].text)[old]), "alpha")
    }

    /// Two lines with almost nothing in common are a rewrite, not an edit — spanning
    /// them would highlight the whole line, which says nothing.
    func testUnrelatedLinesGetNoSpan() {
        let diff = """
        @@ -1,1 +1,1 @@
        -let a = 1
        +print(somethingElseEntirely)
        """
        let lines = DiffParser.lines(from: diff)
        XCTAssertNil(lines[1].emphasis)
        XCTAssertNil(lines[2].emphasis)
    }
}
