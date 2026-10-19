import XCTest
@testable import termio

/// Resume binds a relaunched session to the conversation the agent created, by
/// reading the agent's own session header. omp puts a title record on line 1 and
/// the header on line 2, so a reader that only takes line 1 finds no id and every
/// omp session silently relaunches blank.
final class AgentSessionStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func agent(id: String, idPath: String, cwdPath: String) throws -> AgentPreset {
        let json = """
        { "id": "\(id)", "name": "\(id)", "command": "\(id)",
          "resume": { "resume": "--resume {id}",
            "discover": { "root": "\(root.path)", "format": "jsonl",
                          "id": "\(idPath)", "cwd": "\(cwdPath)" } } }
        """
        let manifest = try JSONDecoder().decode(AgentManifest.self, from: Data(json.utf8))
        return try manifest.definition(directory: root, resourceBundle: .main)
    }

    private func write(_ lines: [String], to name: String) throws -> URL {
        let directory = root.appendingPathComponent("--project--", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testHeaderAfterTitleRecordIsDiscovered() throws {
        let omp = try agent(id: "omp", idPath: "id", cwdPath: "cwd")
        let launchedAt = Date()
        let url = try write([
            #"{"type":"title","v":1,"title":"🔎 Add search","source":"auto","pad":"   "}"#,
            #"{"type":"session","version":3,"id":"01a14f8c-f45f-7000","cwd":"\#(root.path)"}"#,
            #"{"type":"message","role":"user"}"#,
        ], to: "2026-10-18T15-06-40-095Z_01a14f8c-f45f-7000.jsonl")

        XCTAssertEqual(
            AgentSessionStore.discover(agent: omp, directory: root.path, after: launchedAt),
            "01a14f8c-f45f-7000")
        let transcript = try XCTUnwrap(AgentSessionStore.transcript(agent: omp, id: "01a14f8c-f45f-7000"))
        XCTAssertEqual(
            URL(fileURLWithPath: transcript).resolvingSymlinksInPath().path,
            url.resolvingSymlinksInPath().path)
    }

    func testHeaderOnFirstLineStillDiscovered() throws {
        let codex = try agent(id: "codex", idPath: "payload.id", cwdPath: "payload.cwd")
        let launchedAt = Date()
        _ = try write([
            #"{"type":"session_meta","payload":{"id":"rollout-1","cwd":"\#(root.path)"}}"#,
        ], to: "rollout-1.jsonl")

        XCTAssertEqual(
            AgentSessionStore.discover(agent: codex, directory: root.path, after: launchedAt),
            "rollout-1")
    }
}
