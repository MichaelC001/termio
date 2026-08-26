@testable import TermioMobile
import XCTest

/// The paired-device list decodes with `try?` and returns `[]` on failure, so a
/// decode that stops working does not throw, log, or crash — it silently
/// unpairs every machine the user has, and the app looks like it was never set
/// up. That makes every field added to `PairedMac` a compatibility question,
/// and this the test that answers it.
final class PairedDeviceDecodingTests: XCTestCase {
    private func decode(_ json: String) throws -> [PairedMac] {
        try JSONDecoder().decode([PairedMac].self, from: Data(json.utf8))
    }

    /// A blob written before `kind` existed. It has to decode, and it has to
    /// decode as the companion Mac it is — a device pairing carries a token in
    /// a subprotocol and a `/ws` path, neither of which this entry has.
    func testABlobSavedBeforeKindExistedStillDecodes() throws {
        let macs = try decode("""
        [{"id":"mac_1","name":"Studio","address":"ws://studio.local:8787","token":"abc"}]
        """)
        XCTAssertEqual(macs.count, 1)
        XCTAssertEqual(macs.first?.kind, .companion)
        XCTAssertEqual(macs.first?.name, "Studio")
        XCTAssertNil(macs.first?.origin)
    }

    /// The oldest shape of all: no token either, from before pairing carried one.
    func testAnEntryWithNoTokenStillDecodes() throws {
        let macs = try decode(#"[{"id":"mac_1","name":"Studio","address":"ws://studio.local:8787"}]"#)
        XCTAssertEqual(macs.first?.kind, .companion)
        XCTAssertNil(macs.first?.token)
    }

    /// What this release writes has to survive a round trip, or the next launch
    /// is the one that unpairs everything.
    func testADeviceEntryRoundTrips() throws {
        let device = PairedMac(
            id: "h_1", name: "box", address: "ws://127.0.0.1:8790/ws",
            token: "secret", kind: .termiod, origin: "http://127.0.0.1:8790"
        )
        let data = try JSONEncoder().encode([device])
        XCTAssertEqual(try JSONDecoder().decode([PairedMac].self, from: data), [device])
    }

    /// The companion wire reads its token back off the URL; the Session Protocol
    /// puts it in the negotiated subprotocol, and a `?t=` on the Upgrade line is
    /// the proxy-log leak that placement exists to close.
    func testOnlyTheCompanionWirePutsItsTokenOnTheURL() {
        let mac = PairedMac(
            id: "mac_1", name: "Studio", address: "ws://studio.local:8787", token: "abc")
        XCTAssertEqual(mac.connectURL?.absoluteString, "ws://studio.local:8787?t=abc")

        let device = PairedMac(
            id: "h_1", name: "box", address: "ws://127.0.0.1:8790/ws",
            token: "secret", kind: .termiod, origin: "http://127.0.0.1:8790")
        XCTAssertEqual(device.connectURL?.absoluteString, "ws://127.0.0.1:8790/ws")
        XCTAssertEqual(device.endpoint?.token, "secret")
        XCTAssertEqual(device.endpoint?.origin, "http://127.0.0.1:8790")
    }
}

/// The invite is the only thing between a QR code and a saved pairing, and a
/// half-read one must refuse rather than pair against a guess.
final class DeviceInviteParsingTests: XCTestCase {
    func testAWholeInviteParses() throws {
        let invite = try XCTUnwrap(CompanionLink.parseDeviceInvite(
            "termio://device?url=http%3A%2F%2F127.0.0.1%3A8790%2F&token=abc&host_id=h_1&proto=1"
        ))
        XCTAssertEqual(invite.url.absoluteString, "ws://127.0.0.1:8790/ws")
        XCTAssertEqual(invite.token, "abc")
        XCTAssertEqual(invite.hostID, "h_1")
        XCTAssertEqual(invite.origin, "http://127.0.0.1:8790")
    }

    /// Behind a TLS terminator the listener is published under a path
    /// (Tailscale Serve's `--set-path=/termio`), which does not get rewritten —
    /// so `/ws` hangs off whatever the operator published.
    func testAPublishedPathKeepsItsPrefix() throws {
        let invite = try XCTUnwrap(CompanionLink.parseDeviceInvite(
            "termio://device?url=https%3A%2F%2Fbox.tailnet.ts.net%2Ftermio%2F&token=abc&host_id=h_1&proto=1"
        ))
        XCTAssertEqual(invite.url.absoluteString, "wss://box.tailnet.ts.net/termio/ws")
        XCTAssertEqual(invite.origin, "https://box.tailnet.ts.net")
    }

    func testAnInviteMissingAFieldIsRefused() {
        XCTAssertNil(CompanionLink.parseDeviceInvite(
            "termio://device?url=http%3A%2F%2F127.0.0.1%3A8790%2F&host_id=h_1"))
        XCTAssertNil(CompanionLink.parseDeviceInvite("termio://device?token=abc&host_id=h_1"))
    }

    /// A companion address is not an invite, and must fall through to the
    /// shipped path rather than be misread as one.
    func testACompanionAddressIsNotAnInvite() {
        XCTAssertNil(CompanionLink.parseDeviceInvite("ws://studio.local:8787/?t=abc"))
        XCTAssertNil(CompanionLink.parseDeviceInvite("studio.local"))
    }
}
