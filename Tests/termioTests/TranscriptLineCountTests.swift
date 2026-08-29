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
