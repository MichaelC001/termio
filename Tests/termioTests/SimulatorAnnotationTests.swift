import AppKit
import XCTest
@testable import termio

/// Annotate draws in the editor's small box and writes the marks onto the
/// screenshot at its own resolution. These pin that a mark lands where it was
/// drawn on the full-size PNG, and that the PNG keeps the screenshot's size.
final class SimulatorAnnotationTests: XCTestCase {
    private func white(_ width: Int, _ height: Int) -> NSImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep else { return NSImage() }
        for x in 0 ..< width { for y in 0 ..< height { rep.setColor(.white, atX: x, y: y) } }
        let image = NSImage(size: CGSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }

    private func redness(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> CGFloat {
        guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return 0 }
        return color.redComponent - color.greenComponent
    }

    func testAMarkLandsWhereItWasDrawnAtFullResolution() throws {
        // A rectangle round the top-left quarter, measured in the unit square.
        let mark = SimulatorMark(tool: .rectangle, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.5, y: 0.5)])
        let png = try XCTUnwrap(SimulatorAnnotationRenderer.render(white(300, 600), marks: [mark]))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(rep.pixelsWide, 300)
        XCTAssertEqual(rep.pixelsHigh, 600)
        // The left edge at x = 30, halfway down the rectangle (y = 180 from the top).
        XCTAssertGreaterThan(redness(rep, 30, 180), 0.5)
        // Inside the rectangle and well outside it, the screenshot shows through.
        XCTAssertLessThan(redness(rep, 90, 180), 0.1)
        XCTAssertLessThan(redness(rep, 250, 500), 0.1)
    }

    func testNoMarksIsTheScreenshotUnchanged() throws {
        let png = try XCTUnwrap(SimulatorAnnotationRenderer.render(white(40, 80), marks: []))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(rep.pixelsWide, 40)
        XCTAssertLessThan(redness(rep, 20, 40), 0.1)
    }
}
