import TermioShared
import XCTest
@testable import termio

/// The `vt_stream` contract, across languages: the client terminal, built from
/// termiod's native snapshot and fed the same bytes and resize markers, holds
/// the screen termiod's own VT held after every step.
///
/// `Fixtures/vt-stream-resize.txt` is written by termiod's
/// `the_client_resize_fixture_matches_the_daemon`, which also fails when the
/// file no longer matches the daemon. It attaches inside an OSC sequence, and
/// its resizes cover a shell prompt being blanked before the reflow, one
/// blanked from a continuation row, a truncating resize, and the alternate
/// screen. Screens compare as VT, so styles and modes count, and pixel sizes
/// are compared too.
final class StreamTerminalTests: XCTestCase {
    func testTheClientTerminalTracksTheDaemonThroughEveryResize() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "vt-stream-resize", withExtension: "txt", subdirectory: "Fixtures"),
            "the fixture is missing from the test bundle")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        var terminal: TermiodStreamTerminal?
        var screens = 0
        for (number, line) in lines.enumerated() {
            let fields = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            switch fields[0] {
            case "attach":
                terminal = try TermiodStreamTerminal(nativeSnapshot: try Self.hex(fields[1]))
            case "bytes":
                try XCTUnwrap(terminal).write(try Self.hex(fields[1]))
            case "resize":
                try XCTUnwrap(terminal).resize(
                    rows: try XCTUnwrap(UInt16(fields[1])),
                    cols: try XCTUnwrap(UInt16(fields[2])),
                    reflow: fields[3] == "1"
                )
            case "screen":
                let expected = TermiodStreamTerminal.Screen(
                    rows: try XCTUnwrap(UInt16(fields[1])),
                    cols: try XCTUnwrap(UInt16(fields[2])),
                    widthPixels: try XCTUnwrap(UInt32(fields[3])),
                    heightPixels: try XCTUnwrap(UInt32(fields[4])),
                    cursorX: try XCTUnwrap(UInt16(fields[5])),
                    cursorY: try XCTUnwrap(UInt16(fields[6])),
                    alternate: fields[7] == "1",
                    vt: try Self.hex(fields[8])
                )
                let actual = try XCTUnwrap(terminal).screen()
                XCTAssertEqual(
                    actual, expected,
                    """
                    diverged at fixture line \(number + 1):
                    client \(String(decoding: actual.vt, as: UTF8.self).debugDescription)
                    daemon \(String(decoding: expected.vt, as: UTF8.self).debugDescription)
                    """
                )
                screens += 1
            default:
                XCTFail("unknown fixture line \(number + 1): \(fields[0])")
            }
        }
        XCTAssertGreaterThan(screens, 10)
    }

    /// An `S` frame of format 4 carries the native snapshot whole, and only
    /// in `native`: the replay path, which would paint `vt`, gets nothing.
    func testANativeSnapshotFrameDecodesIntoAClientTerminal() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "vt-stream-resize", withExtension: "txt", subdirectory: "Fixtures"))
        let attach = try XCTUnwrap(
            try String(contentsOf: url, encoding: .utf8).split(separator: "\n").first { $0.hasPrefix("attach ") })
        let native = try Self.hex(String(attach.dropFirst("attach ".count)))
        let title = Data("stream".utf8)
        var payload = Data([TermiodSnapshot.nativeFormatVersion, 0, 6, 0, 20, 0, 0, 0, 0, 0])
        payload += [UInt8(title.count >> 8), UInt8(title.count & 0xff)]
        payload += title
        payload += withUnsafeBytes(of: UInt32(native.count).bigEndian) { Data($0) }
        payload += native

        let frame = try XCTUnwrap(TermiodSnapshot.decode(payload))
        XCTAssertEqual(frame.native, native)
        XCTAssertNil(frame.vt)
        XCTAssertEqual(frame.title, "stream")
        XCTAssertEqual(TermiodSnapshot.render(frame), Data())
        let screen = try TermiodStreamTerminal(nativeSnapshot: native).screen()
        XCTAssertEqual(screen.rows, 6)
        XCTAssertEqual(screen.cols, 20)
    }

    private struct BadHex: Error {}

    private static func hex(_ text: String) throws -> Data {
        var bytes = Data(capacity: text.utf8.count / 2)
        var high: UInt8?
        for character in text.utf8 {
            guard let nibble = UInt8(String(UnicodeScalar(character)), radix: 16) else { throw BadHex() }
            if let first = high {
                bytes.append(first << 4 | nibble)
                high = nil
            } else {
                high = nibble
            }
        }
        guard high == nil else { throw BadHex() }
        return bytes
    }
}
