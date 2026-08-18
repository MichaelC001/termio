import XCTest
@testable import termio

/// `TermioStore.adoptDevice` — the a-priori → a-posteriori transition. State is
/// authored against an SSH alias, because a machine's workspace has to exist
/// before anything has connected; the first `hello_ok` is the only moment that
/// alias becomes a machine. These tests pin what gets written down at that
/// moment, and just as importantly what does not.
@MainActor
final class TermiodDeviceAdoptionTests: XCTestCase {
    private func makeStore(
        workspaces: [Workspace] = [Workspace(name: "Sessions")], projects: [Project] = []
    ) -> TermioStore {
        let defaults = UserDefaults(suiteName: "adopt-\(UUID().uuidString)")
            ?? UserDefaults.standard
        return TermioStore(workspaces: workspaces, projects: projects,
                           settings: AppSettings(defaults: defaults))
    }

    private func device(_ id: String) -> TermiodDevice {
        TermiodDevice(id: id, daemonVersion: "termiod/0.1.0 linux-aarch64",
                      routes: [.ssh("vps")], lastSeen: Date())
    }

    private func remoteSession(_ title: String, host: String?) -> Session {
        var session = Session(title: title, agent: .terminal)
        session.termiodRemoteHost = host
        return session
    }

    private func deviceWorkspace(alias: String, sessions: [Session] = []) -> Workspace {
        Workspace(name: alias, terminals: sessions, deviceAlias: alias)
    }

    private func project(
        _ name: String, in workspace: Workspace, sessions: [Session] = []
    ) -> Project {
        Project(workspaceID: workspace.id, name: name, path: "/code/\(name)",
                branch: "main", sessions: sessions)
    }

    /// A checkout recorded before checkouts were device-keyed is promoted the
    /// first time its alias resolves. An old state file must keep working — and
    /// stop being old.
    func testPromotesALegacyAliasKeyedCheckout() {
        let home = Workspace(name: "Sessions")
        var checkout = project("termio", in: home)
        checkout.remoteCheckouts = ["vps": "/home/me/termio"]
        let store = makeStore(workspaces: [home], projects: [checkout])

        store.adoptDevice(device("h_aaaa"), forRoute: .ssh("vps"))

        XCTAssertEqual(store.projects[0].remoteCheckouts, ["h_aaaa": "/home/me/termio"])
    }

    /// The same repo cloned to one machine and reached by a second alias resolves
    /// to the one device-keyed entry — the case that keyed by alias would report
    /// as "not cloned yet" the day the user changes networks.
    func testASecondAliasForOneMachineFindsTheSameCheckout() {
        let home = Workspace(name: "Sessions")
        var checkout = project("termio", in: home)
        checkout.remoteCheckouts = ["vps-lan": "/home/me/termio"]
        let store = makeStore(workspaces: [home], projects: [checkout])

        store.adoptDevice(device("h_aaaa"), forRoute: .ssh("vps-lan"))
        store.adoptDevice(device("h_aaaa"), forRoute: .ssh("vps-wan"))

        XCTAssertEqual(
            store.projects[0].remoteCheckout(device: "h_aaaa", alias: "vps-wan"),
            "/home/me/termio"
        )
    }

    /// Adoption never invents a checkout: a project that was never cloned there
    /// still has none, and the "not cloned yet" path stays honest.
    func testAdoptionDoesNotInventACheckout() {
        let home = Workspace(name: "Sessions")
        let store = makeStore(workspaces: [home], projects: [project("termio", in: home)])

        store.adoptDevice(device("h_aaaa"), forRoute: .ssh("vps"))

        XCTAssertTrue(store.projects[0].remoteCheckouts.isEmpty)
    }

    /// A machine's fallback workspace records which machine its alias reached —
    /// and keeps being the alias's workspace. `deviceAlias` is demoted to a route,
    /// not removed: it is still how the workspace is matched before anything has
    /// connected.
    func testBackfillsAFallbackWorkspacesDeviceWithoutDisturbingItsAlias() {
        let store = makeStore(workspaces: [deviceWorkspace(alias: "vps")])

        store.adoptDevice(device("h_aaaa"), forRoute: .ssh("vps"))

        XCTAssertEqual(store.workspaces[0].deviceID, "h_aaaa")
        XCTAssertEqual(store.workspaces[0].deviceAlias, "vps",
                       "the alias stays the bootstrap identity")
        XCTAssertTrue(store.workspaces[0].isDeviceFallback)
    }

    /// Two aliases for one machine are recorded as one device but are **not**
    /// merged. Merging is specified in §9.5 of the device-architecture doc and
    /// deliberately not performed yet — it must not happen before the duplicate
    /// `host_id` case (a cloned VM) has an answer.
    func testDoesNotYetMergeTwoWorkspacesOnOneDevice() {
        let store = makeStore(workspaces: [
            deviceWorkspace(alias: "vps-lan"), deviceWorkspace(alias: "vps-wan"),
        ])

        store.adoptDevice(device("h_aaaa"), forRoute: .ssh("vps-lan"))
        store.adoptDevice(device("h_aaaa"), forRoute: .ssh("vps-wan"))

        XCTAssertEqual(store.workspaces.count, 2, "merging is a later step, not a side effect")
        XCTAssertEqual(store.workspaces.map(\.deviceID), ["h_aaaa", "h_aaaa"],
                       "but both know they are one machine")
    }

