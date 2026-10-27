import XCTest
import TermioShared
@testable import termio

/// Step 1b of `docs/design/20261025-termiod-owns-the-view.md`: the Mac seeds a
/// host's view from its own `state.json` once, then draws the sidebar from it.
/// A wrong import rearranges or drops rows, so these tests read a state file in
/// the shape the app really writes.
@MainActor
final class TermiodViewImportTests: XCTestCase {
    /// A state file in the shape this app writes: several workspaces on this
    /// Mac and one on a box, loose terminals and chats, a pinned project, a
    /// worktree session, and split groups inside a project and among loose
    /// terminals. Paths are placeholders the integration test points at real
    /// folders.
    static func stateJSON(alpha: String, beta: String, gone: String) -> String {
        """
        {
          "currentWorkspaceID": "A0000000-0000-0000-0000-000000000001",
          "selectedSessionID": "50000000-0000-0000-0000-000000000001",
          "workspaces": [
            {"id": "A0000000-0000-0000-0000-000000000001", "name": "Sessions",
             "isAutoCreated": false, "deviceID": "mac-1",
             "terminals": [
               {"id": "70000000-0000-0000-0000-000000000001", "title": "Terminal 1",
                "agent": "terminal", "createdAt": 814595618.88, "launched": true},
               {"id": "70000000-0000-0000-0000-000000000002", "title": "Terminal 2",
                "agent": "terminal", "createdAt": 814595619.88, "launched": true}
             ],
             "chats": [
               {"id": "71000000-0000-0000-0000-000000000001", "title": "Claude Code",
                "agent": "claudeCode", "createdAt": 814595620.88, "launched": true,
                "resumeID": "0b3c0f9e-1111-4222-8333-944455556666"}
             ]},
            {"id": "A0000000-0000-0000-0000-000000000002", "name": "vps",
             "isAutoCreated": true, "deviceAlias": "vps", "deviceID": "box-1",
             "terminals": [
               {"id": "72000000-0000-0000-0000-000000000001", "title": "Terminal 1",
                "agent": "terminal", "createdAt": 814595621.88,
                "termiodRemoteHost": "vps", "deviceID": "box-1"}
             ],
             "chats": []},
            {"id": "A0000000-0000-0000-0000-000000000003", "name": "Work",
             "isAutoCreated": false, "deviceID": "mac-1",
             "terminals": [], "chats": []}
          ],
          "projects": [
            {"id": "B0000000-0000-0000-0000-000000000001",
             "workspaceID": "A0000000-0000-0000-0000-000000000001",
             "name": "alpha", "path": "\(alpha)", "branch": "main", "pinned": false,
             "remoteCheckouts": {},
             "worktrees": [{"id": "C0000000-0000-0000-0000-000000000001",
                            "path": "\(alpha)-worktrees/feature", "createdAt": 814595618.0,
                            "pinned": false}],
             "sessions": [
               {"id": "50000000-0000-0000-0000-000000000001", "title": "Claude Code",
                "agent": "claudeCode", "createdAt": 814595622.88, "launched": true,
                "liveTitle": "Fix the sidebar", "termiodDaemonID": "a1b2c3d4"},
               {"id": "50000000-0000-0000-0000-000000000002", "title": "Terminal 1",
                "agent": "terminal", "createdAt": 814595623.88,
                "worktreePath": "\(alpha)-worktrees/feature",
                "spawnDirectory": "\(alpha)-worktrees/feature/src"},
               {"id": "50000000-0000-0000-0000-000000000003", "title": "Terminal 2",
                "agent": "terminal", "createdAt": 814595624.88}
             ]},
            {"id": "B0000000-0000-0000-0000-000000000002",
             "workspaceID": "A0000000-0000-0000-0000-000000000003",
             "name": "Beta Docs", "path": "\(beta)", "branch": "—", "pinned": true,
             "remoteCheckouts": {"box-1": "/home/me/beta"}, "worktrees": [],
             "sessions": [
               {"id": "51000000-0000-0000-0000-000000000001", "title": "Terminal 1",
                "agent": "terminal", "createdAt": 814595625.88, "pinned": true}
             ]},
            {"id": "B0000000-0000-0000-0000-000000000003",
             "workspaceID": "A0000000-0000-0000-0000-000000000001",
             "name": "gone", "path": "\(gone)", "branch": "—", "pinned": false,
             "remoteCheckouts": {}, "worktrees": [],
             "sessions": [
               {"id": "52000000-0000-0000-0000-000000000001", "title": "Terminal 1",
                "agent": "terminal", "createdAt": 814595626.88}
             ]},
            {"id": "B0000000-0000-0000-0000-000000000004",
             "workspaceID": "A0000000-0000-0000-0000-000000000002",
             "name": "app", "path": "/home/me/app", "branch": "—", "pinned": false,
             "remoteCheckouts": {}, "worktrees": [],
             "sessions": [
               {"id": "53000000-0000-0000-0000-000000000001", "title": "Terminal 1",
                "agent": "terminal", "createdAt": 814595627.88,
                "termiodRemoteHost": "vps", "deviceID": "box-1"}
             ]}
          ],
          "splitGroups": [
            {"split": {"_0": {"direction": "horizontal", "id": "D0000000-0000-0000-0000-000000000001",
              "pinned": false, "ratio": 0.5,
              "first": {"leaf": {"_0": "50000000-0000-0000-0000-000000000003"}},
              "second": {"leaf": {"_0": "50000000-0000-0000-0000-000000000001"}}}}},
            {"split": {"_0": {"direction": "vertical", "id": "D0000000-0000-0000-0000-000000000002",
              "pinned": false, "ratio": 0.5,
              "first": {"leaf": {"_0": "70000000-0000-0000-0000-000000000002"}},
              "second": {"leaf": {"_0": "70000000-0000-0000-0000-000000000001"}}}}}
          ],
          "inspectorLayouts": {},
          "workspaceSelections": {}
        }
        """
    }

