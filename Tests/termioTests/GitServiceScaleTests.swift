import XCTest
@testable import termio

/// The untracked-flood behavior: a repo with thousands of unignored build products must not
/// cost thousands of file reads, and the in-app .gitignore repair must actually silence them.
final class GitServiceScaleTests: XCTestCase {
    private var repo: URL!

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("termio-git-scale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
    }

    private func git(_ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = repo
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(args.joined(separator: " ")) failed")
    }

    private func write(_ relative: String, _ contents: Data) throws {
        let url = repo.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try contents.write(to: url)
    }

    func testUntrackedTextAndBinaryCounts() async throws {
        try write("a.swift", Data("one\ntwo\nthree".utf8))
        try write("blob.o", Data([0x00, 0x01, 0x02, 0x4D, 0x00]))
        let changes = await GitService.changes(in: repo.path)
        let text = changes.first { $0.path == "a.swift" }
        let binary = changes.first { $0.path == "blob.o" }
        // No trailing newline still counts the last line — matches the old String-split count.
        XCTAssertEqual(text?.additions, 3)
        XCTAssertEqual(binary?.isBinary, true)
        XCTAssertEqual(binary?.additions, 0)
    }

    func testUntrackedFloodSkipsLineCounts() async throws {
        for i in 0..<(GitService.untrackedCountLimit + 20) {
            try write(".build/f\(i).txt", Data("x\ny\n".utf8))
        }
        let changes = await GitService.changes(in: repo.path)
        XCTAssertGreaterThan(changes.count, GitService.untrackedCountLimit)
        // Every row keeps its untracked status but nobody paid for a line count.
        XCTAssertTrue(changes.allSatisfy { $0.isUntracked && $0.additions == 0 })
    }

    func testUntrackedRootsCollapseDirectories() async throws {
        try write(".build/deep/one.o", Data("a".utf8))
        try write(".build/deep/two.o", Data("b".utf8))
        try write("loose.txt", Data("c".utf8))
        let roots = await GitService.untrackedRoots(in: repo.path)
        XCTAssertEqual(roots, [".build/"])
    }

    func testLineCountBoundaries() async throws {
        // Trailing newline must NOT add a phantom line (the old String-split did: "x\ny\n"
        // split non-omitting gave ["x","y",""] = 3); git counts 2 and so do we now.
        try write("terminated.txt", Data("x\ny\n".utf8))
        try write("empty.txt", Data())
        try write("blank.txt", Data("\n".utf8))
        let changes = await GitService.changes(in: repo.path)
        XCTAssertEqual(changes.first { $0.path == "terminated.txt" }?.additions, 2)
        XCTAssertEqual(changes.first { $0.path == "empty.txt" }?.additions, 0)
        XCTAssertEqual(changes.first { $0.path == "blank.txt" }?.additions, 1)
    }

    func testGitignorePatternEscapesLiteralNames() async throws {
        // Names full of glob metacharacters and a trailing space must ignore exactly
        // themselves — proven by git's own matcher, not our reading of the spec.
        let names = ["we ird *[a].txt", "#lead.txt", "!bang.txt", "trail .txt"]
        for name in names {
            try write(name, Data("x".utf8))
            let pattern = try XCTUnwrap(GitService.gitignorePattern(for: name))
            await GitService.appendToGitignore([pattern], in: repo.path)
        }
        XCTAssertNil(GitService.gitignorePattern(for: "new\nline.txt"))
        let changes = await GitService.changes(in: repo.path)
        XCTAssertEqual(changes.map(\.path), [".gitignore"], "some pattern failed to match its own file")
    }

    func testAppendToGitignoreAppendsWithoutRewriting() async throws {
        // Existing contents (even non-UTF8 bytes) must survive an append untouched.
        let original = Data([0x23, 0x20, 0xFF, 0xFE, 0x0A]) // "# " + invalid UTF-8 + newline
        try original.write(to: repo.appendingPathComponent(".gitignore"))
        await GitService.appendToGitignore(["/x.txt"], in: repo.path)
        let after = try Data(contentsOf: repo.appendingPathComponent(".gitignore"))
        XCTAssertEqual(after.prefix(original.count), original)
        XCTAssertTrue(String(decoding: after, as: UTF8.self).hasSuffix("/x.txt\n"))
    }

    func testAppendToGitignoreCreatesDeduplicatesAndSilences() async throws {
        try write(".build/junk.o", Data("junk".utf8))
        await GitService.appendToGitignore(["/.build/"], in: repo.path)
        await GitService.appendToGitignore(["/.build/"], in: repo.path) // idempotent
        let gitignore = try String(
            contentsOf: repo.appendingPathComponent(".gitignore"), encoding: .utf8
        )
        XCTAssertEqual(gitignore.components(separatedBy: "/.build/").count, 2, "pattern duplicated")
        // The flood is actually silenced (the .gitignore itself shows up as untracked instead).
        let changes = await GitService.changes(in: repo.path)
        XCTAssertEqual(changes.map(\.path), [".gitignore"])
    }
}