    /// A workspace for an alias that resolved elsewhere is left alone — adoption
    /// is scoped to the route that was actually travelled.
    func testLeavesOtherAliasesUntouched() {
        let store = makeStore(workspaces: [
            deviceWorkspace(alias: "vps"), deviceWorkspace(alias: "devbox"),
        ])

        store.adoptDevice(device("h_aaaa"), forRoute: .ssh("vps"))

        XCTAssertEqual(store.workspaces[0].deviceID, "h_aaaa")
        XCTAssertNil(store.workspaces[1].deviceID)
    }

    /// Sessions belong to a machine, not to the road taken to reach it.
    func testRecordsTheDeviceOnSessionsThatTookThatRoute() {
        let store = makeStore(workspaces: [
            deviceWorkspace(alias: "vps", sessions: [remoteSession("Terminal 1", host: "vps")]),
            deviceWorkspace(alias: "devbox",
                            sessions: [remoteSession("Terminal 1", host: "devbox")]),
        ])

        store.adoptDevice(device("h_aaaa"), forRoute: .ssh("vps"))

        XCTAssertEqual(store.workspaces[0].terminals[0].deviceID, "h_aaaa")
        XCTAssertNil(store.workspaces[1].terminals[0].deviceID)
    }

    /// This Mac is a device like any other: a local session's device is recorded
    /// exactly the same way, over the route that happens to be a Unix socket.
    func testLocalSessionsGetTheirDeviceToo() {
        let home = Workspace(name: "Sessions")
        let store = makeStore(
            workspaces: [home],
            projects: [project("termio", in: home,
                               sessions: [remoteSession("Terminal 1", host: nil)])])

        store.adoptDevice(device("h_mac"), forRoute: .local)

        XCTAssertEqual(store.projects[0].sessions[0].deviceID, "h_mac")
    }

    /// Re-adopting the same device changes nothing — every attach calls this.
    func testAdoptionIsIdempotent() {
        let home = Workspace(name: "Sessions")
        var checkout = project("termio", in: home,
                               sessions: [remoteSession("Terminal 1", host: "vps")])
        checkout.remoteCheckouts = ["vps": "/home/me/termio"]
        let store = makeStore(workspaces: [home], projects: [checkout])

        store.adoptDevice(device("h_aaaa"), forRoute: .ssh("vps"))
        let afterFirst = store.projects
        store.adoptDevice(device("h_aaaa"), forRoute: .ssh("vps"))

        XCTAssertEqual(store.projects, afterFirst)
    }

    /// Before anything has connected there is no device to key by, and the menu
    /// still has to answer. The legacy alias entry is what it answers from.
    func testCheckoutLookupFallsBackToTheAliasBeforeAnythingHasConnected() {
        var checkout = project("termio", in: Workspace(name: "Sessions"))
        checkout.remoteCheckouts = ["vps": "/home/me/termio"]

        XCTAssertEqual(checkout.remoteCheckout(device: nil, alias: "vps"), "/home/me/termio")
        XCTAssertNil(checkout.remoteCheckout(device: nil, alias: "devbox"))
    }

    /// A device-keyed entry wins over a stale alias entry for a different machine.
    func testDeviceKeyedEntryWinsOverTheAliasFallback() {
        var checkout = project("termio", in: Workspace(name: "Sessions"))
        checkout.remoteCheckouts = ["h_aaaa": "/srv/termio", "vps": "/home/me/termio"]

        XCTAssertEqual(checkout.remoteCheckout(device: "h_aaaa", alias: "vps"), "/srv/termio")
    }

    /// Workspace state survives a round trip through the state file, or the device
    /// would have to be re-learned on every launch.
    func testDeviceFieldsSurviveEncoding() throws {
        var workspace = deviceWorkspace(alias: "vps",
                                        sessions: [remoteSession("t", host: "vps")])
        workspace.deviceID = "h_aaaa"
        workspace.terminals[0].deviceID = "h_aaaa"

        let decoded = try JSONDecoder().decode(
            Workspace.self, from: try JSONEncoder().encode(workspace))

        XCTAssertEqual(decoded.deviceID, "h_aaaa")
        XCTAssertEqual(decoded.deviceAlias, "vps")
        XCTAssertEqual(decoded.terminals[0].deviceID, "h_aaaa")
    }

    /// A state file written before devices existed still loads, with the device
    /// simply unknown — that is the normal starting state, not a corrupt one.
    func testStateFilesWrittenBeforeDevicesStillDecode() throws {
        let json = Data("""
        {"id":"\(UUID().uuidString)","name":"vps","path":"~","branch":"—","kind":"host",
         "sshHost":"vps","remoteCheckouts":{"vps":"/home/me/termio"},"sessions":[]}
        """.utf8)

        let decoded = try JSONDecoder().decode(
            WorkspaceMigration.LegacyProject.self, from: json)

        XCTAssertNil(decoded.deviceID)
        XCTAssertEqual(decoded.sshHost, "vps")
        XCTAssertEqual(decoded.remoteCheckouts, ["vps": "/home/me/termio"])
    }
}