    static func snapshot(alpha: String, beta: String, gone: String) throws -> StateFile.Snapshot {
        try JSONDecoder().decode(
            StateFile.Snapshot.self,
            from: Data(stateJSON(alpha: alpha, beta: beta, gone: gone).utf8))
    }

    /// This Mac's part of a state file, the way `importTree` cuts it.
    static func localTree(_ snapshot: StateFile.Snapshot) -> Termiod.ViewImport {
        let workspaces = (snapshot.workspaces ?? []).filter { $0.deviceAlias == nil }
        let local = Set(workspaces.map(\.id))
        return TermioStore.viewImport(
            projects: snapshot.projects.filter { local.contains($0.workspaceID) },
            workspaces: workspaces,
            splitGroups: snapshot.splitGroups ?? [],
            name: { $0.termiodSessionName ?? $0.id.uuidString })
    }

    func testTheImportKeepsEveryRowOfThisMacInOrder() throws {
        let snapshot = try Self.snapshot(alpha: "/work/alpha", beta: "/work/beta", gone: "/work/gone")
        let tree = Self.localTree(snapshot)

        XCTAssertEqual(tree.projects.map(\.path), ["/work/alpha", "/work/beta", "/work/gone"],
                       "the box's project is not this Mac's to import")
        XCTAssertEqual(tree.projects.map(\.label), ["alpha", "Beta Docs", "gone"])
        XCTAssertEqual(tree.projects.map(\.pinned), [false, true, false])

        // The split pair shares a group, in the split's order; the worktree
        // session is a group of its own.
        XCTAssertEqual(tree.projects[0].groups.map(\.sessions), [
            ["50000000-0000-0000-0000-000000000003", "50000000-0000-0000-0000-000000000001"],
            ["50000000-0000-0000-0000-000000000002"],
        ])
        XCTAssertEqual(tree.loose.map(\.sessions), [
            ["70000000-0000-0000-0000-000000000002", "70000000-0000-0000-0000-000000000001"],
            ["71000000-0000-0000-0000-000000000001"],
        ])

        let imported = Set(tree.projects.flatMap(\.groups).flatMap(\.sessions)
            + tree.loose.flatMap(\.sessions))
        let local = Set((snapshot.workspaces ?? []).filter { $0.deviceAlias == nil }.map(\.id))
        let expected = Set(snapshot.projects.filter { local.contains($0.workspaceID) }
            .flatMap(\.sessions).map(\.id.uuidString)
            + (snapshot.workspaces ?? []).filter { $0.deviceAlias == nil }
                .flatMap(\.looseSessions).map(\.id.uuidString))
        XCTAssertEqual(imported, expected, "every session of this Mac is named once")
    }

