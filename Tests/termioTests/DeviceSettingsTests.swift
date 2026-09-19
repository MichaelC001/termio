import XCTest
@testable import termio

/// Which machine a setting means, and how that survives a round trip to disk.
///
/// These are the two rules the RFC's storage split rests on: an authored value is
/// keyed by machine identity rather than by the road taken to it, and a probe
/// nobody could run reads as *unknown* rather than as *missing*.
final class DeviceSettingsTests: XCTestCase {

    // MARK: Identity

    func testOneMachineReachedTwoWaysKeepsOneBlob() {
        // The same box behind a LAN name and a WAN name. Once a handshake has
        // revealed the `host_id`, both must file under it — otherwise a command
        // path typed over the tailnet is invisible when reached over the WAN.
        let lan = KnownDevice(alias: "box.local", deviceID: "h_3f0a")
        let wan = KnownDevice(alias: "box.example.com", deviceID: "h_3f0a")
        XCTAssertEqual(lan.settingsKey, wan.settingsKey)
    }

    func testAnUnhandshakenMachineFallsBackToItsAlias() {
        // Before the first handshake there is no `host_id`, and the alias is the
        // only name there is. It must still be storable, or a path typed on a box
        // Termio has never opened would be dropped.
        XCTAssertEqual(KnownDevice(alias: "vps", deviceID: nil).settingsKey, "vps")
    }

    func testThisMacIsNamedRatherThanEmpty() {
        // A JSON object key a human reads and hand-edits; `"": {…}` is neither.
        XCTAssertEqual(KnownDevice.thisMac.settingsKey, "local")
    }

    // MARK: Storage

    func testAuthoredValuesSurviveTheRoundTripToJSON() {
        var section = DeviceSettingsSection()
        section["h_3f0a"] = DeviceAuthoredSettings(agentCommands: ["claudeCode": "/usr/bin/claude"])
        section["local"] = DeviceAuthoredSettings(agentCommands: ["codex": "codex"])

        let restored = DeviceSettingsSection(jsonObject: section.jsonObject)
        XCTAssertEqual(restored, section)
        XCTAssertEqual(restored["h_3f0a"].agentCommands?["claudeCode"], "/usr/bin/claude")
    }

    func testAMachineWithNothingLeftDropsOutOfTheFile() {
        // The file's whole premise is that it holds only what the user set, so
        // clearing the last value on a machine must leave no trace of it — not an
        // empty object that grows the file forever.
        var section = DeviceSettingsSection()
        section["vps"] = DeviceAuthoredSettings(agentCommands: ["codex": "codex"])
        section["vps"] = DeviceAuthoredSettings(agentCommands: [:])

        XCTAssertTrue(section.byDevice.isEmpty)
        XCTAssertNil(section.jsonObject, "an empty section writes no key at all")
    }

    func testAnAbsentSectionIsEmptyRatherThanAFailure() {
        // A settings.json written before this feature existed has no `devices`
        // key, and that is the ordinary case, not a parse error.
        XCTAssertTrue(DeviceSettingsSection(jsonObject: nil).byDevice.isEmpty)
    }

    // MARK: Readiness

    func testAnUnreachableMachineReportsUnknownNotMissing() {
        // The rule the whole third state exists for: a `(!)` meaning "we could not
        // reach the box" sends the user to reinstall something already installed.
        let state = DeviceDiscoveredState(
            checkedAt: Date(timeIntervalSince1970: 0), reachable: false,
            agents: [AgentPreset.claudeCode.rawValue: AgentReadiness.available.rawValue])
        XCTAssertEqual(state.readiness(for: .claudeCode), .unknown)
    }

    func testAnAgentTheProbeNeverAskedAboutIsUnknown() {
        let state = DeviceDiscoveredState(
            checkedAt: Date(timeIntervalSince1970: 0), reachable: true, agents: [:])
        XCTAssertEqual(state.readiness(for: .claudeCode), .unknown)
    }

