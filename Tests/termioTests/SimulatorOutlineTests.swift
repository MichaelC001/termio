import XCTest
@testable import termio

/// `termio sim inspect` prints the accessibility tree as an outline an agent taps
/// from, so what it leaves out matters as much as what it prints: a container that
/// says nothing must not cost a line, and an element off the screen must not be
/// offered as something to tap. Both shapes come from real home-screen reads, where
/// SpringBoard nests every icon in unlabelled views and keeps the App Library one
/// page to the right.
final class SimulatorOutlineTests: XCTestCase {
    private func element(
        _ type: String, label: String? = nil, frame: (Double, Double, Double, Double)? = nil,
        children: [[String: Any]] = []
    ) -> [String: Any] {
        var element: [String: Any] = ["type": type, "children": children]
        if let label { element["label"] = label }
        if let frame {
            element["frame"] = ["x": frame.0, "y": frame.1, "width": frame.2, "height": frame.3]
        }
        return element
    }

    private func document(_ elements: [[String: Any]], screen: (Double, Double) = (402, 874)) -> [String: Any] {
        ["elements": elements, "screen": ["width": screen.0, "height": screen.1], "truncated": false]
    }

    func testUnlabelledContainersFoldAwayAndLiftTheirChildren() {
        let tree = document([
            element("Other", frame: (0, 0, 402, 874), children: [
                element("Button", label: "Continue", frame: (120, 640, 160, 44)),
            ]),
        ])
        XCTAssertEqual(TermioStore.outline(tree), "Button \"Continue\" @ 120,640 160x44")
    }

    func testElementsWhollyOffScreenAreCountedNotPrinted() {
        let tree = document([
            element("Icon", label: "Maps", frame: (30, 88, 162, 185)),
            element("TextField", label: "App Library", frame: (836, 90, 338, 48)),
        ])
        XCTAssertEqual(
            TermioStore.outline(tree),
            "Icon \"Maps\" @ 30,88 162x185\n(1 off-screen elements omitted)")
    }

    func testAnIconOnAPageNotShownHasAnEmptyFrameAndIsOmitted() {
        let tree = document([
            element("Icon", label: "Files", frame: (30, 88, 64, 64)),
            element("Icon", label: "Settings", frame: (0, 0, 0, 0)),
        ])
        XCTAssertEqual(
            TermioStore.outline(tree),
            "Icon \"Files\" @ 30,88 64x64\n(1 off-screen elements omitted)")
    }

    func testAnElementCrossingTheEdgeStays() {
        let tree = document([element("Cell", label: "Row", frame: (0, 860, 402, 44))])
        XCTAssertEqual(TermioStore.outline(tree), "Cell \"Row\" @ 0,860 402x44")
    }

    func testAPointOnASilentElementStillNamesIt() {
        let tree = document([element("SBIconImageView", frame: (307, 384, 60, 60))])
        XCTAssertEqual(TermioStore.outline(tree), "SBIconImageView @ 307,384 60x60")
    }

    /// After a rotation an iPad app's tree still holds the old orientation's
    /// layout, in containers taller than the screen now is; its buttons are
    /// not on screen where their frames say.
    func testALayoutNoLongerShownIsOmitted() {
        let tree = document([
            element("Other", label: "Calendar", frame: (0, 0, 1180, 1180), children: [
                element("UIView", frame: (0, 0, 820, 1180), children: [
                    element("Button", label: "Year", frame: (486, 33, 75, 36)),
                ]),
                element("UIView", frame: (0, 0, 1180, 820), children: [
                    element("Button", label: "Year", frame: (666, 33, 75, 36)),
                ]),
            ]),
        ], screen: (1180, 1180))
        XCTAssertEqual(
            TermioStore.outline(tree, interface: CGSize(width: 1180, height: 820)),
            """
            Other "Calendar" @ 0,0 1180x1180
              Button "Year" @ 666,33 75x36
            (1 containers of a layout no longer shown omitted)
            """)
    }

    /// iOS reports an empty field's placeholder as its value, and an agent read
    /// it as text to delete (termio-sh/termio#774). The helper drops such a
    /// value and sends the placeholder beside it.
    func testAnEmptyFieldPrintsItsPlaceholderNotAValue() {
        var empty = element("TextField", frame: (71, 307, 260, 35))
        empty["value"] = NSNull()
        empty["placeholder"] = "ws://mac-hostname:8787"
        var typed = element("TextField", frame: (71, 360, 260, 35))
        typed["value"] = "ws://studio.local:8787"
        typed["placeholder"] = "ws://mac-hostname:8787"
        XCTAssertEqual(
            TermioStore.outline(document([empty, typed])),
            """
            TextField placeholder "ws://mac-hostname:8787" @ 71,307 260x35
            TextField = "ws://studio.local:8787" @ 71,360 260x35
            """)
    }

    func testAnEmptyScreenSaysSo() {
        XCTAssertEqual(TermioStore.outline(document([])), "no accessible elements")
    }
}
