import Darwin
import Foundation

/// The OpenSSH ControlMaster socket termio-spawned `ssh` sessions share with the
/// inspector's remote file tree. The terminal session is the master: the user
/// authenticates once there, and pane operations reuse that exact connection.
enum SSHMux {
    /// macOS exposes a 104-byte `sun_path`, including the trailing NUL.
    static let maximumSocketPathBytes = 103
    static let controlHashBytes = 40
    private static let staleDirectoryAge: TimeInterval = 120

    /// One short, private directory per app process. `mkdtemp` creates it
    /// atomically as 0700, avoiding both long/network home paths and predictable
    /// `/tmp` directory ownership races. A restored session starts a new master
    /// with the new process's path, so cross-launch stability is unnecessary.
    static let directory: URL? = {
        let parent = URL(fileURLWithPath: "/tmp", isDirectory: true)
        let prefix = "termio-ssh-\(getuid())\(AppChannel.suffix)-"
        removeStaleDirectories(in: parent, prefix: prefix)

        let pid = getpid()
        var template = Array(
            parent.appendingPathComponent("\(prefix)\(pid)-XXXXXX").path.utf8CString)
        let path: String? = template.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress, mkdtemp(base) != nil else { return nil }
            return String(cString: base)
        }
        guard let path else { return nil }
        guard isControlPathSafe(directoryPath: path) else {
            try? FileManager.default.removeItem(atPath: path)
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }()

    static func isControlPathSafe(directoryPath: String) -> Bool {
        directoryPath.utf8.count + 1 + controlHashBytes <= maximumSocketPathBytes
    }

    /// Remove only same-user directories from dead app processes, and only
    /// after ControlPersist's 60-second window has safely elapsed.
    private static func removeStaleDirectories(in parent: URL, prefix: String) {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey,
        ]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        else { return }