    func testTheWireShapeIsWhatTermiodReads() throws {
        let tree = Termiod.ViewImport(
            projects: [.init(path: "/work", label: "work", pinned: true,
                             groups: [.init(sessions: ["a"])])],
            loose: [.init(sessions: ["b"])])
        let payload = try Termiod.viewImportPayload(tree, seq: 4)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])

        XCTAssertEqual(object["op"] as? String, "view_import")
        XCTAssertEqual(object["seq"] as? Int, 4)
        let project = try XCTUnwrap((object["projects"] as? [[String: Any]])?.first)
        XCTAssertEqual(project["path"] as? String, "/work")
        XCTAssertEqual(project["pinned"] as? Bool, true)

        let place = try JSONSerialization.jsonObject(
            with: Termiod.encodeControl(Termiod.Place.loose)) as? [String: Any]
        XCTAssertEqual(place?["loose"] as? Bool, true)
        XCTAssertNil(place?["project"])
        let named = try JSONSerialization.jsonObject(
            with: Termiod.encodeControl(Termiod.Place.project("p1"))) as? [String: Any]
        XCTAssertEqual(named?["project"] as? String, "p1")
        XCTAssertNil(named?["loose"], "loose is written only when true")
    }

    private func makeStore(_ snapshot: StateFile.Snapshot) -> TermioStore {
        let defaults = UserDefaults(suiteName: "view-import-\(UUID().uuidString)")
            ?? UserDefaults.standard
        return TermioStore(workspaces: snapshot.workspaces ?? [], projects: snapshot.projects,
                           settings: AppSettings(defaults: defaults))
    }

    private func decodeView(_ json: String) throws -> Termiod.HostView {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var view = try decoder.decode(Termiod.HostView.self, from: Data(json.utf8))
        view.offersImport = true
        return view
    }

    private func information(_ id: String, name: String) throws -> Termiod.SessionInformation {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Termiod.SessionInformation.self, from: Data("""
        {"id": "\(id)", "name": "\(name)", "cwd": "/"}
        """.utf8))
    }

    /// The host owns order, labels and pins, files live sessions, and a row
    /// it once had and no longer has goes. Every row is registered here, so
    /// drawing asks no host anything.
    func testThisMacsRowsAreDrawnFromItsView() throws {
        let snapshot = try Self.snapshot(alpha: "/work/alpha", beta: "/work/beta", gone: "/work/gone")
        let store = makeStore(snapshot)
        let alpha = UUID(uuidString: "B0000000-0000-0000-0000-000000000001")
        let beta = UUID(uuidString: "B0000000-0000-0000-0000-000000000002")
        let gone = UUID(uuidString: "B0000000-0000-0000-0000-000000000003")
        for index in store.projects.indices {
            switch store.projects[index].id {
            case alpha: store.projects[index].hostProjectID = "p_alpha"
            case beta: store.projects[index].hostProjectID = "p_beta"
            case gone: store.projects[index].hostProjectID = "p_gone"
            default: break
            }
        }
        let loose = "70000000-0000-0000-0000-000000000001"
        // The host lists beta first and renamed alpha. `p_gone` was removed
        // elsewhere, `p_new` was added by `termio .`, and the loose terminal
        // sits in alpha.
        let view = try decodeView("""
        {"revision": 9, "seeded": true,
         "projects": [
           {"id": "p_beta", "path": "/work/beta", "label": "Beta Docs", "pinned": true, "groups": []},
           {"id": "p_alpha", "path": "/private/work/alpha", "label": "Alpha", "groups": [
             {"id": "g1", "focused": "x1",
              "root": {"pane": {"id": "x1", "kind": "terminal", "session": "s_loose"}}}]},
           {"id": "p_new", "path": "/work/new", "label": "new", "groups": []}],
         "loose": []}
        """)

        store.drawFromHostView(view, on: .thisMac,
                               live: [try information("s_loose", name: loose)])

        let local = Set(store.workspaces.filter { $0.deviceAlias == nil }.map(\.id))
        let rows = store.projects.filter { local.contains($0.workspaceID) }
        XCTAssertEqual(rows.map(\.hostProjectID), ["p_beta", "p_alpha", "p_new"])
        XCTAssertEqual(rows.map(\.name), ["Beta Docs", "Alpha", "new"])
        XCTAssertEqual(rows[1].path, "/work/alpha", "a row keeps this Mac's spelling")
        XCTAssertTrue(rows[1].sessions.contains { $0.id.uuidString == loose })
        XCTAssertFalse(store.workspaces.flatMap(\.terminals).contains { $0.id.uuidString == loose })
        XCTAssertNil(store.projects.first { $0.id == gone }, "removed elsewhere")
        XCTAssertTrue(store.projects.contains { $0.path == "/home/me/app" },
                      "another machine's rows are not this view's")

        // Drawing the same view again changes nothing.
        let drawn = store.projects
        store.drawFromHostView(view, on: .thisMac,
                               live: [try information("s_loose", name: loose)])
        XCTAssertEqual(store.projects, drawn)
    }

    /// The pane goes where the row is: the row's project once it is
    /// registered, a loose group for a loose row, and the cwd before either.
    func testASessionIsPlacedWhereItsRowIs() throws {
        let snapshot = try Self.snapshot(alpha: "/work/alpha", beta: "/work/beta", gone: "/work/gone")
        let store = makeStore(snapshot)
        let project = try XCTUnwrap(store.projects.firstIndex { $0.name == "alpha" })
        let session = store.projects[project].sessions[0]
        let looseSession = try XCTUnwrap(store.workspaces[0].terminals.first)

        XCTAssertNil(store.hostPlace(for: session), "no view yet: the host uses the cwd")

        store.hostViews[KnownDevice.thisMac.id] = try decodeView(
            #"{"revision": 1, "seeded": true, "projects": [], "loose": []}"#)
        XCTAssertNil(store.hostPlace(for: session), "an unregistered row: the cwd")
        XCTAssertEqual(store.hostPlace(for: looseSession), .loose)

        store.projects[project].hostProjectID = "p_alpha"
        XCTAssertEqual(store.hostPlace(for: session), .project("p_alpha"))
    }
}

