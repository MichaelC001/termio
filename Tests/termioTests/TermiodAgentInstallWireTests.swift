import Foundation
import TermioShared
import XCTest
@testable import termio

/// The `install_agents` reporter is spelled by the daemon's `Reporter` enum
/// (`termiod/src/agent/install.rs`, internally tagged on `kind`). The two
/// sides drifted once — the daemon renamed its variants and the app kept
/// sending the old names, and every hook install in that release failed with
/// "unknown variant" — so the wire spelling is pinned here.
final class TermiodAgentInstallWireTests: XCTestCase {
    private func reporterJSON(_ reporter: Termiod.AgentHookReporter) throws -> [String: Any] {
        let payload = try Termiod.installAgentsPayload(
            agents: nil, hooks: .install, skills: .install, reporter: reporter, hookVersion: "1")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        return try XCTUnwrap(object["reporter"] as? [String: Any])
    }

    func testThisMacIsSpelledTheDaemonsWay() throws {
        let reporter = try reporterJSON(.thisMac)
        XCTAssertEqual(reporter["kind"] as? String, "this_mac")
        XCTAssertEqual(reporter.count, 1, "the daemon resolves the command itself; nothing else travels")
    }

    func testADeviceIsSpelledTheDaemonsWay() throws {
        let reporter = try reporterJSON(.device)
        XCTAssertEqual(reporter["kind"] as? String, "device")
        XCTAssertEqual(reporter.count, 1)
    }
}
