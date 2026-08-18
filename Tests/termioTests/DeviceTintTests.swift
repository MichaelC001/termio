import SwiftUI
import XCTest
@testable import termio

/// The mark a device carries in the sidebar footer (`DeviceTint`).
///
/// The invariant worth pinning is the one the whole device vocabulary rests on:
/// a mark follows the *machine*, not the road taken to it. A tint keyed by alias
/// would give one box three different colors as the user moves between a LAN
/// name, a WAN name, and a tailnet name — which is worse than no mark at all,
/// because the cue would then be actively misleading.
@MainActor
final class DeviceTintTests: XCTestCase {
    /// Two aliases that resolved to one `host_id` are one machine, so they carry
    /// one mark.
    func testOneDeviceReachedByTwoAliasesKeepsOneMark() {
        let lan = KnownDevice(alias: "vps-lan", deviceID: "device-a")
        let tailnet = KnownDevice(alias: "vps-tailnet", deviceID: "device-a")

        XCTAssertEqual(DeviceTint.color(for: lan, chrome: nil),
                       DeviceTint.color(for: tailnet, chrome: nil))
    }

    /// This Mac is the machine you are on when you are not thinking about
    /// machines: it stays unhued, so every colored dot means "somewhere else".
    func testThisMacIsUnhued() {
        XCTAssertEqual(DeviceTint.color(for: .thisMac, chrome: nil), Color.secondary)
        XCTAssertNotEqual(DeviceTint.color(for: KnownDevice(alias: "ukvps", deviceID: nil),
                                           chrome: nil),
                          Color.secondary)
    }

    /// With no terminal theme selected there is no palette to borrow from; the
    /// fallback must still answer rather than trap on an empty collection.
    func testAnswersWithNoThemeSelected() {
        let device = KnownDevice(alias: "ukvps", deviceID: nil)
        XCTAssertEqual(DeviceTint.color(for: device, chrome: nil),
                       DeviceTint.color(for: device, chrome: nil))
    }
}