        let now = Date()
        for url in urls where url.lastPathComponent.hasPrefix(prefix) {
            let remainder = url.lastPathComponent.dropFirst(prefix.count)
            guard let separator = remainder.firstIndex(of: "-"),
                  let pid = pid_t(remainder[..<separator]),
                  pid > 0,
                  kill(pid, 0) == -1,
                  errno == ESRCH,
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isDirectory == true,
                  values.isSymbolicLink != true,
                  now.timeIntervalSince(values.contentModificationDate ?? now) >= staleDirectoryAge,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
            else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// The `ControlPath` value both sides pass — `%C` is expanded by ssh itself.
    static var controlPathTemplate: String? {
        directory?.appendingPathComponent("%C").path
    }

    /// Appended to the interactive terminal's `ssh <host>` command. If the
    /// private runtime directory could not be created, the terminal still opens
    /// normally; only the optional remote browser is unavailable.
    static var masterShellOptions: String? {
        guard let controlPathTemplate else { return nil }
        return "-o ControlMaster=auto -o ControlPath=\(shellQuoted(controlPathTemplate)) -o ControlPersist=60"
    }

    /// Pane-side helper options: reuse the session socket, never own a
    /// connection, and never raise an authentication prompt.
    static var clientOptions: [String]? {
        guard let controlPathTemplate else { return nil }
        return [
            "-o", "ControlPath=\(controlPathTemplate)",
            "-o", "ControlMaster=no",
            "-o", "BatchMode=yes",
        ]
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Removes this process's private mux directory after every hosted SSH
    /// session has been torn down on a clean app quit.
    static func cleanup() {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Why a remote operation failed, split so the pane can react honestly.
enum SSHProviderError: Error, Equatable {
    case disconnected
    case muxUnavailable
    case commandFailed(String)
    case unsupportedListing
    case listingTooLarge
    case notRegularFile
    case tooLarge
    case timedOut
}

/// Browses an SSH host over the terminal session's existing ControlMaster.
///
/// Directory records are emitted as `kind\0basename\0` by a remote `find` +
/// POSIX-shell loop. NUL framing is deliberate: Unix names may contain newlines,
/// so a line-oriented `ls` parser can be spoofed by a crafted symlink target.
actor SSHFileSystemProvider: FileSystemProvider {
    let host: String

    static let listingByteLimit = 8 * 1_048_576
    private var probedHome: String?

    init(host: String) {
        self.host = host
    }

    func root() async throws -> String {
        try await probeHome()
    }

    func list(_ path: String) async throws -> [FileEntry] {
        do {
            let output = try await run(
                Self.listingCommand(for: path),
                captureLimit: Self.listingByteLimit,
                timeout: 30)
            return try Self.parseListing(output).sortedForTree()
        } catch SSHProviderError.tooLarge {
            throw SSHProviderError.listingTooLarge
        }
    }

    func read(_ path: String, limit: Int) async throws -> Data {
        guard limit >= 0, limit < Int.max else { throw SSHProviderError.tooLarge }
        return try await run(
            Self.readCommand(for: path, limit: limit),
            captureLimit: limit,
            timeout: 15,
            notRegularExitStatus: 65)
    }

    // MARK: Connection

    private func run(
        _ remoteCommand: String,
        captureLimit: Int? = nil,
        timeout: TimeInterval,
        notRegularExitStatus: Int32? = nil
    ) async throws -> Data {
        guard let clientOptions = SSHMux.clientOptions else {
            throw SSHProviderError.muxUnavailable
        }

        let check = await SSHProcessRunner.run(
            Self.checkArgv(host: host, clientOptions: clientOptions),
            timeout: 3)
        if check.wasCancelled { throw CancellationError() }
        guard !check.timedOut, check.status == 0 else {
            throw SSHProviderError.disconnected
        }

        let result = await SSHProcessRunner.run(
            Self.commandArgv(
                host: host, remoteCommand: remoteCommand, clientOptions: clientOptions),
            captureLimit: captureLimit,
            timeout: timeout)
        if result.wasCancelled { throw CancellationError() }
        if result.timedOut { throw SSHProviderError.timedOut }
        if result.outputLimitExceeded { throw SSHProviderError.tooLarge }
        if let notRegularExitStatus, result.status == notRegularExitStatus {
            throw SSHProviderError.notRegularFile
        }
        guard result.status == 0 else {
            throw SSHProviderError.commandFailed(
                result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.stdout
    }

    /// Resolve `$HOME` once. NUL-delimited markers keep shell startup chatter
    /// from being mistaken for either the marker or the path.
    private func probeHome() async throws -> String {
        if let probedHome { return probedHome }
        let output = try await run(
            "printf '\\0TERMIO_HOME\\0%s\\0' \"$HOME\"",
            timeout: 10)
        let home = try Self.parseHome(output)
        probedHome = home
        return home
    }

    // MARK: Listing protocol

    private static let listScript = """
    for entry do
        if [ -L "$entry" ]; then
            kind=l
        elif [ -d "$entry" ]; then
            kind=d
        elif [ -f "$entry" ]; then
            kind=f
        else
            kind=o
        fi
        name=${entry##*/}
        printf '%s\\0%s\\0' "$kind" "$name"
    done
    """

    /// Internal for the local protocol integration test.
    static func listingCommand(for path: String) -> String {
        "find -H \(quoted(path)) -mindepth 1 -maxdepth 1 "
            + "-exec sh -c \(quoted(listScript)) sh {} +"
    }

    /// Re-check the file type immediately before opening it, then cap the
    /// remote producer as well as the local pipe. The process timeout remains
    /// the final guard against a file being swapped after the check.
    static func readCommand(for path: String, limit: Int) -> String {
        let byteCount = limit + 1
        return """
        path=\(quoted(path))
        if [ ! -f "$path" ] || [ -L "$path" ]; then
            printf '%s\n' 'termio: not a regular file' >&2
            exit 65
        fi
        dd if="$path" bs=\(byteCount) count=1 2>/dev/null
        """
    }

    static func checkArgv(host: String, clientOptions: [String]) -> [String] {
        ["/usr/bin/ssh"] + clientOptions + ["-O", "check", "--", host]
    }

    static func commandArgv(
        host: String,
        remoteCommand: String,
        clientOptions: [String]
    ) -> [String] {
        ["/usr/bin/ssh"] + clientOptions + ["-T", "--", host, remoteCommand]
    }

    /// Internal for regression tests: malformed/traversing records fail closed.
    static func parseListing(_ data: Data) throws -> [FileEntry] {
        let fields = try nulFields(in: data)
        guard fields.count.isMultiple(of: 2) else {
            throw SSHProviderError.unsupportedListing
        }

        var entries: [FileEntry] = []
        entries.reserveCapacity(fields.count / 2)
        for index in stride(from: 0, to: fields.count, by: 2) {
            guard fields[index].count == 1,
                  let code = fields[index].first,
                  let name = String(data: fields[index + 1], encoding: .utf8),
                  isSafeEntryName(name)
            else {
                throw SSHProviderError.unsupportedListing
            }

            let kind: FileEntry.Kind
            switch code {
            case 102: kind = .file // f
            case 100: kind = .directory // d
            case 108: kind = .symlink // l
            case 111: kind = .other // o
            default: throw SSHProviderError.unsupportedListing
            }
            entries.append(FileEntry(name: name, kind: kind))
        }
        return entries
    }

    static func parseHome(_ data: Data) throws -> String {
        let fields = try nulFields(in: data)
        let marker = Data("TERMIO_HOME".utf8)
        guard let markerIndex = fields.lastIndex(of: marker),
              fields.indices.contains(markerIndex + 1),
              let home = String(data: fields[markerIndex + 1], encoding: .utf8),
              home.hasPrefix("/"),
              !home.contains("\0")
        else {
            throw SSHProviderError.commandFailed("The remote home directory could not be resolved.")
        }
        return home
    }

    private static func nulFields(in data: Data) throws -> [Data] {
        var fields: [Data] = []
        var fieldStart = data.startIndex
        for index in data.indices where data[index] == 0 {
            fields.append(data[fieldStart..<index])
            fieldStart = data.index(after: index)
        }
        guard fieldStart == data.endIndex else {
            throw SSHProviderError.unsupportedListing
        }
        return fields
    }

    private static func isSafeEntryName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\0")
    }

    private static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Bounded subprocess runner

struct SSHProcessResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: String
    let timedOut: Bool
    let wasCancelled: Bool
    let outputLimitExceeded: Bool
}

/// `Process` is callback-based and does not inherit Swift task cancellation.
/// This bridge drains both pipes concurrently, bounds captured output, and owns
/// timeout/cancellation termination so no hidden SSH helper can live forever.
enum SSHProcessRunner {
    static let stderrCaptureLimit = 65_536
    fileprivate static let terminationGrace: TimeInterval = 0.25
    private static let readerDrainGrace: TimeInterval = 0.5

    static func run(
        _ argv: [String],
        captureLimit: Int? = nil,
        timeout: TimeInterval = 30
    ) async -> SSHProcessResult {
        let execution = SSHProcessExecution()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: runSync(
                        argv,
                        captureLimit: captureLimit,
                        timeout: timeout,
                        execution: execution))
                }
            }
        }, onCancel: {
            execution.cancel()
        })
    }