/// The same import against a real daemon, through this app's real client.
/// Opt-in like `TermiodWireOrderIntegrationTests`: set
/// `TERMIO_TERMIOD_TEST_BIN` to a built `termiod`.
@MainActor
final class TermiodViewImportIntegrationTests: XCTestCase {
    private var daemon: Process?
    private var directory: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let binary = ProcessInfo.processInfo.environment["TERMIO_TERMIOD_TEST_BIN"] ?? ""
        try XCTSkipIf(binary.isEmpty, "set TERMIO_TERMIOD_TEST_BIN to run this")
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vi-\(UUID().uuidString.prefix(8))")
        let home = directory.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        self.directory = directory
        let socket = directory.appendingPathComponent("termiod.sock").path
        XCTAssertLessThan(socket.utf8.count, 104, "socket path must fit sun_path")
        setenv("TERMIOD_SOCK", socket, 1)

        let serve = Process()
        serve.executableURL = URL(fileURLWithPath: binary)
        serve.arguments = ["serve"]
        serve.environment = ProcessInfo.processInfo.environment.merging(
            ["TERMIOD_SOCK": socket, "HOME": home.path, "TERMIOD_KEEP_AWAKE": "off"]
        ) { _, new in new }
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
        if let directory { try? FileManager.default.removeItem(at: directory) }
        unsetenv("TERMIOD_SOCK")
        try super.tearDownWithError()
    }

    /// Starts each named session in `/`, so only the import can place it.
    private func start(_ names: [String]) throws {
        try Termiod.withControlChannel(route: .local) { transport, _ in
            for (index, name) in names.enumerated() {
                let create: [String: Any] = [
                    "op": "create", "name": name, "cwd": "/",
                    "argv": ["/bin/sh", "-c", "sleep 60"], "seq": index + 1,
                ]
                try Termiod.writeFrame(
                    transport.writeDescriptor, kind: .control,
                    payload: JSONSerialization.data(withJSONObject: create))
                while true {
                    let frame = try Termiod.readFrame(transport.readDescriptor)
                    guard frame.kind == .control else { continue }
                    if case .error(let payload) = try Termiod.decodeControl(frame.payload) {
                        XCTFail("create \(name): \(payload.message)")
                    }
                    break
                }
            }
        }
    }

    func testARealStateFileImportsWithoutLosingARow() throws {
        let root = try XCTUnwrap(directory)
        let alpha = root.appendingPathComponent("alpha").path
        let beta = root.appendingPathComponent("beta").path
        let gone = root.appendingPathComponent("gone").path
        for path in [alpha, beta] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        let snapshot = try TermiodViewImportTests.snapshot(alpha: alpha, beta: beta, gone: gone)
        let tree = TermiodViewImportTests.localTree(snapshot)
        let names = tree.projects.flatMap(\.groups).flatMap(\.sessions)
            + tree.loose.flatMap(\.sessions)
        // Every row of this Mac is running but one, which has no pane to move.
        let notRunning = "50000000-0000-0000-0000-000000000002"
        try start(names.filter { $0 != notRunning })

        let (ids, sessions, view) = try Termiod.importView(route: .local, tree: tree)
        let projectIDs = try XCTUnwrap(ids, "the first import is taken")
        XCTAssertEqual(projectIDs.count, 3)
        XCTAssertTrue(view.seeded)
        XCTAssertEqual(view.projects.map(\.id), projectIDs, "the Mac's order")
        XCTAssertEqual(view.projects.map(\.label), ["alpha", "Beta Docs", "gone"])
        XCTAssertEqual(view.projects.map(\.pinned), [false, true, false])
        XCTAssertEqual(view.projects[2].path, gone, "a folder that is gone keeps its row")

        var nameByID: [String: String] = [:]
        for information in sessions.sessions { nameByID[information.id] = information.name }
        func shown(_ group: Termiod.HostView.Group) -> [String] {
            group.root.sessions.compactMap { nameByID[$0] }
        }
        for (hostProject, imported) in zip(view.projects, tree.projects) {
            XCTAssertEqual(
                hostProject.groups.map(shown),
                imported.groups.map { $0.sessions.filter { $0 != notRunning } }
                    .filter { !$0.isEmpty },
                "the groups of \(imported.label)")
        }
        XCTAssertEqual(view.loose.map(shown), tree.loose.map(\.sessions))

        // Drawn back, this Mac's rows are the rows it had.
        let defaults = UserDefaults(suiteName: "view-import-\(UUID().uuidString)")
            ?? UserDefaults.standard
        let store = TermioStore(workspaces: snapshot.workspaces ?? [], projects: snapshot.projects,
                                settings: AppSettings(defaults: defaults))
        let local = Set(store.workspaces.filter { $0.deviceAlias == nil }.map(\.id))
        let rowIDs = store.projects.filter { local.contains($0.workspaceID) }.map(\.id)
        for (rowID, hostID) in zip(rowIDs, projectIDs) {
            if let index = store.projects.firstIndex(where: { $0.id == rowID }) {
                store.projects[index].hostProjectID = hostID
            }
        }
        let before = store.projects
        let looseBefore = store.workspaces.map(\.looseSessions)
        store.drawFromHostView(view, on: .thisMac, live: sessions.sessions)
        XCTAssertEqual(store.projects.map(\.id), before.map(\.id))
        XCTAssertEqual(store.projects.map { $0.sessions.map(\.id) }, before.map { $0.sessions.map(\.id) })
        XCTAssertEqual(store.workspaces.map(\.looseSessions), looseBefore)

        let (again, _, _) = try Termiod.importView(route: .local, tree: tree)
        XCTAssertNil(again, "a seeded host keeps its own view")
    }
}