    func testAReachableMachineReportsWhatItAnswered() {
        let state = DeviceDiscoveredState(
            checkedAt: Date(timeIntervalSince1970: 0), reachable: true,
            agents: [AgentPreset.claudeCode.rawValue: AgentReadiness.missing.rawValue])
        XCTAssertEqual(state.readiness(for: .claudeCode), .missing)
    }

    // MARK: The cache is a cache

    func testTheDeviceFileRoundTripsAndIsDeletable() throws {
        let key = "test-\(UUID().uuidString)"
        let state = DeviceDiscoveredState(
            checkedAt: Date(timeIntervalSince1970: 1_700_000_000), reachable: true,
            termiodVersion: "0.42.0",
            agents: ["codex": AgentReadiness.available.rawValue],
            integrationVersion: "0.42.0+900")

        DeviceStateCache.save(state, for: key)
        XCTAssertEqual(DeviceStateCache.load(key), state)

        // Deleting it at any moment is safe by construction: the next read is
        // simply "we have not asked yet".
        DeviceStateCache.forget(key)
        XCTAssertNil(DeviceStateCache.load(key))
    }

    func testAnAliasWithAPathSeparatorCannotEscapeTheDirectory() {
        // An alias is whatever the user typed into ~/.ssh/config, and a `/` in one
        // would otherwise name a subdirectory — or somewhere else entirely.
        let url = DeviceStateCache.url(for: "../../etc/passwd")
        XCTAssertEqual(url.deletingLastPathComponent().path, DeviceStateCache.directory.path)
        XCTAssertFalse(url.lastPathComponent.contains("/"))
    }

    // MARK: What an install covered

    private func state(
        agents: [String: String], covered: [String]?, stamped: Bool = true
    ) -> DeviceDiscoveredState {
        DeviceDiscoveredState(
            checkedAt: Date(), reachable: true, agents: agents,
            integrationVersion: stamped ? AppInfo.buildStamp : nil,
            integrationAgents: covered)
    }

    func testAnAgentInstalledAfterSetupNeedsSetupAgain() {
        // Both halves write only for agents whose CLI is on the machine, so the
        // agent that arrived afterwards has no hooks and reports nothing. The
        // version stamp alone cannot see this — it is still this build's.
        let machine = state(
            agents: ["claudeCode": "available", "codex": "available"],
            covered: ["claudeCode"])
        XCTAssertEqual(machine.agentsOutsideIntegration, ["codex"])
        XCTAssertFalse(machine.carriesCurrentIntegration)
    }

    func testAnAgentThatWentMissingIsNotAReasonToSetUpAgain() {
        // The reverse of the case above: the install covered more than the
        // machine now has. Nothing is un-wired by an uninstall, and sending the
        // user back to setup for it would be the false alarm §D4 exists to stop.
        let machine = state(
            agents: ["claudeCode": "available", "codex": "missing"],
            covered: ["claudeCode", "codex"])
        XCTAssertEqual(machine.agentsOutsideIntegration, [])
        XCTAssertTrue(machine.carriesCurrentIntegration)
    }

    func testABuildThatRecordedNoListIsLeftAlone() {
        // A device file written before this was recorded. Reading `nil` as
        // "covered nothing" would put every machine in the roster back on "set
        // up" the moment this ships; the next app update moves the stamp anyway.
        let machine = state(agents: ["claudeCode": "available"], covered: nil)
        XCTAssertEqual(machine.agentsOutsideIntegration, [])
        XCTAssertTrue(machine.carriesCurrentIntegration)
    }

    func testTheCoveredListSurvivesTheRoundTripToJSON() {
        let machine = state(agents: ["claudeCode": "available"], covered: ["claudeCode"])
        let data = try? JSONEncoder().encode(machine)
        let read = data.flatMap { try? JSONDecoder().decode(DeviceDiscoveredState.self, from: $0) }
        XCTAssertEqual(read?.integrationAgents, ["claudeCode"])
    }
}
