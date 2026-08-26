import XCTest
@testable import termio

/// The editor's pure text logic: line/offset mapping and bracket pairing. These are the pieces
/// where a silent off-by-one becomes "revealed the wrong line" — cheap to pin down.
final class TextPositionsTests: XCTestCase {
    func testOffsetOfLineWalksAndClamps() {
        let text = "one\ntwo\nthree\n" as NSString
        XCTAssertEqual(TextPositions.offset(ofLine: 1, in: text), 0)
        XCTAssertEqual(TextPositions.offset(ofLine: 2, in: text), 4)
        XCTAssertEqual(TextPositions.offset(ofLine: 3, in: text), 8)
        // Past the end: clamps into the document instead of running off it.
        XCTAssertLessThan(TextPositions.offset(ofLine: 99, in: text), text.length)
    }

    /// Multi-byte content doesn't shift the mapping: `offset(ofLine:)` counts UTF-16 units, the
    /// same unit `NSTextView` selections use.
    func testOffsetOfLineCountsUTF16Units() {
        let text = "alpha\nβeta 🙂\ngamma" as NSString
        XCTAssertEqual(TextPositions.offset(ofLine: 2, in: text), 6)
        // "🙂" is a surrogate pair, so line 3 starts 8 units after line 2, not 7.
        XCTAssertEqual(TextPositions.offset(ofLine: 3, in: text), 14)
    }
}

final class BracketMatcherTests: XCTestCase {
    func testSimplePair() {
        let text = "f(x)" as NSString
        XCTAssertEqual(BracketMatcher.match(at: 1, in: text), 3)
        XCTAssertEqual(BracketMatcher.match(at: 3, in: text), 1)
    }

    func testNestedPairsSkipInnerLevels() {
        let text = "{ a: [1, (2)], b: {} }" as NSString
        XCTAssertEqual(BracketMatcher.match(at: 0, in: text), 21)
        XCTAssertEqual(BracketMatcher.match(at: 5, in: text), 12) // [ … ]
        XCTAssertEqual(BracketMatcher.match(at: 9, in: text), 11) // ( … )
    }

    func testEachKindCountsOnlyItself() {
        // Interleaved kinds: the scanner tracks one pair-kind at a time (the standard
        // lightweight-editor behavior — strict cross-kind nesting would need a full parser
        // and get fooled by brackets in strings far more often than this does).
        let text = "([)]" as NSString
        XCTAssertEqual(BracketMatcher.match(at: 0, in: text), 2) // ( … )
        XCTAssertEqual(BracketMatcher.match(at: 1, in: text), 3) // [ … ]
    }

    func testUnbalancedReturnsNil() {
        let text = "((a)" as NSString
        XCTAssertNil(BracketMatcher.match(at: 0, in: text))
        XCTAssertEqual(BracketMatcher.match(at: 1, in: text), 3)
    }

    func testNonBracketAndOutOfBounds() {
        let text = "abc" as NSString
        XCTAssertNil(BracketMatcher.match(at: 1, in: text))
        XCTAssertNil(BracketMatcher.match(at: -1, in: text))
        XCTAssertNil(BracketMatcher.match(at: 3, in: text))
    }
}

/// Which selections the occurrence wash chases. The wash itself needs a laid-out text view, but
/// what it decides to look for is pure — and every rule here is one that, wrong, paints the
/// document at rest.
final class OccurrenceTargetTests: XCTestCase {
    private let source = "let total = count + total\nlet other = total" as NSString

    private func target(_ selection: NSRange, editable: Bool = true) -> OccurrenceTarget? {
        OccurrenceTarget.resolve(selection: selection, in: source, allowsCaretWord: editable)
    }

    func testCaretInsideAWordTakesTheWholeWord() {
        let inside = target(NSRange(location: 6, length: 0)) // "to|tal"
        XCTAssertEqual(inside?.text, "total")
        XCTAssertEqual(inside?.range, NSRange(location: 4, length: 5))
        XCTAssertEqual(inside?.wholeWord, true)
    }

    /// A caret parked at either edge still belongs to the word — the trailing edge is where you
    /// land after double-clicking or arrowing to the end of a name.
    func testCaretAtWordEdges() {
        XCTAssertEqual(target(NSRange(location: 4, length: 0))?.text, "total")
        XCTAssertEqual(target(NSRange(location: 9, length: 0))?.text, "total")
    }

    func testCaretAwayFromAnyWordHasNoTarget() {
        XCTAssertNil(target(NSRange(location: 10, length: 0))) // on "="
        XCTAssertNil(target(NSRange(location: 11, length: 0))) // in the gap after it
    }

    /// A read-only peek shows no caret, so an empty selection there is a click, not a place.
    func testReadOnlyBufferIgnoresTheCaret() {
        XCTAssertNil(target(NSRange(location: 6, length: 0), editable: false))
        // A real selection still counts — that's the reading gesture the peek has.
        XCTAssertEqual(target(NSRange(location: 4, length: 5), editable: false)?.text, "total")
    }

    func testSelectionSpanningLinesIsSkipped() {
        XCTAssertNil(target(NSRange(location: 20, length: 10)))
    }

    func testWhitespaceOnlySelectionIsSkipped() {
        XCTAssertNil(target(NSRange(location: 3, length: 1)))
    }

    func testOversizedSelectionIsSkipped() {
        let long = String(repeating: "a", count: OccurrenceTarget.maximumSelectionLength + 1) as NSString
        XCTAssertNil(OccurrenceTarget.resolve(
            selection: NSRange(location: 0, length: long.length), in: long, allowsCaretWord: true))
    }

    /// A partial selection matches literally: selecting `tot` must not light up every `total`.
    func testPartialSelectionDropsTheWordBound() {
        let partial = target(NSRange(location: 4, length: 3))
        XCTAssertEqual(partial?.text, "tot")
        XCTAssertEqual(partial?.wholeWord, false)
    }

    /// Word scanning walks UTF-16 units, the unit `NSTextView` selections speak — a caret past an
    /// astral character must not read a surrogate half as a letter and swallow the neighbors.
    func testSurrogatePairsBoundAWord() {
        let text = "a🙂name" as NSString
        XCTAssertEqual(OccurrenceTarget.wordRange(at: 5, in: text), NSRange(location: 3, length: 4))
    }
}
