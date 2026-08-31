@testable import TermioMobile
import TermioShared
import XCTest

/// Agent status reaches this phone as a **resource** — `status:`, with a cursor
/// — and not as a broadcast, so a screen that locked through three turns
/// resumes where it left off instead of rescanning.
///
/// The other half is the one status decision a viewer owns. The device reports
/// that a turn ended; whether that reads as a calm "ready for you" depends on
/// whether this person was looking, and the Mac answers from its selection
/// while this answers from the open session. Getting it wrong shows `done` on
/// the Mac and `idle` on the phone for one session at one moment, which is the
/// disagreement `source` / `turn_ended` exist to prevent.
///
/// The frames below are the daemon's own JSON (`termiod/src/protocol.rs`), run
/// through the real decode.
final class TermiodStatusResourceTests: XCTestCase {
    private func makeBackend() -> TermiodBackend {
        guard let url = URL(string: "ws://127.0.0.1:9/ws") else {
            fatalError("a literal URL that does not parse")
        }
        return TermiodBackend(endpoint: DeviceEndpoint(kind: .termiod, url: url), sessionID: nil)
    }

    private func event(_ json: String) throws -> Termiod.IncomingEvent {
        try Termiod.decodeEvent(Data(json.utf8))
    }

    private func statusChanged(
        seq: UInt64, session: String, status: String,
        source: String = "screen", turnEnded: Bool = false
    ) -> String {
        let ended = turnEnded ? "true" : "false"
        return "{\"ev\":\"status_changed\",\"resource\":\"status:\",\"seq\":\(seq),"
            + "\"session\":\"\(session)\",\"status\":\"\(status)\","
            + "\"source\":\"\(source)\",\"turn_ended\":\(ended),\"blocking\":false}"
    }

    /// The handshake, which is what lets a roster be published at all: the
    /// backend refuses to publish before the device names itself, because a
    /// workspace id that churned between pushes would reshuffle every list on
    /// screen.
    private func handshake(_ backend: TermiodBackend) throws {
        let payload = Data(
            ("{\"op\":\"hello_ok\",\"host_id\":\"h_1\",\"host\":\"vps\","
                + "\"client_id\":\"c_1\",\"proto\":1,\"caps\":[\"events\",\"resources\"],"
                + "\"home\":\"/root\"}").utf8)
        guard case .helloOk(let hello) = try Termiod.decodeControl(payload) else {
            return XCTFail("a hello_ok decoded as something else")
        }
        backend.handshakeLanded(hello)
    }

    /// Give the backend a roster, through the reply that really carries one — a
    /// status delta for a session the roster has never named is dropped, so
    /// without this the assertions below would pass on an empty backend and
    /// prove nothing.
    private func seedRoster(_ backend: TermiodBackend, sessions: [String]) throws {
        try handshake(backend)
        let rows = sessions.map { id in
            "{\"id\":\"\(id)\",\"name\":\"\(id)\",\"pid\":1,\"alive\":true,"
                + "\"cwd\":\"/srv/repo\",\"command\":\"claude\",\"status\":\"working\","
                + "\"agent_id\":\"claudeCode\",\"project\":\"/srv/repo\",\"clients\":0,"
                + "\"created_unix\":0,\"rows\":24,\"cols\":80}"
        }
        let payload = Data(
            "{\"op\":\"sessions\",\"sessions\":[\(rows.joined(separator: ","))],\"re\":1}".utf8)
        backend.receive(TermiodChannel.Reply(
            responseID: Termiod.responseID(of: payload),
            control: try Termiod.decodeControl(payload)))
    }

    /// The status the phone would actually draw for a session — read off the
    /// published roster, through the same mapping the lists render from, not
    /// off the backend's own bookkeeping.
    private func drawnStatus(_ backend: TermiodBackend, _ session: String) -> SessionStatus? {
        var seen: SessionStatus?
        backend.onRoster = { roster in
            seen = roster.projects
                .flatMap(\.sessions)
                .first { $0.rosterID == session }?
                .status
        }
        backend.forcePublishForTests()
        backend.onRoster = nil
        return seen
    }

    /// A session the roster has never named cannot be revised, but its batch
    /// still advances the cursor: a batch skipped here is a batch that must not
    /// be asked for again, or every reconnect replays it forever.
    func testAnUnknownSessionStillAdvancesTheCursor() throws {
        let backend = makeBackend()
        XCTAssertNil(backend.statusResumeCursor)

        backend.receive(try event(statusChanged(seq: 7, session: "s_1", status: "working")))

        XCTAssertEqual(backend.statusResumeCursor, 7)
    }

