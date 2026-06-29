import Darwin
import Foundation

/// Per-project sandbox configuration. Lives on `Project` (so it persists for free
/// via the existing `Codable` project store) and is the single source of truth the
/// per-project permissions panel edits.
///
/// The sandbox runs each session inside a lightweight Linux micro-VM (via the bundled
/// `termio-sandbox` helper). Permissions are mostly *which host paths are visible and
/// whether they are writable* — a deny-by-default the VM enforces for free: anything
/// not mounted is simply absent. Coarse network on/off and CPU/memory caps map to the
/// helper's flags. Domain-level egress allowlisting is intentionally deferred (it
/// needs the helper's HTTP/SOCKS proxy, a later milestone) rather than faked.
struct ContainerConfig: Codable, Hashable {
    /// A host directory exposed inside the VM beyond the project's own `/workspace`
    /// (a sibling repo, a shared cache, etc.).
    struct Mount: Codable, Hashable, Identifiable {
        var id = UUID()
        var hostPath: String
        var guestPath: String
        var readOnly: Bool
    }

    enum Network: String, Codable, Hashable {
        case off
        case full
    }

    /// The base OCI image for this project's VM. `nil` uses the helper's default. A
    /// project needing a specific toolchain sets its own image (later: a cached rootfs
    /// built from the project's install steps).
    var image: String?

    /// `/workspace` (the project directory) is mounted read-write by default — the
    /// agent's edits are meant to land in the real repo.
    var workspaceReadOnly: Bool = false

    var extraMounts: [Mount] = []

    var mountClaudeCredentials: Bool = true
    var mountCodexCredentials: Bool = true
    var mountSSH: Bool = false

    var network: Network = .full

    /// `nil` means "use the helper's default" rather than imposing a cap.
    var cpus: Int?
    var memoryGigabytes: Int?

    /// Because the VM caps the blast radius, skipping the agent's own approval prompts
    /// is a reasonable default *inside a sandbox*. Feeds `AgentPreset.permissionBypassFlag`.
    var skipAgentApprovals: Bool = true
}

/// Bridges the app to the bundled `termio-sandbox` helper — the entitled executable
/// that boots a Linux micro-VM and runs sessions inside it (see the helper's
/// `main.swift`). The app never links Apple's Containerization stack itself.
///
/// A VM project runs **one shared container** (not one VM per session): the first time
/// a session of the project needs it, the app spawns one long-lived `serve` daemon that
/// boots the container, installs the agent CLIs once, and listens on a unix socket.
/// Every session's libghostty `.exec` PTY then runs `attach`, which the daemon `exec`s
/// into the shared container. So libghostty stays oblivious that the other end of the
/// PTY lives in a VM, and the agents are installed once for the whole project.
@MainActor
final class ContainerManager {
    private let helperURL: URL?
    private let kernelURL: URL?

    /// The agent CLIs installed once into a project's container. They must be the Linux
    /// builds (claude bundles a per-platform native ripgrep, so the host's macOS install
    /// cannot be reused) — hence a one-time `npm install` inside the container.
    private static let agentInstallPackages =
        "@anthropic-ai/claude-code @openai/codex opencode-ai"

    /// The base image for a VM project whose config doesn't name one. It carries Node,
    /// which the agent CLIs need (a bare distro yields `claude: not found`).
    private static let defaultImage = "docker.io/library/node:22"

    /// One running `serve` daemon per VM-project, keyed by project. Killing the daemon
    /// process also tears down its in-process VM (the helper hosts the VM itself), so a
    /// `terminate()` is enough to stop the container.
    private struct Daemon {
        let process: Process
        let socketPath: String
        let workDirectory: URL
    }
    private var daemons: [Project.ID: Daemon] = [:]

    init() {
        // Both ship inside termio.app/Contents/Resources (placed there by
        // scripts/build-app.sh). Absent in a bare `swift run`, which simply means the
        // sandbox is unavailable and sessions fall back to the host.
        helperURL = Bundle.main.url(forResource: "termio-sandbox", withExtension: nil)
        kernelURL = Bundle.main.url(forResource: "vmlinux-arm64", withExtension: nil)
    }

