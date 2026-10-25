import AppKit
import XCTest
@testable import termio

/// The pane answers Simulator.app's shortcuts while its screen has focus, from
/// one table that also labels the "…" menu — so a menu row and its key can never
/// disagree. These pin that a real key event finds its command, arrows included,
/// whose events carry function-key flags a plain letter's do not.
final class SimulatorCommandTests: XCTestCase {
    private func key(_ characters: String, _ flags: NSEvent.ModifierFlags) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: 0)
    }

    private func arrow(_ key: Int) -> String {
        UnicodeScalar(key).map { String(Character($0)) } ?? ""
    }

    func testLettersWithModifiersFindTheirCommand() throws {
        XCTAssertEqual(SimulatorCommand.matching(try XCTUnwrap(key("h", [.command, .shift]))), .home)
        XCTAssertEqual(SimulatorCommand.matching(try XCTUnwrap(key("H", [.command, .shift]))), .home)
        XCTAssertEqual(SimulatorCommand.matching(try XCTUnwrap(key("l", [.command]))), .lock)
        XCTAssertEqual(SimulatorCommand.matching(try XCTUnwrap(key("z", [.command, .control]))), .shake)
    }

    func testArrowsFindTheirCommandDespiteFunctionKeyFlags() throws {
        let flags: NSEvent.ModifierFlags = [.command, .function, .numericPad]
        XCTAssertEqual(SimulatorCommand.matching(try XCTUnwrap(key(arrow(NSRightArrowFunctionKey), flags))), .rotateRight)
        XCTAssertEqual(SimulatorCommand.matching(try XCTUnwrap(key(arrow(NSLeftArrowFunctionKey), [.command]))), .rotateLeft)
        XCTAssertEqual(SimulatorCommand.matching(try XCTUnwrap(key(arrow(NSUpArrowFunctionKey), flags))), .volumeUp)
    }

    func testAPlainKeyIsTyping() throws {
        XCTAssertNil(SimulatorCommand.matching(try XCTUnwrap(key("l", []))))
        XCTAssertNil(SimulatorCommand.matching(try XCTUnwrap(key("h", [.command]))))
    }
}
