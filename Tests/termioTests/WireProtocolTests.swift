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

    /// The whole point: one session the phone can't read costs that row, not the
    /// tree. Before lossy decoding this returned nil and the phone showed an
    /// empty app.
    func testRosterDropsOnlyTheUnreadableSession() throws {
        let json = """
        {"t":"roster","projects":[{"id":"p1","name":"termio","path":"/tmp/termio","sessions":[\
        {"id":"s1","title":"Good","agent":"claude","status":"idle"},\
        {"id":"s2","title":"Missing agent and status"},\
        {"id":"s3","title":"Also good","agent":"codex","status":"working"}]}]}
        """

        let decoded = try XCTUnwrap(CompanionRoster.decode(json))

        XCTAssertEqual(decoded.projects.count, 1)
        XCTAssertEqual(decoded.projects.first?.sessions.map(\.id), ["s1", "s3"])
    }

    func testRosterDropsOnlyTheUnreadableProject() throws {
        let json = """
        {"t":"roster","projects":[\
        {"id":"p1","name":"termio","path":"/tmp/termio","sessions":[]},\
        {"name":"no id","path":"/tmp/broken","sessions":[]},\
        {"id":"p3","name":"other","path":"/tmp/other","sessions":[]}]}
        """

        let decoded = try XCTUnwrap(CompanionRoster.decode(json))

        XCTAssertEqual(decoded.projects.map(\.id), ["p1", "p3"])
    }

    /// A session from a newer Mac carrying fields this build never heard of
    /// still decodes — unknown keys are ignored, not fatal.
    func testRosterKeepsSessionWithUnknownFields() throws {
        let json = """
        {"t":"roster","projects":[{"id":"p1","name":"termio","path":"/tmp/termio","sessions":[\
        {"id":"s1","title":"Good","agent":"claude","status":"idle","somethingNewer":{"a":1}}]}]}
        """

        let decoded = try XCTUnwrap(CompanionRoster.decode(json))

        XCTAssertEqual(decoded.projects.first?.sessions.map(\.id), ["s1"])
    }

    /// An unknown tag has to arrive as a value, not as nil: the drop is only
    /// loggable if the receiver is handed something.
    func testUnknownControlTypeDecodesAsUnsupported() {
        XCTAssertEqual(
            CompanionControl.decode(#"{"t":"somethingFromANewerPhone","x":1}"#),
            .unsupported(type: "somethingFromANewerPhone")
        )
    }

    func testMalformedControlFrameStillDecodesToNil() {
        XCTAssertNil(CompanionControl.decode("not json at all"))
    }
}
