import XCTest
@testable import termio

/// The transcript line counter must give the plain newline count, and must get
/// there by reading only what was appended since the last call — a full re-read
/// per status event is the main-thread stall it replaced.
final class TranscriptLineCountTests: XCTestCase {
    private var path = ""

    override func setUpWithError() throws {
        path = NSTemporaryDirectory() + "termio-linecount-\(UUID().uuidString).jsonl"
        try Data().write(to: URL(fileURLWithPath: path))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(atPath: path)
    }

    private func append(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    func testAppendsAreScannedIncrementally() throws {
        let counter = TranscriptLineCounter()
        try append("a\nb\nc\n")
        XCTAssertEqual(counter.count(path), 3)
        XCTAssertEqual(counter.bytesScanned, 6)
        XCTAssertEqual(counter.count(path), 3)
        XCTAssertEqual(counter.bytesScanned, 6, "an unchanged file costs no read")
        try append("d\ne")
        XCTAssertEqual(counter.count(path), 4)
        XCTAssertEqual(counter.bytesScanned, 9, "only the appended bytes are scanned")
    }

    func testShrunkFileIsCountedAgainFromTheStart() throws {
        let counter = TranscriptLineCounter()
        try append("a\nb\nc\nd\n")
        XCTAssertEqual(counter.count(path), 4)
        try Data("x\n".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(counter.count(path), 1)
    }

    func testMissingFileCountsZeroAndForgetsThePath() throws {
        let counter = TranscriptLineCounter()
        try append("a\n")
        XCTAssertEqual(counter.count(path), 1)
        try FileManager.default.removeItem(atPath: path)
        XCTAssertEqual(counter.count(path), 0)
        try Data("a\nb\n".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(counter.count(path), 2, "a recreated file is counted fresh")
    }

    func testCountSpansChunkBoundaries() throws {
        let counter = TranscriptLineCounter()
        // Well past one 256 KB read, with newlines landing on both sides of every
        // chunk edge.
        let lines = 300_000
        try append(String(repeating: "x\n", count: lines))
        XCTAssertEqual(counter.count(path), lines)
        try append("tail without newline")
        XCTAssertEqual(counter.count(path), lines)
        XCTAssertEqual(counter.bytesScanned, UInt64(lines * 2 + 20))
    }
}

extension TranscriptLineCountTests {
    private func setMtime(_ path: String, toLaterThanNow seconds: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(seconds)], ofItemAtPath: path)
    }

    func testSameSizeInPlaceRewriteIsRecounted() throws {
        let counter = TranscriptLineCounter()
        try append("a\nb\nc\n")                 // 6 bytes, 3 lines
        XCTAssertEqual(counter.count(path), 3)
        // Overwrite in place with the same byte count but a different newline
        // count, and move mtime forward so the same-size branch must recount.
        try Data("aabbc\n".utf8).write(to: URL(fileURLWithPath: path))  // 6 bytes, 1 line
        try setMtime(path, toLaterThanNow: 5)
        XCTAssertEqual(counter.count(path), 1, "a same-size rewrite must not reuse the old count")
    }

    func testReplacedByRenameIsRecounted() throws {
        let counter = TranscriptLineCounter()
        try append("a\nb\nc\nd\n")               // 8 bytes, 4 lines
        XCTAssertEqual(counter.count(path), 4)
        // Atomically replace the path with a different file of the SAME size but
        // a different line count — a new inode the size check alone would miss.
        let other = path + ".new"
        try Data("aabbccd\n".utf8).write(to: URL(fileURLWithPath: other))  // 8 bytes, 1 line
        _ = try FileManager.default.replaceItemAt(
            URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: other))
        XCTAssertEqual(counter.count(path), 1, "a replaced inode must force a recount")
    }

    func testUnchangedFileAfterMtimeSettleStillCostsNoRead() throws {
        let counter = TranscriptLineCounter()
        try append("a\nb\n")
        XCTAssertEqual(counter.count(path), 2)
        let after = counter.bytesScanned
        XCTAssertEqual(counter.count(path), 2)
        XCTAssertEqual(counter.bytesScanned, after, "an untouched file is not re-read")
    }
}
