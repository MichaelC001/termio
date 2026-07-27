import Darwin
import Foundation
import XCTest
@testable import termio

final class SSHListingProtocolTests: XCTestCase {
    func testParsesNULTerminatedNamesIncludingNewlines() throws {
        let data = records([
            ("d", "folder"),
            ("f", "line\nbreak.txt"),
            ("l", "broken-link"),
            ("o", "named-pipe"),
        ])

        let entries = try SSHFileSystemProvider.parseListing(data)

        XCTAssertEqual(entries.map(\.name), [
            "folder", "line\nbreak.txt", "broken-link", "named-pipe",
        ])
        XCTAssertEqual(entries.map(\.kind), [
            .directory, .file, .symlink, .other,
        ])
        XCTAssertTrue(entries[0].isDirectory)
        XCTAssertTrue(entries[1].isPreviewable)
        XCTAssertFalse(entries[2].isPreviewable)
        XCTAssertFalse(entries[3].isPreviewable)
    }

    func testRejectsTraversalAndMalformedRecords() {
        XCTAssertThrowsError(
            try SSHFileSystemProvider.parseListing(records([("f", "../../tmp/owned")])))
        XCTAssertThrowsError(
            try SSHFileSystemProvider.parseListing(records([("f", "..")])))

        var unterminated = Data("f\0name".utf8)
        XCTAssertThrowsError(try SSHFileSystemProvider.parseListing(unterminated))
        unterminated.append(0)
        unterminated.append(contentsOf: Data("extra\0".utf8))
        XCTAssertThrowsError(try SSHFileSystemProvider.parseListing(unterminated))
        XCTAssertThrowsError(
            try SSHFileSystemProvider.parseListing(Data([102, 0, 0xff, 0])))
    }

    func testHomeMarkerIgnoresShellStartupChatter() throws {
        let data = Data("banner from rc\n\0TERMIO_HOME\0/home/test user\0".utf8)
        XCTAssertEqual(try SSHFileSystemProvider.parseHome(data), "/home/test user")
    }

    func testListingCommandDoesNotInterpretSymlinkTargetAsRecords() async throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory
            .appendingPathComponent("termio-ssh-list-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }

        let regularNames = [
            "line\nbreak.txt",
            "quote's file",
            "tab\tfile",
            "-leading-option",
        ]
        for name in regularNames {
            XCTAssertTrue(manager.createFile(
                atPath: directory.appendingPathComponent(name).path,
                contents: Data("hello".utf8)))
        }
        let target = directory.appendingPathComponent("target").path
        XCTAssertTrue(manager.createFile(atPath: target, contents: Data("target".utf8)))
        try manager.createSymbolicLink(
            atPath: directory.appendingPathComponent("safe-link").path,
            withDestinationPath: target)
        let fifo = directory.appendingPathComponent("named-pipe").path
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)

        let result = await SSHProcessRunner.run([
            "/bin/sh", "-c", SSHFileSystemProvider.listingCommand(for: directory.path),
        ], timeout: 5)
        XCTAssertEqual(result.status, 0, result.stderr)

