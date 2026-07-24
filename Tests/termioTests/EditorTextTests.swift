import XCTest
@testable import termio

/// The editor's pure text logic: line/offset mapping and bracket pairing. These are the pieces
/// where a silent off-by-one becomes "revealed the wrong line" — cheap to pin down.
final class TextPositionsTests: XCTestCase {
    func testAsciiOffsets() {
        let text = "let a = 1\nlet b = 2\n" as NSString
        XCTAssertEqual(TextPositions.position(utf16Offset: 0, in: text).line, 0)
        XCTAssertEqual(TextPositions.position(utf16Offset: 0, in: text).character, 0)
        // "l" of the second line: offset 10 → line 1, character 0.
        XCTAssertEqual(TextPositions.position(utf16Offset: 10, in: text).line, 1)
        XCTAssertEqual(TextPositions.position(utf16Offset: 10, in: text).character, 0)
        // Mid-second-line.
        XCTAssertEqual(TextPositions.position(utf16Offset: 14, in: text).character, 4)
    }

    func testUTF16UnitsCountSurrogatePairsAsTwo() {
        // "🙂" is two UTF-16 units, so the symbol after it starts at character 3.
        let text = "🙂 var x = 1" as NSString
        let position = TextPositions.position(utf16Offset: 3, in: text)
        XCTAssertEqual(position.line, 0)
        XCTAssertEqual(position.character, 3)
        // CJK stays one unit each.
        let cjk = "中文注释 foo" as NSString
        XCTAssertEqual(TextPositions.position(utf16Offset: 5, in: cjk).character, 5)
    }

    func testCRLFAdvancesOncePerPair() {
        let text = "a\r\nb\r\nc" as NSString
        // "b" sits at offset 3: one \r\n behind it → line 1, character 0.
        XCTAssertEqual(TextPositions.position(utf16Offset: 3, in: text).line, 1)
        XCTAssertEqual(TextPositions.position(utf16Offset: 3, in: text).character, 0)
    }

    func testOffsetClampsOutOfRange() {
        let text = "ab" as NSString
        XCTAssertEqual(TextPositions.position(utf16Offset: -5, in: text).character, 0)
        XCTAssertEqual(TextPositions.position(utf16Offset: 99, in: text).character, 2)
    }

    func testLineColumnIsOneBased() {
        let text = "ab\ncd" as NSString
        let footer = TextPositions.lineColumn(utf16Offset: 4, in: text)
        XCTAssertEqual(footer.line, 2)
        XCTAssertEqual(footer.column, 2)
    }

    func testOffsetOfLineWalksAndClamps() {
        let text = "one\ntwo\nthree\n" as NSString
        XCTAssertEqual(TextPositions.offset(ofLine: 1, in: text), 0)
        XCTAssertEqual(TextPositions.offset(ofLine: 2, in: text), 4)
        XCTAssertEqual(TextPositions.offset(ofLine: 3, in: text), 8)
        // Past the end: clamps into the document instead of running off it.
        XCTAssertLessThan(TextPositions.offset(ofLine: 99, in: text), text.length)
    }

    /// The two directions agree: offset(ofLine:) followed by position() lands on the same line.
    func testRoundTrip() {
        let text = "alpha\nβeta 🙂\ngamma" as NSString
        for line in 1...3 {
            let offset = TextPositions.offset(ofLine: line, in: text)
            XCTAssertEqual(TextPositions.position(utf16Offset: offset, in: text).line, line - 1)
        }
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
