import XCTest
import TermioShared
@testable import termio

/// A host's view on the Mac: the projects registered on a box show as rows in
/// that machine's workspace, and a session the box placed in a project is filed
/// there instead of by its cwd.
@MainActor
final class TermiodHostViewTests: XCTestCase {
    private func makeStore(
        workspaces: [Workspace], projects: [Project] = []
    ) -> TermioStore {
        let defaults = UserDefaults(suiteName: "host-view-\(UUID().uuidString)")
            ?? UserDefaults.standard
        return TermioStore(workspaces: workspaces, projects: projects,
                           settings: AppSettings(defaults: defaults))
    }

    private func decode<Value: Decodable>(_ type: Value.Type, _ json: String) throws -> Value {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: Data(json.utf8))
    }

    /// The shape termiod's serde writes: `pinned` left out when false, a node
    /// tagged by its case, a pane's kind flattened into it.
    private let viewJSON = """
    {"revision": 7,
     "projects": [{"id": "p_app", "path": "/home/me/app", "label": "app",
       "groups": [{"id": "g1", "focused": "x1",
         "root": {"split": {"direction": "right", "ratio": 0.5,
           "before": {"pane": {"id": "x1", "kind": "terminal", "session": "s_one"}},
           "after": {"pane": {"id": "x2", "kind": "terminal", "session": "s_two"}}}}}]}],
     "loose": [{"id": "g2", "focused": "x3",
       "root": {"pane": {"id": "x3", "kind": "terminal", "session": "s_loose"}}}]}
    """

    func testDecodesTheViewTermiodWrites() throws {
        let view = try decode(Termiod.HostView.self, viewJSON)

        XCTAssertEqual(view.revision, 7)
        XCTAssertEqual(view.projects.map(\.path), ["/home/me/app"])
        XCTAssertFalse(view.projects[0].pinned)
        XCTAssertEqual(view.projects[0].sessions, ["s_one", "s_two"])
        XCTAssertEqual(view.projectBySession["s_two"]?.id, "p_app")
        XCTAssertNil(view.projectBySession["s_loose"], "a loose group is in no project")
    }

    /// A pane of a kind this build does not know still decodes, with no session.
    func testAPaneOfAnUnknownKindDecodes() throws {
        let node = try decode(
            Termiod.HostView.Node.self,
            #"{"pane": {"id": "x9", "kind": "files", "root": "/home/me/app"}}"#)

        XCTAssertEqual(node.sessions, [])
    }

    /// A node of a kind a newer host added must not fail the whole view.
    func testANodeOfAnUnknownKindDecodes() throws {
        let node = try decode(Termiod.HostView.Node.self, #"{"stack": {"panes": []}}"#)

        XCTAssertEqual(node, .unknown)
    }

    /// Host paths compare as text. This Mac's filesystem knows nothing of the
    /// other machine's symlinks, so `/private` is never stripped.
    func testHostPathsCompareAsText() {
        XCTAssertEqual(TermioStore.hostPathKey("/home//me/./app/../app/"), "/home/me/app")
        XCTAssertEqual(TermioStore.hostPathKey("/private/var/x"), "/private/var/x")
    }

    func testAHostProjectGetsARowInItsMachinesWorkspace() throws {
        let box = Workspace(name: "vps", deviceAlias: "vps")
        let store = makeStore(workspaces: [Workspace(name: "Sessions"), box])
        let view = try decode(Termiod.HostView.self, viewJSON)
        let device = KnownDevice(alias: "vps", deviceID: nil)

        store.applyHostView(view, from: device, route: device.route)
        store.applyHostView(view, from: device, route: device.route)

        XCTAssertEqual(store.projects.count, 1, "a second answer adds nothing")
        XCTAssertEqual(store.projects[0].path, "/home/me/app")
        XCTAssertEqual(store.projects[0].name, "app")
        XCTAssertEqual(store.projects[0].workspaceID, box.id)
    }

    /// A view read before a removal landed still lists the project. Neither the
    /// removal in flight nor a view older than its revision brings the row back.
    func testARemovedProjectsRowDoesNotComeBackFromAnOlderView() throws {
        let box = Workspace(name: "vps", deviceAlias: "vps")
        let store = makeStore(workspaces: [box])
        let view = try decode(Termiod.HostView.self, viewJSON)
        let device = KnownDevice(alias: "vps", deviceID: nil)

        store.hostProjectsRemoving["vps"] = ["/home/me/app"]
        store.applyHostView(view, from: device, route: device.route)
        XCTAssertTrue(store.projects.isEmpty, "the removal is still in flight")

        store.hostProjectsRemoving["vps"] = []
        store.hostViewFloors["vps"] = 8
        store.applyHostView(view, from: device, route: device.route)
        XCTAssertTrue(store.projects.isEmpty, "revision 7 predates the removal")
    }

    /// On this Mac the app still authors the tree, so the local host's view adds
    /// no rows.
    func testThisMacsViewAddsNoRows() throws {
        let store = makeStore(workspaces: [Workspace(name: "Sessions")])
        let view = try decode(Termiod.HostView.self, viewJSON)

        store.applyHostView(view, from: .thisMac, route: .local)

        XCTAssertTrue(store.projects.isEmpty)
    }

    /// A project here that was cloned to the box at that path already is the row
    /// for the box's project.
    func testACloneToTheBoxIsTheRowForItsProject() throws {
        let home = Workspace(name: "Sessions")
        var clone = Project(workspaceID: home.id, name: "app", path: "/Users/me/app",
                            branch: "main", sessions: [])
        clone.remoteCheckouts = ["vps": "/home/me/app/"]
        let store = makeStore(workspaces: [home], projects: [clone])
        let view = try decode(Termiod.HostView.self, viewJSON)
        let device = KnownDevice(alias: "vps", deviceID: nil)

        store.applyHostView(view, from: device, route: device.route)

        XCTAssertEqual(store.projects.map(\.id), [clone.id])
    }

    /// The host's placement wins over the cwd: the session runs in `/tmp`, and
    /// the host placed its pane in the project.
    func testAnAdoptedSessionLandsWhereTheHostPlacedIt() throws {
        let box = Workspace(name: "vps", deviceAlias: "vps")
        let store = makeStore(workspaces: [box])
        let view = try decode(Termiod.HostView.self, viewJSON)
        let device = KnownDevice(alias: "vps", deviceID: nil)
        store.applyHostView(view, from: device, route: device.route)
        let information = try decode(
            Termiod.SessionInformation.self,
            #"{"id": "s_one", "name": "build", "cwd": "/tmp"}"#)

        store.adoptDeviceSession(information, on: device)

        XCTAssertEqual(store.projects[0].sessions.map(\.termiodSessionName), ["build"])
        XCTAssertTrue(store.workspaces[0].terminals.isEmpty)
    }

    func testAHostProjectIsRemovedWhenOnlyTheClosedSessionsAreLiveInIt() throws {
        let view = try decode(Termiod.HostView.self, viewJSON)

        XCTAssertEqual(
            TermioStore.hostProjectRemoval(
                at: "/home/me/./app/", in: view, live: ["s_one", "s_loose"],
                closing: ["s_one"]),
            .remove("p_app"),
            "s_two is placed there but is not live")
    }

    /// The host kills every live session in the project, so a project that
    /// holds a session this row did not have stays on the host.
    func testAHostProjectStaysWhileAnotherLiveSessionIsPlacedInIt() throws {
        let view = try decode(Termiod.HostView.self, viewJSON)

        XCTAssertEqual(
            TermioStore.hostProjectRemoval(
                at: "/home/me/app", in: view, live: ["s_one", "s_two"], closing: ["s_one"]),
            .others("p_app", ["s_two"]))
    }

    func testNoHostProjectAtThePathRemovesNothing() throws {
        let view = try decode(Termiod.HostView.self, viewJSON)

        XCTAssertEqual(
            TermioStore.hostProjectRemoval(at: "/home/me/other", in: view, live: [], closing: []),
            .none)
    }
}

/// The same against a real daemon: the host places a session it starts inside a
/// project in that project, the Mac reads both in one connection, and removing
/// the project ends the session.
///
/// Opt-in on the same terms as `TermiodWireOrderIntegrationTests`.
final class TermiodHostViewIntegrationTests: XCTestCase {
    private var daemon: Process?
    private var socketDirectory: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let binary = ProcessInfo.processInfo.environment["TERMIO_TERMIOD_TEST_BIN"] ?? ""
        try XCTSkipIf(binary.isEmpty, "set TERMIO_TERMIOD_TEST_BIN to run this")

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hv-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketDirectory = directory
        let socket = directory.appendingPathComponent("termiod.sock").path
        XCTAssertLessThan(socket.utf8.count, 104, "socket path must fit sun_path")
        setenv("TERMIOD_SOCK", socket, 1)

        let serve = Process()
        serve.executableURL = URL(fileURLWithPath: binary)
        serve.arguments = ["serve"]
        serve.environment = ProcessInfo.processInfo.environment.merging(
            ["TERMIOD_SOCK": socket]) { _, new in new }
        serve.standardOutput = FileHandle.nullDevice
        serve.standardError = FileHandle.nullDevice
        try serve.run()
        daemon = serve

        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: socket), Date() < deadline {
            usleep(50_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket), "daemon never bound")
    }

    override func tearDownWithError() throws {
        daemon?.terminate()
        daemon?.waitUntilExit()
        if let socketDirectory {
            try? FileManager.default.removeItem(at: socketDirectory)
        }
        unsetenv("TERMIOD_SOCK")
        try super.tearDownWithError()
    }

    /// Sends one raw control op and returns the first reply whose `op` is
    /// `expected`. The Mac has no verb for these yet, so the test speaks JSON.
    private func request(_ operation: [String: Any], expecting expected: String) throws -> [String: Any] {
        try Termiod.withControlChannel(route: .local, caps: [Termiod.viewCapability]) { transport, handshake in
            XCTAssertTrue(handshake.capabilities.contains(Termiod.viewCapability))
            try Termiod.writeFrame(
                transport.writeDescriptor, kind: .control,
                payload: JSONSerialization.data(withJSONObject: operation))
            while true {
                let frame = try Termiod.readFrame(transport.readDescriptor)
                guard frame.kind == .control,
                      let reply = try JSONSerialization.jsonObject(with: frame.payload)
                        as? [String: Any]
                else { continue }
                if reply["op"] as? String == expected { return reply }
                if reply["op"] as? String == "error" {
                    throw TermiodClientError.requestFailed("\(reply)")
                }
            }
        }
    }

    func testTheHostPlacesASessionInItsProjectAndRemovingTheProjectEndsIt() throws {
        let checkout = try XCTUnwrap(socketDirectory).appendingPathComponent("app")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let added = try request(
            ["op": "project_add", "path": checkout.path, "seq": 1], expecting: "project_added")
        let project = try XCTUnwrap(added["project"] as? String)
        let created = try request(
            ["op": "create", "cwd": checkout.path, "argv": ["/bin/sleep", "30"], "seq": 1],
            expecting: "created")
        let session = try XCTUnwrap(created["id"] as? String)

        let (roster, view) = try Termiod.rosterAndView(route: .local)
        let hostView = try XCTUnwrap(view, "a host with the view capability sends its view")
        XCTAssertEqual(hostView.projectBySession[session]?.id, project)
        let live = Set(roster.sessions.filter(\.alive).map(\.id))
        XCTAssertTrue(live.contains(session))
        // The host's path is canonical: `/private/var` on this Mac.
        let resolved = try XCTUnwrap(realpath(checkout.path, nil))
        let canonical = String(cString: resolved)
        free(resolved)

        // A removal that agreed to end only other sessions is refused on the
        // host, and the session keeps running.
        XCTAssertThrowsError(try Termiod.removeHostProject(route: .local, only: ["s_other"]) { _, _ in
            project
        })
        let (still, _) = try Termiod.rosterAndView(route: .local)
        XCTAssertTrue(still.sessions.contains { $0.id == session && $0.alive })

        let revision = try Termiod.removeHostProject(route: .local, only: [session]) {
            sessions, view in
            let live = Set(sessions.sessions.filter(\.alive).map(\.id))
            guard case .remove(let id) = TermioStore.hostProjectRemoval(
                at: canonical, in: view, live: live, closing: [session])
            else { return nil }
            return id
        }
        XCTAssertNotNil(revision)

        let (after, afterView) = try Termiod.rosterAndView(route: .local)
        XCTAssertEqual(afterView?.projects.map(\.id), [])
        XCTAssertFalse(after.sessions.contains { $0.id == session && $0.alive })
    }
}