        let entries = try SSHFileSystemProvider.parseListing(result.stdout)
        XCTAssertEqual(
            Set(entries.map(\.name)),
            Set(regularNames + ["target", "safe-link", "named-pipe"]))
        for name in regularNames + ["target"] {
            XCTAssertEqual(entries.first(where: { $0.name == name })?.kind, .file)
        }
        XCTAssertEqual(entries.first(where: { $0.name == "safe-link" })?.kind, .symlink)
        XCTAssertEqual(entries.first(where: { $0.name == "named-pipe" })?.kind, .other)
    }

    @MainActor
    func testSSHArgvTerminatesOptionsBeforeDestination() {
        let options = ["-o", "BatchMode=yes"]
        XCTAssertEqual(
            SSHFileSystemProvider.checkArgv(host: "-host", clientOptions: options),
            ["/usr/bin/ssh", "-o", "BatchMode=yes", "-O", "check", "--", "-host"])
        XCTAssertEqual(
            SSHFileSystemProvider.commandArgv(
                host: "-host", remoteCommand: "printf ok", clientOptions: options),
            ["/usr/bin/ssh", "-o", "BatchMode=yes", "-T", "--", "-host", "printf ok"])
        XCTAssertTrue(TermioStore.sshCommand(host: "-host").contains(" -- '-host'"))
    }

    func testControlPathBudgetHandlesLongHomesAndActualTemplate() throws {
        XCTAssertTrue(SSHMux.isControlPathSafe(directoryPath: "/tmp/termio-501-ABCDEF"))
        XCTAssertFalse(SSHMux.isControlPathSafe(directoryPath: "/" + String(repeating: "x", count: 80)))
        let template = try XCTUnwrap(SSHMux.controlPathTemplate)
        let expanded = template.replacingOccurrences(
            of: "%C", with: String(repeating: "a", count: SSHMux.controlHashBytes))
        XCTAssertLessThanOrEqual(expanded.utf8.count, SSHMux.maximumSocketPathBytes)
    }

    @MainActor
    func testPreviewLeasesArePrivateIndependentAndCleanUp() throws {
        XCTAssertTrue(RemotePreviewStorage.isSafeComponent("hello world.swift"))
        XCTAssertTrue(RemotePreviewStorage.isSafeComponent("line\nbreak.txt"))
        XCTAssertFalse(RemotePreviewStorage.isSafeComponent("../../tmp/owned"))
        XCTAssertFalse(RemotePreviewStorage.isSafeComponent(".."))
        XCTAssertFalse(RemotePreviewStorage.isSafeComponent("nul\0byte"))

        var first: RemotePreviewLease? = try RemotePreviewStorage.stage(
            Data("first".utf8), named: "remote\nname.txt")
        let firstURL = try XCTUnwrap(first?.fileURL)
        XCTAssertEqual(first?.displayName, "remote\nname.txt")
        XCTAssertEqual(firstURL.lastPathComponent, "preview.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
        let permissions = try FileManager.default.attributesOfItem(
            atPath: firstURL.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((permissions?.intValue ?? 0) & 0o777, 0o700)

        var second: RemotePreviewLease? = try RemotePreviewStorage.stage(
            Data("second".utf8), named: "safe.txt")
        let secondURL = try XCTUnwrap(second?.fileURL)
        first = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
        second = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondURL.path))
    }

    func testRemoteActiveContentClassification() {
        XCTAssertTrue(FileActivation.isActiveWebContent(URL(fileURLWithPath: "/tmp/page.html")))
        XCTAssertTrue(FileActivation.isActiveWebContent(URL(fileURLWithPath: "/tmp/vector.svg")))
        XCTAssertFalse(FileActivation.isActiveWebContent(URL(fileURLWithPath: "/tmp/image.png")))
        XCTAssertFalse(FilePreviewView.usesWebFallback(
            imageDecoded: false, allowsWebFallback: false))
        XCTAssertTrue(FilePreviewView.usesWebFallback(
            imageDecoded: false, allowsWebFallback: true))
    }

    @MainActor
    func testStoreRejectsStaleRemotePresentationAndOwnsAcceptedLease() throws {
        let suite = "termio-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TermioStore(projects: [], settings: AppSettings(defaults: defaults))

        var staleLease: RemotePreviewLease? = try RemotePreviewStorage.stage(
            Data("stale".utf8), named: "stale.txt")
        let staleURL = try XCTUnwrap(staleLease?.fileURL)
        let staleGeneration = store.filePresentationGeneration
        store.openFileInEditor(URL(fileURLWithPath: "/tmp/local-winner.txt"))

        XCTAssertFalse(store.presentRemoteFilePreview(
            try XCTUnwrap(staleLease), expectedGeneration: staleGeneration))
        staleLease = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleURL.path))

        var acceptedLease: RemotePreviewLease? = try RemotePreviewStorage.stage(
            Data("accepted".utf8), named: "remote name.md")
        let acceptedURL = try XCTUnwrap(acceptedLease?.fileURL)
        XCTAssertTrue(store.presentRemoteFilePreview(
            try XCTUnwrap(acceptedLease),
            expectedGeneration: store.filePresentationGeneration))
        XCTAssertEqual(store.openFileDisplayName, "remote name.md")
        acceptedLease = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: acceptedURL.path))

        store.openFileURL = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: acceptedURL.path))
    }

    func testReadCommandCapsBytesAndRejectsFIFO() async throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory
            .appendingPathComponent("termio-ssh-read-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }

        let exact = directory.appendingPathComponent("exact").path
        XCTAssertTrue(manager.createFile(atPath: exact, contents: Data(repeating: 97, count: 128)))
        let exactResult = await runReadCommand(path: exact, limit: 128)
        XCTAssertEqual(exactResult.status, 0, exactResult.stderr)
        XCTAssertEqual(exactResult.stdout.count, 128)
        XCTAssertFalse(exactResult.outputLimitExceeded)

        let oversized = directory.appendingPathComponent("oversized").path
        XCTAssertTrue(manager.createFile(
            atPath: oversized, contents: Data(repeating: 98, count: 129)))
        let oversizedResult = await runReadCommand(path: oversized, limit: 128)
        XCTAssertTrue(oversizedResult.outputLimitExceeded)
        XCTAssertEqual(oversizedResult.stdout.count, 128)

        let fifo = directory.appendingPathComponent("pipe").path
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        let started = Date()
        let fifoResult = await runReadCommand(path: fifo, limit: 128)
        XCTAssertEqual(fifoResult.status, 65)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    private func records(_ values: [(String, String)]) -> Data {
        var data = Data()
        for (kind, name) in values {
            data.append(contentsOf: kind.utf8)
            data.append(0)
            data.append(contentsOf: name.utf8)
            data.append(0)
        }
        return data
    }

    private func runReadCommand(path: String, limit: Int) async -> SSHProcessResult {
        await SSHProcessRunner.run(
            ["/bin/sh", "-c", SSHFileSystemProvider.readCommand(for: path, limit: limit)],
            captureLimit: limit,
            timeout: 2)
    }
}

