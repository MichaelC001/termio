import XCTest
@testable import termio

/// Select Element outlines what the pointer is over, read from the helper's
/// hit test. The tree it answers with nests silent containers and images
/// inside the button a person means, and after a rotation still holds the old
/// layout; these pin which element is picked.
final class SimulatorElementTests: XCTestCase {
    private let interface = CGSize(width: 402, height: 874)

    private func element(
        _ type: String, label: String? = nil, id: String? = nil,
        _ x: Double, _ y: Double, _ width: Double, _ height: Double, children: [[String: Any]] = []
    ) -> [String: Any] {
        var element: [String: Any] = [
            "type": type, "frame": ["x": x, "y": y, "width": width, "height": height], "children": children,
        ]
        if let label { element["label"] = label }
        if let id { element["identifier"] = id }
        return element
    }

    private var tabBar: [String: Any] {
        ["elements": [element("Other", label: "Termio", 0, 0, 402, 874, children: [
            element("Other", 0, 780, 402, 94, children: [
                element("Button", label: "Settings", id: "home.tab.settings", 304, 792, 96, 48, children: [
                    element("Image", 330, 800, 40, 30),
                ]),
            ]),
        ])]]
    }

    func testThePointerOnAButtonsImagePicksTheButton() throws {
        let picked = try XCTUnwrap(SimulatorElement.pick(from: tabBar, at: CGPoint(x: 340, y: 810), interface: interface))
        XCTAssertEqual(picked.label, "Settings")
        XCTAssertEqual(picked.summary, "Button \"Settings\" #home.tab.settings @ 304,792 96x48")
    }

    func testAPointOnNothingButTheAppPicksTheApp() throws {
        let picked = try XCTUnwrap(SimulatorElement.pick(from: tabBar, at: CGPoint(x: 100, y: 820), interface: interface))
        XCTAssertEqual(picked.label, "Termio")
    }

    func testALayoutNoLongerShownIsPassedOver() throws {
        let rotated: [String: Any] = ["elements": [element("Other", label: "Termio", 0, 0, 402, 874, children: [
            element("Other", 0, 0, 874, 874, children: [element("Button", label: "Old", 300, 790, 96, 48)]),
            element("Button", label: "New", 300, 790, 96, 48),
        ])]]
        let picked = try XCTUnwrap(SimulatorElement.pick(from: rotated, at: CGPoint(x: 340, y: 810), interface: interface))
        XCTAssertEqual(picked.label, "New")
    }

    func testAScrollIndicatorLosesToTheListUnderIt() throws {
        let list: [String: Any] = ["elements": [element("Other", label: "Termio", 0, 0, 402, 874, children: [
            element("Table", label: "Projects", 0, 127, 402, 747, children: [
                element("_UIScrollViewScrollIndicator", label: "Vertical scroll bar", 369, 155, 30, 636),
            ]),
        ])]]
        let picked = try XCTUnwrap(SimulatorElement.pick(from: list, at: CGPoint(x: 380, y: 400), interface: interface))
        XCTAssertEqual(picked.type, "Table")
    }

    func testTraitsAndTheHintGoIntoTheLineAndNoneMeansNoTraits() throws {
        var back = element("Button", label: "Settings", 8, 54, 90, 44)
        back["traits"] = ["Button", "BackButton"]
        back["help"] = "Returns to Settings."
        var title = element("StaticText", label: "StandBy", 0, 100, 402, 40)
        title["traits"] = ["None"]
        let document: [String: Any] = ["elements": [back, title]]
        let picked = try XCTUnwrap(SimulatorElement.pick(from: document, at: CGPoint(x: 20, y: 60), interface: interface))
        XCTAssertEqual(picked.summary,
                       "Button \"Settings\" @ 8,54 90x44 traits: Button, BackButton hint: \"Returns to Settings.\"")
        let plain = try XCTUnwrap(SimulatorElement.pick(from: document, at: CGPoint(x: 200, y: 120), interface: interface))
        XCTAssertEqual(plain.traits, [])
        XCTAssertNil(plain.hint)
    }

    func testAnEmptyReadPicksNothing() {
        XCTAssertNil(SimulatorElement.pick(from: ["elements": []], at: .zero, interface: interface))
    }
}
