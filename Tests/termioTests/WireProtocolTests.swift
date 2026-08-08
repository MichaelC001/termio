import TermioShared
import XCTest

final class WireProtocolTests: XCTestCase {
    func testAuthRoundTripCarriesCurrentWireVersion() {
        let auth = CompanionControl.auth(token: "pairing-token", wire: Wire.current)

        XCTAssertEqual(CompanionControl.decode(auth.encoded()), auth)
    }

    func testAuthWithoutWireDecodesAsLegacy() {
        XCTAssertEqual(
            CompanionControl.decode(#"{"t":"auth","token":"pairing-token"}"#),
            .auth(token: "pairing-token", wire: Wire.legacy)
        )
    }

    func testRosterRoundTripCarriesCurrentWireVersion() throws {
        let roster = CompanionRoster(projects: [])

        let decoded = try XCTUnwrap(CompanionRoster.decode(roster.encodedJSON()))
        XCTAssertEqual(decoded, roster)
        XCTAssertEqual(decoded.wire, Wire.current)
    }

    func testRosterWithoutWireDecodesAsLegacy() throws {
        let decoded = try XCTUnwrap(
            CompanionRoster.decode(#"{"t":"roster","projects":[]}"#)
        )

        XCTAssertEqual(decoded.wire, Wire.legacy)
    }
}