final class SSHProcessRunnerTests: XCTestCase {
    func testDrainsLargeStderrWithoutDeadlock() async {
        let result = await SSHProcessRunner.run([
            "/bin/sh", "-c",
            "/usr/bin/yes x | /usr/bin/head -c 131072 >&2; printf ok",
        ], timeout: 5)

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "ok")
        XCTAssertEqual(result.stderr.utf8.count, SSHProcessRunner.stderrCaptureLimit)
        XCTAssertFalse(result.timedOut)
    }

    func testCaptureLimitTerminatesProducer() async {
        let result = await SSHProcessRunner.run(
            ["/usr/bin/head", "-c", "4096", "/dev/zero"],
            captureLimit: 128,
            timeout: 5)

        XCTAssertTrue(result.outputLimitExceeded)
        XCTAssertLessThanOrEqual(result.stdout.count, 128)
    }

    func testTimeoutTerminatesProcess() async {
        let started = Date()
        let result = await SSHProcessRunner.run(
            ["/bin/sleep", "5"],
            timeout: 0.05)

        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testTaskCancellationTerminatesProcess() async throws {
        let started = Date()
        let task = Task {
            await SSHProcessRunner.run([
                "/bin/sh", "-c",
                "trap '' TERM; /bin/sleep 30 & printf '%s' \"$!\"; wait",
            ], timeout: 10)
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        let result = await task.value
        XCTAssertTrue(result.wasCancelled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        let childPID = try XCTUnwrap(
            pid_t(String(decoding: result.stdout, as: UTF8.self)))
        var childIsGone = false
        for _ in 0..<20 {
            if kill(childPID, 0) == -1, errno == ESRCH {
                childIsGone = true
                break
            }
            usleep(10_000)
        }
        XCTAssertTrue(childIsGone, "cancellation left a subprocess running")
    }

    func testListingCaptureLimitTerminatesUnboundedProducer() async {
        let result = await SSHProcessRunner.run(
            ["/usr/bin/yes", "listing"],
            captureLimit: SSHFileSystemProvider.listingByteLimit,
            timeout: 5)

        XCTAssertTrue(result.outputLimitExceeded)
        XCTAssertEqual(result.stdout.count, SSHFileSystemProvider.listingByteLimit)
        XCTAssertFalse(result.timedOut)
    }
}
