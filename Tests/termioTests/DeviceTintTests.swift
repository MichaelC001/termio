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

    /// The case that shipped wrong: a plain `ssh` shell and a durable termiod
    /// session on the *same* box, sitting next to each other in one section.
    ///
    /// An `ssh` terminal never handshakes with a daemon, so it carries no
    /// `deviceID` of its own. Hashing the session alone gave it the alias while
    /// its neighbour hashed the `host_id`, and the two rows came out different
    /// colours — a cue that actively lies about how many machines are in play.
    /// `KnownDevice.running` resolves the alias first, which is what makes them
    /// one mark.
    func testAnSSHShellAndATermiodSessionOnOneBoxShareAMark() throws {
        var ssh = Session(title: "SSH Shell", agent: .terminal)
        ssh.sshHost = "ukvps"
        var durable = Session(title: "Terminal 1", agent: .terminal)
        durable.termiodRemoteHost = "ukvps"
        durable.deviceID = "h_2dd9"
        let registry: (String) -> String? = { $0 == "ukvps" ? "h_2dd9" : nil }

        let sshDevice = KnownDevice.running(ssh, resolvingAlias: registry)
        let durableDevice = KnownDevice.running(durable, resolvingAlias: registry)

        XCTAssertEqual(sshDevice?.deviceID, "h_2dd9", "the alias resolves to the machine")
        XCTAssertEqual(DeviceTint.color(for: try XCTUnwrap(sshDevice), chrome: nil),
                       DeviceTint.color(for: try XCTUnwrap(durableDevice), chrome: nil))
    }

    /// A session on this Mac has no machine to mark.
    func testALocalSessionHasNoDevice() {
        XCTAssertNil(KnownDevice.running(Session(title: "Terminal 1"), resolvingAlias: { _ in nil }))
    }

    /// Before any handshake the alias is all there is, and the mark still has to
    /// resolve — it just may change once, when the machine finally answers.
    func testAnUnreachedAliasStillCarriesAMark() {
        var session = Session(title: "Terminal 1", agent: .terminal)
        session.termiodRemoteHost = "newbox"

        let device = KnownDevice.running(session, resolvingAlias: { _ in nil })

        XCTAssertEqual(device?.alias, "newbox")
        XCTAssertNil(device?.deviceID)
    }

    /// With no terminal theme selected there is no palette to borrow from; the
    /// fallback must still answer rather than trap on an empty collection.
    func testAnswersWithNoThemeSelected() {
        let device = KnownDevice(alias: "ukvps", deviceID: nil)
        XCTAssertEqual(DeviceTint.color(for: device, chrome: nil),
                       DeviceTint.color(for: device, chrome: nil))
    }
}