    /// Whether a session can run sandboxed: the helper + kernel are bundled, on Apple
    /// silicon, on macOS 26 (what the VM/vmnet runtime requires). False anywhere else,
    /// so the caller transparently runs the session on the host instead.
    func isAvailable() -> Bool {
        guard #available(macOS 26, *) else { return false }
        #if arch(arm64)
        guard let helperURL, FileManager.default.isExecutableFile(atPath: helperURL.path) else { return false }
        return kernelURL != nil
        #else
        return false
        #endif
    }

    /// Ensures the project's shared-container daemon is running and returns the unix
    /// socket its sessions attach to, spawning the daemon on first use. Returns `nil`
    /// when the sandbox is unavailable (no helper bundled, not macOS 26, …), so the
    /// caller runs the session on the host instead.
    ///
    /// Booting the container, pulling the image, and installing the agents happen
    /// asynchronously inside the daemon; `attach` retries connecting to the socket until
    /// the daemon is listening, so the first session simply waits through the one-time
    /// preparation rather than this call blocking.
    func ensureDaemon(for project: Project) -> String? {
        guard let helperURL, let kernelURL, let config = project.container, isAvailable() else { return nil }

        if let existing = daemons[project.id], existing.process.isRunning {
            return existing.socketPath
        }

        // A short socket path under /tmp keeps it within the ~104-char sun_path limit
        // (the temp dir, where the log and staged credentials live, is far longer).
        let shortID = String(project.id.uuidString.prefix(8)).lowercased()
        let socketPath = "/tmp/termio-sandbox-\(shortID).sock"
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("termio-sandbox-\(shortID)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        var arguments = ["serve",
                         "--workspace", project.path,
                         "--kernel", kernelURL.path,
                         "--socket", socketPath,
                         "--image", config.image.flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultImage]
        if let cpus = config.cpus { arguments.append(contentsOf: ["--cpus", String(cpus)]) }
        if let memory = config.memoryGigabytes {
            arguments.append(contentsOf: ["--memory", String(memory * 1024)])
        }

        var prepareSteps: [String] = []
        for mount in credentialMounts(for: config, stagingIn: workDirectory, prepare: &prepareSteps) {
            arguments.append(contentsOf: ["--mount", mount])
        }
        for mount in config.extraMounts {
            let suffix = mount.readOnly ? ":ro" : ""
            arguments.append(contentsOf: ["--mount", "\(mount.hostPath):\(mount.guestPath)\(suffix)"])
        }

        // Install the agents, then copy any staged credential files into place. `; true`
        // keeps a missing optional credential from failing the whole preparation.
        let install = (["npm install -g \(Self.agentInstallPackages)"] + prepareSteps + ["true"])
            .joined(separator: "; ")
        arguments.append(contentsOf: ["--install", install])

        let process = Process()
        process.executableURL = helperURL
        process.arguments = arguments
        // Keep the daemon's diagnostics for inspection; a blank terminal during a slow
        // first boot is otherwise hard to explain.
        let logURL = workDirectory.appendingPathComponent("serve.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let log = try? FileHandle(forWritingTo: logURL) {
            process.standardOutput = log
            process.standardError = log
        }
        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(Data("termio: could not start the project sandbox: \(error)\n".utf8))
            return nil
        }
        daemons[project.id] = Daemon(process: process, socketPath: socketPath, workDirectory: workDirectory)
        return socketPath
    }

    /// The command a session's PTY runs to join the project's shared container: it
    /// connects to `socketPath` and the daemon `exec`s `agentCommand` (or a login shell
    /// when `nil`) inside the container, in `/workspace`.
    func attachCommand(socketPath: String, agentCommand: String?) -> String? {
        guard let helperURL else { return nil }
        var argv = [helperURL.path, "attach", "--socket", socketPath]
        if let agentCommand, !agentCommand.isEmpty {
            // Run through a login shell so a multi-word command with flags (e.g.
            // "claude --dangerously-skip-permissions") and PATH resolution work.
            argv.append(contentsOf: ["--", "/bin/sh", "-lc", agentCommand])
        }
        return argv.map(Self.shellQuote).joined(separator: " ")
    }

    /// Stops a project's container (and frees its socket / staging) when the project is
    /// closed. Terminating the helper process tears its in-process VM down with it.
    func teardown(projectID: Project.ID) {
        guard let daemon = daemons.removeValue(forKey: projectID) else { return }
        if daemon.process.isRunning { daemon.process.terminate() }
        unlink(daemon.socketPath)
        try? FileManager.default.removeItem(at: daemon.workDirectory)
    }

    /// Stops every project container — called when the app quits, so no helper VM
    /// outlives the app.
    func teardownAll() {
        for id in Array(daemons.keys) { teardown(projectID: id) }
    }

    /// Builds the `--mount` specs that carry the user's agent credentials into the
    /// container, and the boot steps that finish placing them.
    ///
    /// `Mount.share` is virtiofs (a directory export), so credential *directories*
    /// (`~/.claude`, `~/.codex`) mount straight across, but the lone `~/.claude.json`
    /// file cannot be a mount source. It is instead staged into a directory that mounts
    /// read-only, and a boot step copies it into `/root`. Credentials are plain portable
    /// text, so this saves the user re-authenticating inside every sandbox.
    ///
    /// Crucially the sandbox never mounts the *live* credential directory: a sandboxed
    /// agent must not be able to scribble into the user's real `~/.claude` (history,
    /// tokens). Each directory is mounted as a copy-on-write clone instead (see
    /// `cloneCopyOnWrite`), so the agent reads the real credentials and writes its own
    /// session state into the clone, leaving the host's untouched.
    private func credentialMounts(for config: ContainerConfig,
                                  stagingIn workDirectory: URL,
                                  prepare: inout [String]) -> [String] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        var mounts: [String] = []

        func mountClonedDirectoryIfPresent(_ relativePath: String, cloneName: String, to guestPath: String) {
            let source = home.appendingPathComponent(relativePath)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return }
            let clone = workDirectory.appendingPathComponent(cloneName, isDirectory: true)
            guard cloneCopyOnWrite(from: source, to: clone) else {
                // Couldn't clone (e.g. across volumes): skip rather than expose the live
                // directory to the sandbox's writes.
                FileHandle.standardError.write(
                    Data("termio: could not clone \(relativePath) for the sandbox; skipping it\n".utf8))
                return
            }
            mounts.append("\(clone.path):\(guestPath)")
        }

        if config.mountClaudeCredentials {
            mountClonedDirectoryIfPresent(".claude", cloneName: "claude", to: "/root/.claude")
            // The single-file ~/.claude.json holds the account/session; stage a copy so
            // it can ride in on a directory mount (and so the agent's writes stay off the
            // host original).
            let claudeJSON = home.appendingPathComponent(".claude.json")
            if fileManager.fileExists(atPath: claudeJSON.path) {
                let stagedHome = workDirectory.appendingPathComponent("host-home", isDirectory: true)
                try? fileManager.createDirectory(at: stagedHome, withIntermediateDirectories: true)
                let staged = stagedHome.appendingPathComponent(".claude.json")
                try? fileManager.removeItem(at: staged)
                if (try? fileManager.copyItem(at: claudeJSON, to: staged)) != nil {
                    mounts.append("\(stagedHome.path):/root/.host-home:ro")
                    prepare.append("cp -f /root/.host-home/.claude.json /root/.claude.json 2>/dev/null")
                }
            }
        }
        if config.mountCodexCredentials {
            mountClonedDirectoryIfPresent(".codex", cloneName: "codex", to: "/root/.codex")
        }
        if config.mountSSH {
            mountClonedDirectoryIfPresent(".ssh", cloneName: "ssh", to: "/root/.ssh")
        }
        return mounts
    }

    /// Makes an APFS copy-on-write clone of `source` at `destination` via `clonefile(2)`:
    /// instant and block-shared until written, so cloning even a multi-gigabyte
    /// `~/.claude` costs nothing up front. Unlike `FileManager.copyItem` (a full byte
    /// copy) this is what makes per-sandbox credential isolation cheap. Returns `false`
    /// when the clone can't be made (notably across volumes, where `clonefile` fails),
    /// so the caller can refuse rather than fall back to the live directory.
    private func cloneCopyOnWrite(from source: URL, to destination: URL) -> Bool {
        try? FileManager.default.removeItem(at: destination)
        return source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                clonefile(sourcePath, destinationPath, 0) == 0
            }
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