    private static func runSync(
        _ argv: [String],
        captureLimit: Int?,
        timeout: TimeInterval,
        execution: SSHProcessExecution
    ) -> SSHProcessResult {
        guard let executable = argv.first else {
            return SSHProcessResult(
                status: 127, stdout: Data(), stderr: "missing executable",
                timedOut: false, wasCancelled: execution.isCancelled,
                outputLimitExceeded: false)
        }
        if execution.isCancelled {
            return SSHProcessResult(
                status: SIGTERM, stdout: Data(), stderr: "",
                timedOut: false, wasCancelled: true,
                outputLimitExceeded: false)
        }

        guard !argv.contains(where: { $0.contains("\0") }) else {
            return SSHProcessResult(
                status: 127, stdout: Data(), stderr: "invalid NUL in process argument",
                timedOut: false, wasCancelled: execution.isCancelled,
                outputLimitExceeded: false)
        }

        var stdoutFDs = [Int32](repeating: -1, count: 2)
        var stderrFDs = [Int32](repeating: -1, count: 2)
        guard pipe(&stdoutFDs) == 0, pipe(&stderrFDs) == 0 else {
            for descriptor in stdoutFDs + stderrFDs where descriptor >= 0 {
                close(descriptor)
            }
            return SSHProcessResult(
                status: 127, stdout: Data(), stderr: "could not create process pipes",
                timedOut: false, wasCancelled: execution.isCancelled,
                outputLimitExceeded: false)
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        posix_spawn_file_actions_addopen(
            &actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdoutFDs[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderrFDs[1], STDERR_FILENO)
        for descriptor in stdoutFDs + stderrFDs {
            posix_spawn_file_actions_addclose(&actions, descriptor)
        }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        var processID: pid_t = 0
        let spawnStatus = withCStringArray(argv) { cArguments in
            posix_spawn(
                &processID, executable, &actions, &attributes,
                cArguments, environ)
        }
        close(stdoutFDs[1])
        close(stderrFDs[1])
        guard spawnStatus == 0 else {
            close(stdoutFDs[0])
            close(stderrFDs[0])
            return SSHProcessResult(
                status: 127,
                stdout: Data(),
                stderr: String(cString: strerror(spawnStatus)),
                timedOut: false,
                wasCancelled: execution.isCancelled,
                outputLimitExceeded: false)
        }
        execution.register(processID)

        let stdoutHandle = FileHandle(
            fileDescriptor: stdoutFDs[0], closeOnDealloc: true)
        let stderrHandle = FileHandle(
            fileDescriptor: stderrFDs[0], closeOnDealloc: true)

        let readers = DispatchGroup()
        let stdoutCapture = PipeCapture()
        let stderrCapture = PipeCapture()
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdoutCapture.drain(
                stdoutHandle,
                limit: captureLimit,
                onLimitExceeded: { execution.terminate(after: terminationGrace) })
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrCapture.drain(
                stderrHandle,
                limit: stderrCaptureLimit)
            readers.leave()
        }

        var timedOut = false
        var exitStatus: Int32 = -1
        var didExit = waitForExit(
            processID,
            until: Date().addingTimeInterval(max(timeout, 0.01)),
            status: &exitStatus)
        if !didExit {
            timedOut = true
            execution.terminate(after: terminationGrace)
            didExit = waitForExit(
                processID,
                until: Date().addingTimeInterval(terminationGrace + 1),
                status: &exitStatus)
            if !didExit {
                kill(-processID, SIGKILL)
                didExit = waitForExit(
                    processID,
                    until: Date().addingTimeInterval(1),
                    status: &exitStatus)
            }
        }

        if readers.wait(timeout: .now() + readerDrainGrace) == .timedOut {
            // A subprocess can leave a child holding the pipe descriptors.
            // Closing our read ends lets this operation return without waiting
            // on a process it does not own.
            try? stdoutHandle.close()
            try? stderrHandle.close()
            _ = readers.wait(timeout: .now() + readerDrainGrace)
        }
        execution.clear(processID)
        return SSHProcessResult(
            status: didExit ? exitStatus : -1,
            stdout: stdoutCapture.data,
            stderr: String(decoding: stderrCapture.data, as: UTF8.self),
            timedOut: timedOut,
            wasCancelled: execution.isCancelled,
            outputLimitExceeded: stdoutCapture.limitExceeded)
    }

    private static func withCStringArray<Result>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        let pointers = strings.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        var terminated = pointers + [nil]
        return terminated.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }

    private static func waitForExit(
        _ processID: pid_t,
        until deadline: Date,
        status: inout Int32
    ) -> Bool {
        var waitStatus: Int32 = 0
        repeat {
            let result = waitpid(processID, &waitStatus, WNOHANG)
            if result == processID {
                let signal = waitStatus & 0x7f
                status = signal == 0 ? (waitStatus >> 8) & 0xff : signal
                return true
            }
            if result == -1, errno != EINTR {
                status = 127
                return true
            }
            usleep(10_000)
        } while Date() < deadline
        return false
    }
}

private final class SSHProcessExecution: @unchecked Sendable {
    private let lock = NSLock()
    private var processID: pid_t?
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func register(_ processID: pid_t) {
        let shouldTerminate = lock.withLock {
            self.processID = processID
            return cancelled
        }
        if shouldTerminate {
            terminate(processID, after: SSHProcessRunner.terminationGrace)
        }
    }

    func clear(_ processID: pid_t) {
        lock.withLock {
            if self.processID == processID { self.processID = nil }
        }
    }

    func cancel() {
        let processID = lock.withLock {
            cancelled = true
            return self.processID
        }
        if let processID {
            terminate(processID, after: SSHProcessRunner.terminationGrace)
        }
    }

    func terminate(after grace: TimeInterval) {
        let processID = lock.withLock { self.processID }
        if let processID { terminate(processID, after: grace) }
    }

    private func terminate(_ processID: pid_t, after grace: TimeInterval) {
        kill(-processID, SIGTERM)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + grace) { [weak self] in
            let shouldKill = self?.lock.withLock {
                guard self?.processID == processID else { return false }
                return kill(processID, 0) == 0 || errno == EPERM
            } ?? false
            if shouldKill { kill(-processID, SIGKILL) }
        }
    }
}

private final class PipeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var captured = Data()
    private var exceeded = false

    var data: Data { lock.withLock { captured } }
    var limitExceeded: Bool { lock.withLock { exceeded } }

    func drain(
        _ handle: FileHandle,
        limit: Int?,
        onLimitExceeded: (() -> Void)? = nil
    ) {
        var totalBytes = 0
        while let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty {
            totalBytes += chunk.count
            if let limit {
                let firstExcess = lock.withLock {
                    if captured.count < limit {
                        captured.append(chunk.prefix(limit - captured.count))
                    }
                    guard totalBytes > limit, !exceeded else { return false }
                    exceeded = true
                    return true
                }
                if firstExcess { onLimitExceeded?() }
            } else {
                lock.withLock { captured.append(chunk) }
            }
        }
    }
}
