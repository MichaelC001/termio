import Foundation
import JSONRPC
import LanguageClient
import LanguageServerProtocol
import ProcessEnv

/// One language server per (project root, server id), spawned lazily the first time the editor
/// opens a matching file and kept for the rest of the app run — an idle server is cheap, and
/// reusing it is what makes cross-file jumps instant. A server that dies is marked dead for the
/// run (no restart machinery): the feature quietly vanishes for that root instead of flapping.
@MainActor
final class LSPManager {
    static let shared = LSPManager()

    private struct Key: Hashable {
        let root: String
        let serverID: String
    }

    private var servers: [Key: InitializingServer] = [:]
    /// The child processes, kept for the synchronous quit path — `applicationWillTerminate`
    /// can't await a polite LSP shutdown, but it can close the stdio and terminate.
    private var processes: [Key: Process] = [:]
    /// Keys whose exit we caused (quit teardown), so the termination handler doesn't
    /// misread it as a crash.
    private var expectedExits: Set<Key> = []
    private var dead: Set<Key> = []
    /// In-flight spawns, so two editors opening at once share one server instead of racing
    /// two children into existence.
    private var pending: [Key: Task<InitializingServer?, Never>] = [:]

    private init() {}

    /// The running (or newly spawned) server for `fileURL`, with the language id to announce it
    /// under and the workspace root it was initialized with. `nil` when no registered server owns
    /// the extension, its binary isn't installed, or it already crashed this run.
    func server(for fileURL: URL) async -> (server: InitializingServer, languageID: String, root: URL)? {
        guard let (descriptor, languageID) = LSPRegistry.descriptor(for: fileURL) else { return nil }
        let root = Self.workspaceRoot(for: fileURL)
        let key = Key(root: root.path, serverID: descriptor.id)
        if dead.contains(key) { return nil }
        if let existing = servers[key] { return (existing, languageID, root) }

        if pending[key] == nil {
            pending[key] = Task { await self.start(descriptor, root: root, key: key) }
        }
        let task = pending[key]!
        let server = await task.value
        pending[key] = nil
        return server.map { ($0, languageID, root) }
    }

    /// The workspace a file belongs to: its git root, or its own directory outside a repo —
    /// the same walk the editor header uses for the repo-relative path.
    static func workspaceRoot(for url: URL) -> URL {
        let file = url.standardizedFileURL
        var dir = file.deletingLastPathComponent()
        var candidate = dir
        while candidate.path != "/" {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent(".git").path) {
                dir = candidate
                break
            }
            candidate = candidate.deletingLastPathComponent()
        }
        return dir
    }

    private func start(_ descriptor: LSPServerDescriptor, root: URL, key: Key) async -> InitializingServer? {
        guard let launch = await LSPRegistry.resolveLaunch(descriptor.command) else {
            Log.lsp.info("\(descriptor.id, privacy: .public): binary not on PATH, feature off")
            return nil
        }
        // The login-shell PATH goes into the child too, so a server that shells out to its
        // toolchain (gopls → go) finds it despite the app's own minimal Finder PATH.
        var environment = ProcessInfo.processInfo.environment
        let directories = await AgentAvailability.pathDirectories()
        if !directories.isEmpty { environment["PATH"] = directories.joined(separator: ":") }

        let parameters = Process.ExecutionParameters(
            path: launch.binary,
            arguments: launch.arguments,
            environment: environment,
            currentDirectoryURL: root
        )
        let pair: (channel: DataChannel, process: Process)
        do {
            pair = try DataChannel.localProcessChannel(parameters: parameters) {
                Task { @MainActor in LSPManager.shared.processDidExit(key) }
            }
        } catch {
            Log.lsp.error("\(descriptor.id, privacy: .public) failed to launch: \(String(describing: error), privacy: .public)")
            dead.insert(key)
            return nil
        }

        let connection = JSONRPCServerConnection(dataChannel: pair.channel)
        let rootURI = root.absoluteString
        let server = InitializingServer(server: connection) {
            InitializeParams(
                processId: Int(ProcessInfo.processInfo.processIdentifier),
                clientInfo: .init(name: "termio"),
                locale: nil,
                rootPath: root.path,
                rootUri: rootURI,
                initializationOptions: nil,
                capabilities: ClientCapabilities(
                    workspace: nil,
                    textDocument: TextDocumentClientCapabilities(
                        hover: HoverClientCapabilities(
                            dynamicRegistration: false, contentFormat: [.markdown, .plaintext]
                        ),
                        definition: .init(dynamicRegistration: false, linkSupport: true)
                    ),
                    window: nil,
                    general: nil,
                    experimental: nil
                ),
                trace: nil,
                workspaceFolders: [WorkspaceFolder(uri: rootURI, name: root.lastPathComponent)]
            )
        }
        servers[key] = server
        processes[key] = pair.process
        Log.lsp.info("\(descriptor.id, privacy: .public) started for \(root.path, privacy: .public)")
        return server
    }

    private func processDidExit(_ key: Key) {
        servers[key] = nil
        processes[key] = nil
        if expectedExits.remove(key) != nil { return }
        dead.insert(key)
        Log.lsp.error("\(key.serverID, privacy: .public) exited for \(key.root, privacy: .public) — off for this run")
    }

    /// The quit path: synchronous, so it can run inside `applicationWillTerminate`. Closing the
    /// child's stdio (terminate) is enough — every LSP server exits on a broken pipe, and the
    /// polite shutdown/exit handshake has nothing left to protect at app quit.
    func terminateAll() {
        for (key, process) in processes {
            expectedExits.insert(key)
            process.terminate()
        }
        processes.removeAll()
        servers.removeAll()
    }
}
