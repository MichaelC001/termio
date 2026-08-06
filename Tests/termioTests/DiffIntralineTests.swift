import XCTest
@testable import termio

/// The word-level intraline pass, pinned on the cases that motivated it: two edits in one
/// line must produce two spans (prefix/suffix stripping could only produce one, swallowing
/// everything between them), spans must not open or close on whitespace, CJK must not
/// collapse into a single line-long run, and a rewritten line must produce nothing at all.
final class DiffIntralineTests: XCTestCase {
    private func spans(_ old: String, _ new: String) -> (old: [String], new: [String])? {
        guard let result = DiffIntraline.spans(old: old, new: new) else { return nil }
        func texts(_ ranges: [Range<Int>], in text: String) -> [String] {
            let characters = Array(text)
            return ranges.map { String(characters[$0]) }
        }
        return (texts(result.old, in: old), texts(result.new, in: new))
    }

    func testSingleWordEditMarksOnlyThatWord() {
        let result = spans("let value = compute(input)", "let value = derive(input)")
        XCTAssertEqual(result?.old, ["compute"])
        XCTAssertEqual(result?.new, ["derive"])
    }

    func testTwoSeparateEditsProduceTwoSpans() {
        let result = spans("foo(alpha, beta)", "bar(alpha, gamma)")
        XCTAssertEqual(result?.old, ["foo", "beta"])
        XCTAssertEqual(result?.new, ["bar", "gamma"])
    }

    func testAdjacentEditsMergeAcrossUnchangedWhitespace() {
        let result = spans("let a = 1", "var b = 1")
        XCTAssertEqual(result?.old, ["let a"])
        XCTAssertEqual(result?.new, ["var b"])
    }

    func testSpanDoesNotOpenOnWhitespace() {
        let result = spans("call(one)", "call(one, two)")
        XCTAssertEqual(result?.old, [])
        // The inserted text is `, two` — the span starts at the comma, not at the space
        // that happens to precede `two`.
        XCTAssertEqual(result?.new, [", two"])
    }

    func testIndentOnlyChangeKeepsItsWhitespaceSpan() {
        let result = spans("  return x", "    return x")
        XCTAssertEqual(result?.old, ["  "])
        XCTAssertEqual(result?.new, ["    "])
    }

    func testPureInsertionLeavesTheOldSideUnmarked() {
        let result = spans("total = base", "total = base + tax")
        XCTAssertEqual(result?.old, [])
        XCTAssertEqual(result?.new, ["+ tax"])
    }

    func testRewrittenLineIsNotMarked() {
        XCTAssertNil(spans("let greeting = \"hello\"",
                           "await database.commit(transaction, retries: 3)"))
    }

    func testIdenticalLinesAreNotMarked() {
        XCTAssertNil(spans("same", "same"))
    }

    /// CJK has no intra-word boundaries; tokenizing per ideograph is what keeps a
    /// one-character edit from marking the whole line.
    func testCJKMarksOnlyTheChangedCharacters() {
        let result = spans("会话已断开连接", "会话已恢复连接")
        XCTAssertEqual(result?.old, ["断开"])
        XCTAssertEqual(result?.new, ["恢复"])
    }

    /// Character offsets, not UTF-16 or byte offsets — the document maps them back itself.
    func testOffsetsAreCharacterOffsets() {
        let result = DiffIntraline.spans(old: "🎉 party time", new: "🎉 party hard")
        XCTAssertEqual(result?.new, [8..<12])
    }

    /// Past the comparison budget the pair still gets a usable span rather than none.
    func testOversizedPairFallsBackToOneSpanPerSide() {
        let old = (0..<400).map { "token\($0)" }.joined(separator: " ")
        let new = (0..<400).map { "value\($0)" }.joined(separator: " ")
        XCTAssertNil(DiffIntraline.spans(old: old, new: new),
                     "wholly different lines stay unmarked even on the fallback path")

        let sharedTail = " end"
        let mixedOld = (0..<200).map { "token\($0)" }.joined(separator: " ") + sharedTail
        let mixedNew = (0..<200).map { "other\($0)" }.joined(separator: " ") + sharedTail
        // Still nothing to salvage — but the call must return, not hang, on a big pair.
        XCTAssertNil(DiffIntraline.spans(old: mixedOld, new: mixedNew))
    }

    func testOverlongLinesAreSkipped() {
        let long = String(repeating: "a", count: 2100)
        XCTAssertNil(DiffIntraline.spans(old: long, new: long + "b"))
    }
}