    /// The cursor only ever moves forward. A late duplicate must not walk it
    /// backwards into re-reading batches it has already applied.
    func testTheCursorNeverMovesBackwards() throws {
        let backend = makeBackend()

        backend.receive(try event(statusChanged(seq: 9, session: "s_1", status: "working")))
        backend.receive(try event(statusChanged(seq: 4, session: "s_1", status: "idle")))

        XCTAssertEqual(backend.statusResumeCursor, 9)
    }

    /// The daemon's `stalled` fields ride the same batches, so dropping the
    /// broadcast subscription costs nothing — and a batch carrying them is
    /// still an ordinary status batch.
    func testAStalledBatchDecodesAsAStatusBatch() throws {
        let decoded = try event(
            "{\"ev\":\"status_changed\",\"resource\":\"status:\",\"seq\":3,"
                + "\"session\":\"s_1\",\"status\":\"working\","
                + "\"stalled_working_seconds\":1260,\"stalled_transcript_lines_grown\":2}")
        guard case .statusChanged(let change) = decoded else {
            return XCTFail("a status_changed event decoded as something else")
        }
        XCTAssertEqual(change.seq, 3)
        XCTAssertEqual(change.stalledWorkingSeconds, 1260)
        XCTAssertEqual(change.stalledTranscriptLinesGrown, 2)
        XCTAssertEqual(change.report.status, "working", "a stall never moves the status")
    }

    /// A daemon that predates the fields says nothing about them, and every
    /// `needs_you` such a daemon sent was blocking — so absent reads as
    /// blocking, and the field can only ever narrow the claim.
    func testAnOlderDaemonsStatusStillDecodes() throws {
        let decoded = try event("{\"ev\":\"status\",\"session\":\"s_1\",\"status\":\"needs_you\"}")
        guard case .status(let report) = decoded else {
            return XCTFail("a status event decoded as something else")
        }
        XCTAssertNil(report.source)
        XCTAssertFalse(report.turnEnded)
        XCTAssertNil(report.blocking)
        XCTAssertFalse(report.isDerived, "no source means the only channel it had: hooks")
    }

    /// The seam itself: one derived turn end, two viewers, two right answers.
    func testADerivedTurnEndReadsDoneOffScreenAndIdleOnIt() throws {
        let ended = statusChanged(
            seq: 1, session: "s_1", status: "idle", source: "title", turnEnded: true)

        let elsewhere = makeBackend()
        try seedRoster(elsewhere, sessions: ["s_1", "s_2"])
        elsewhere.viewingSessionID = "s_2"
        elsewhere.receive(try event(ended))
        XCTAssertEqual(drawnStatus(elsewhere, "s_1"), .done,
                       "a turn that ended while you were elsewhere is ready for you")

        let watching = makeBackend()
        try seedRoster(watching, sessions: ["s_1"])
        watching.viewingSessionID = "s_1"
        watching.receive(try event(ended))
        XCTAssertEqual(drawnStatus(watching, "s_1"), .idle,
                       "you watched it end — there is nothing to catch up on")
    }

    /// Opening the session clears the mark, the way looking at the row does on
    /// the Mac. Without this the phone keeps a green dot on the screen the user
    /// is already reading.
    func testOpeningASessionClearsItsDoneMark() throws {
        let backend = makeBackend()
        try seedRoster(backend, sessions: ["s_1"])
        backend.receive(try event(statusChanged(
            seq: 1, session: "s_1", status: "idle", source: "screen", turnEnded: true)))
        XCTAssertEqual(drawnStatus(backend, "s_1"), .done)

        backend.viewingSessionID = "s_1"

        XCTAssertEqual(drawnStatus(backend, "s_1"), .idle)
    }

    /// A hook's own `done` is not the viewer's business: the agent said done, so
    /// it reads done on every client, looked at or not.
    func testAHookDoneIsNotTheViewersToReinterpret() throws {
        let backend = makeBackend()
        try seedRoster(backend, sessions: ["s_1"])
        backend.viewingSessionID = "s_1"

        backend.receive(try event(statusChanged(
            seq: 2, session: "s_1", status: "done", source: "hook", turnEnded: false)))

        XCTAssertEqual(drawnStatus(backend, "s_1"), .done,
                       "the agent said done; a viewer does not overrule that")
    }

    /// Only the turn end is the viewer's to interpret — a working status is not.
    func testAWorkingStatusIsUntouchedByFocus() throws {
        let backend = makeBackend()
        try seedRoster(backend, sessions: ["s_1"])
        backend.viewingSessionID = "s_1"

        backend.receive(try event(statusChanged(seq: 3, session: "s_1", status: "working")))

        XCTAssertEqual(drawnStatus(backend, "s_1"), .working)
    }
}
