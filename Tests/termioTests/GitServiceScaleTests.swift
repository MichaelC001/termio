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
