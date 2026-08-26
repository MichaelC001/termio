import XCTest
@testable import termio

/// What the Search pane draws, and where its highlights come from.
///
/// The defect these pin: the results row used to re-find the query in the line
/// itself, with `.caseInsensitive` and canonical (not literal) comparison —
/// a *second* matcher beside the one that produced the hit. Two matchers
/// disagree exactly where it looks like a bug: an uppercase query painting
/// lowercase text, and a line whose match sat past the length cap lighting up
/// nothing at all. Spans now come from the matcher; nothing downstream searches.
final class SearchExcerptTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/repo", isDirectory: true)

    private func match(_ text: String, query: String, insensitive: Bool,
                       line: Int = 10, before: [String] = [], after: [String] = [])
    -> ContentMatch {
        ContentSearch.match(
            relative: "a.swift", root: root, line: line, text: text,
            query: query, insensitive: insensitive, before: before, after: after)
    }

    private func marked(_ match: ContentMatch) -> [String] {
        match.spans.map { String(match.text[$0]) }
    }

    // MARK: - Spans follow the matcher

    /// Smart case is the search's rule, so it has to be the highlight's rule.
    /// An uppercase query greps case-sensitively; painting `widget` under a
    /// `Widget` search marks something the search deliberately did not match.
    func testAnUppercaseQueryDoesNotPaintLowercaseText() {
        let hit = match("let Widget = widget()", query: "Widget", insensitive: false)
        XCTAssertEqual(marked(hit), ["Widget"])
    }

    func testALowercaseQueryPaintsEveryCase() {
        let hit = match("let Widget = widget()", query: "widget", insensitive: true)
        XCTAssertEqual(marked(hit), ["Widget", "widget"])
    }

    /// Every occurrence on the line is marked, not just the first — one row can
    /// legitimately hold several hits.
    func testEveryOccurrenceOnTheLineIsMarked() {
        let hit = match("a-b-a-b-a", query: "a", insensitive: true)
        XCTAssertEqual(hit.spans.count, 3)
    }

    /// A hit far down a minified line used to arrive with the line truncated in
    /// front of it, so the row drew no highlight at all. The window follows the
    /// match instead, and says it was cut.
    func testALongLineIsWindowedAroundItsMatch() {
        let text = String(repeating: "x", count: 900) + "needle" + String(repeating: "y", count: 900)
        let hit = match(text, query: "needle", insensitive: true)

        XCTAssertTrue(hit.isWindowed, "the row must be able to say the line was cut")
        XCTAssertEqual(marked(hit), ["needle"], "the hit survives the window")
        XCTAssertLessThan(hit.text.count, text.count)
    }

    /// A query that is not on the line marks nothing — no guessing, no partial.
    func testALineWithoutTheQueryMarksNothing() {
        XCTAssertTrue(match("nothing here", query: "absent", insensitive: true).spans.isEmpty)
    }

    // MARK: - Excerpt composition

    /// Two hits close enough that their context overlaps are one run of lines,
    /// not two — reading the same context twice with a divider through it is
    /// worse than reading it once.
    func testNearbyHitsMergeIntoOneRun() {
        let first = match("hit one", query: "hit", insensitive: true, line: 10,
                          before: ["a", "b"], after: ["c", "d"])
        let second = match("hit two", query: "hit", insensitive: true, line: 13,
                           before: ["c", "d"], after: ["e", "f"])

        let excerpts = SearchExcerpt.compose([first, second])

        XCTAssertEqual(excerpts.count, 1, "overlapping context is one excerpt")
        let numbers = excerpts[0].lines.map(\.number)
        XCTAssertEqual(numbers, Array(8...15), "each line once, in order")
        XCTAssertEqual(excerpts[0].lines.filter(\.isMatch).map(\.number), [10, 13])
    }

    /// Hits far apart stay separate runs, so the gap between them can be shown.
    func testDistantHitsStaySeparateRuns() {
        let first = match("hit one", query: "hit", insensitive: true, line: 10,
                          before: ["a"], after: ["b"])
        let second = match("hit two", query: "hit", insensitive: true, line: 90,
                           before: ["c"], after: ["d"])

        XCTAssertEqual(SearchExcerpt.compose([first, second]).count, 2)
    }

    /// A line that arrives first as somebody else's context and later as a hit
    /// has to end up drawn as the hit, or the match goes unpainted.
    func testAContextLineThatIsAlsoAHitBecomesTheHit() {
        let first = match("alpha", query: "beta", insensitive: true, line: 10,
                          before: [], after: ["beta here"])
        let second = match("beta here", query: "beta", insensitive: true, line: 11)

        let excerpts = SearchExcerpt.compose([first, second])

        XCTAssertEqual(excerpts.count, 1)
        let eleven = excerpts[0].lines.first { $0.number == 11 }
        XCTAssertEqual(eleven?.isMatch, true)
        XCTAssertFalse(eleven?.spans.isEmpty ?? true, "and it is painted")
    }

    /// The line numbers in the gutter are the file's, taken from the hit and its
    /// context rather than from the excerpt's position in the list.
    func testGutterNumbersComeFromTheFile() {
        let hit = match("x", query: "x", insensitive: true, line: 42,
                        before: ["above"], after: ["below"])
        let excerpt = SearchExcerpt.compose([hit])[0]
        XCTAssertEqual(excerpt.lines.map(\.number), [41, 42, 43])
        XCTAssertEqual(excerpt.firstLine, 41)
    }
}
