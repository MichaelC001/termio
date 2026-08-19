import XCTest
@testable import termio

/// A project whose checkout is on another machine.
///
/// The identity question is the one worth pinning: a box commonly answers to a
/// LAN name, a WAN name, and a tailnet name, so matching a checkout by the alias
/// it was reached through would open a second row for the same directory the day
/// the user changes networks.
@MainActor
final class RemoteProjectTests: XCTestCase {
    private func remote(_ path: String, alias: String, device: String? = nil) -> Project {
        var project = Project(
            workspaceID: UUID(), name: "api", path: path, branch: "—", sessions: [])
        project.deviceAlias = alias
        project.deviceID = device
        project.remoteCheckouts[device ?? alias] = path
        return project
    }

    func testSameDirectoryOnTheSameDeviceIsTheSameCheckout() {
        let project = remote("/srv/api", alias: "vps-lan", device: "device-a")

        XCTAssertTrue(project.isCheckout(at: "/srv/api", on: "vps-lan", device: "device-a"))
        XCTAssertTrue(project.isCheckout(at: "/srv/api", on: "vps-tailnet", device: "device-a"),
                      "one machine reached by a second alias is still one checkout")
        XCTAssertFalse(project.isCheckout(at: "/srv/web", on: "vps-lan", device: "device-a"),
                       "a different directory on the same machine is a different checkout")
        XCTAssertFalse(project.isCheckout(at: "/srv/api", on: "other", device: "device-b"))
    }

    /// Until a handshake resolves a `host_id` the alias is all there is — the same
    /// bootstrap/stable split `KnownDevice` carries.
    func testAliasMatchesUntilADeviceResolvesIt() {
        let project = remote("/srv/api", alias: "vps-lan")

        XCTAssertTrue(project.isCheckout(at: "/srv/api", on: "vps-lan", device: nil))
        XCTAssertTrue(project.isCheckout(at: "/srv/api", on: "vps-lan", device: "device-a"),
                      "a device this row hasn’t learned yet can’t disprove the alias")
        XCTAssertFalse(project.isCheckout(at: "/srv/api", on: "vps-wan", device: nil))
    }

    /// A folder on this Mac is never a remote checkout, however the paths line up —
    /// the local project row and a same-named directory on a VPS are two places.
    func testALocalProjectIsNeverARemoteCheckout() {
        let local = Project(
            workspaceID: UUID(), name: "api", path: "/srv/api", branch: "main", sessions: [])

        XCTAssertFalse(local.isOnAnotherDevice)
        XCTAssertNil(local.device)
        XCTAssertFalse(local.isCheckout(at: "/srv/api", on: "vps-lan", device: "device-a"))
    }

    /// The checkout a remote terminal opens in resolves through the device key when
    /// one is known and the alias key until then, so the row works before and after
    /// the machine identifies itself.
    func testTheSeededCheckoutResolvesBothWays() {
        let known = remote("/srv/api", alias: "vps-lan", device: "device-a")
        XCTAssertEqual(known.remoteCheckout(device: "device-a", alias: "vps-lan"), "/srv/api")

        let unresolved = remote("/srv/api", alias: "vps-lan")
        XCTAssertEqual(unresolved.remoteCheckout(device: nil, alias: "vps-lan"), "/srv/api")
        XCTAssertEqual(unresolved.remoteCheckout(device: "device-a", alias: "vps-lan"), "/srv/api",
                       "a device key that isn’t recorded yet falls back to the alias")
    }

    /// The device fields survive a round trip, and a project written before them
    /// still decodes as a folder on this Mac.
    func testDeviceSurvivesEncodingAndOlderStateFilesStayLocal() throws {
        let project = remote("/srv/api", alias: "vps-lan", device: "device-a")
        let decoded = try JSONDecoder().decode(
            Project.self, from: try JSONEncoder().encode(project))

        XCTAssertEqual(decoded.deviceAlias, "vps-lan")
        XCTAssertEqual(decoded.deviceID, "device-a")
        XCTAssertTrue(decoded.isOnAnotherDevice)

        let older = """
        {"id":"\(UUID().uuidString)","name":"api","path":"/Users/me/api",
         "branch":"main","sessions":[]}
        """
        let legacy = try JSONDecoder().decode(Project.self, from: Data(older.utf8))
        XCTAssertFalse(legacy.isOnAnotherDevice)
    }
}
