import AppKit
import Foundation
import GhosttyTerminal

/// The flag-on (`TERMIO_TERMIOD=1`) session plumbing: sessions run inside the
/// local termiod daemon and the app is an attach client. Kept beside the
/// protocol client so the whole opt-in backend lives in one folder; the
/// default `PTYProcess` path is untouched when the flag is off.
extension TermioStore {
    /// Builds the attach channel for a session about to be surfaced. The
    /// termiod session is *named* with the app session's stable UUID, which is
    /// what makes relaunch reattachment work: `attach` with
    /// `create_if_missing` resolves the name first, so a session that survived
    /// the last app quit is rejoined — same process, same pid — and only a
    /// session with no live counterpart spawns fresh.
    func makeTermiodLink(for session: Session, argv: [String], cwd: String,
                         env: [String: String]) -> TermiodSessionLink {
        // The remote host is per-session (the `+` ▸ New Remote Terminal picker
        // and "Clone on Remote…" set `session.termiodRemoteHost`), with the old
        // single-host `TERMIO_TERMIOD_REMOTE` env kept only as a fallback default
        // so an env-configured demo host still works when no session sets one.
        let remoteHost = session.termiodRemoteHost ?? Termiod.remoteHost
        // A remote session runs on the VPS, so the Mac's cwd, PATH-laden env,
        // and shell path are all wrong there — hand the remote its own login
        // shell (empty argv/env) and let it set up its own environment. The one
        // thing that *does* travel is the remote cwd, when the caller chose one
        // (a cloned repo directory): the remote daemon `cd`s there before the
        // shell, so the terminal opens inside it. Local sessions keep the full
        // spec, unchanged.
        let specification = remoteHost == nil
            ? Termiod.CreateSpecification(
                cwd: cwd,
                argv: argv,
                env: env.map { [$0.key, $0.value] },
                rows: UInt16(clamping: lastHostGridRows),
                cols: UInt16(clamping: lastHostGridColumns))
            : Termiod.CreateSpecification(
                cwd: session.termiodRemoteCwd ?? "",
                argv: [],
                env: [],
                rows: UInt16(clamping: lastHostGridRows),
                cols: UInt16(clamping: lastHostGridColumns))
        return TermiodSessionLink(
            sessionName: session.id.uuidString,
            specification: specification,
            remoteHost: remoteHost,
            rows: lastHostGridRows,
            cols: lastHostGridColumns
        )
    }

    /// Wires the channel to the surface and registers it. Output enters the
    /// surface through `InMemoryTerminalSession.receive` — the same seam the
    /// in-process PTY read pump feeds — so there is exactly one render path.
    func attachTermiodLink(_ link: TermiodSessionLink,
                           to inMemory: InMemoryTerminalSession,
                           for session: Session) {
        let isAgentSession = session.agent != .terminal && !session.isSSH
        link.onOutput = { [weak inMemory] data in inMemory?.receive(data) }
        link.onExit = { [weak self, weak inMemory] code, runtimeMilliseconds in
            self?.termiodLinks[session.id] = nil
            self?.lastScreenActivity[session.id] = nil
            // Mirrors the PTYProcess exit policy, minus the self-update
            // binary-replaced check (the daemon owns the process, so the app
            // cannot pin its executable): a clean agent quit hands the pane
            // back to a shell; everything else parks on the exit prompt, and
            // a clean plain-terminal exit closes the pane.
            if isAgentSession, code == 0 {
                self?.revertSessionToShell(session.id)
                return
            }
            inMemory?.finish(exitCode: UInt32(bitPattern: code),
                             runtimeMilliseconds: runtimeMilliseconds)
            if session.agent == .terminal, code == 0 {
                self?.closeSession(session.id)
            }
        }
        termiodLinks[session.id] = link
        link.start()
    }

    /// Startup roster check over a control-role channel: which persisted
    /// sessions have a live counterpart in the daemon (and will therefore
    /// reattach when surfaced) versus which will spawn fresh. Purely
    /// diagnostic — the attach-by-name above is what actually decides.
    func logTermiodRoster() {
        let persistedNames = Set(projects.flatMap { project in
            project.sessions.map { $0.id.uuidString }
        })
        DispatchQueue.global(qos: .utility).async {
            do {
                let live = try Termiod.listSessions(host: Termiod.remoteHost)
                for information in live where information.alive {
                    let verdict = persistedNames.contains(information.name)
                        ? "will reattach" : "no matching app session"
                    Log.termiod.info("""
                    live termiod session name=\(information.name, privacy: .public) \
                    pid=\(information.pid, privacy: .public) — \(verdict, privacy: .public)
                    """)
                }
                if live.isEmpty {
                    Log.termiod.info("no live termiod sessions at startup")
                }
            } catch {
                Log.termiod.error("""
                startup roster list failed: \
                \(error.localizedDescription, privacy: .public)
                """)
            }
        }
    }

    // MARK: - Remote terminals (per-session SSH host)

    /// Opens a **remote terminal** on `host`: a `.terminal` session whose termiod
    /// link runs on that SSH box (`session.termiodRemoteHost`), so the shell lives
    /// on the remote and the Mac attaches over `ssh <host> termiod stdio`. Unlike
    /// `addSSHSession` (a plain `ssh <host>` in a *local* PTY), this is the durable
    /// termiod path — detach-not-kill and snapshot repaint carry across the network.
    ///
    /// The whole feature depends on the opt-in daemon backend, so with the flag off
    /// it surfaces a clear message rather than silently opening a broken pane. The
    /// remote must have `termiod` installed; `ensureRemoteReady` deploys it if
    /// missing (off the main thread, with progress) before the session is created —
    /// otherwise the first `termiod stdio` over SSH would fail and the pane would
    /// sit dead.
    ///
    /// `cwd` (used by "Clone on Remote…") is the remote directory the shell spawns
    /// in; `title` overrides the sidebar label (the host alias by default, or a
    /// repo name for a clone).
    func addRemoteTerminal(host: String, cwd: String? = nil, title: String? = nil) {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        guard Termiod.isEnabled else {
            presentTermiodDisabledAlert()
            return
        }
        ensureRemoteReady(host: host) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.createRemoteTerminalSession(host: host, cwd: cwd, title: title)
            case .failure(let error):
                self.presentRemoteSetupFailure(host: host, message: error.message)
            }
        }
    }

    /// Creates the remote `.terminal` session in the Terminals funnel (a remote
    /// terminal isn't tied to a local project, same as `addSSHSession`), tagging it
    /// with the per-session remote host + cwd that `makeTermiodLink` threads through.
    private func createRemoteTerminalSession(host: String, cwd: String?, title: String?) {
        var session = Session(title: title ?? host, agent: .terminal)
        session.termiodRemoteHost = host
        session.termiodRemoteCwd = cwd

        if let index = projects.firstIndex(where: { $0.kind == .terminals }) {
            projects[index].sessions.append(session)
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
            projects.append(Project(
                name: "Terminals", path: home, branch: "—",
                sessions: [session], kind: .terminals
            ))
        }
        selectedSessionID = session.id
    }

    /// A remote-setup outcome carrying a human message on failure (host
    /// unreachable, deploy failed) so the caller can show exactly what went wrong.
    enum RemoteSetupResult {
        case success
        case failure(RemoteSetupError)
    }

    struct RemoteSetupError {
        let message: String
    }

    /// Ensures `host` has `termiod` deployed before an attach — the same
    /// idempotent check the CLI's `remote open` runs (`test -x ~/.local/bin/termiod`,
    /// deploy if absent, see termiod/src/remote.rs). Runs off the main thread with a
    /// borderless "Setting up host…" HUD; `completion` fires back on the main queue.
    /// The deploy step shells out to the *local* `termiod remote deploy <host>`
    /// (which cross-compiles + scps), so the app never re-implements the deploy.
    func ensureRemoteReady(host: String, completion: @escaping (RemoteSetupResult) -> Void) {
        let hud = RemoteSetupHUD(message: "Setting up \(host)…")
        hud.show()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.performRemoteReadyCheck(host: host)
            DispatchQueue.main.async {
                hud.dismiss()
                completion(result)
            }
        }
    }

    /// The blocking half of `ensureRemoteReady`, run off-main. Probes for the
    /// remote binary and, when missing, invokes the local `termiod remote deploy`.
    /// `nonisolated` because it is invoked from a background queue and touches only
    /// process/filesystem primitives — never `TermioStore`'s main-actor state.
    private nonisolated static func performRemoteReadyCheck(host: String) -> RemoteSetupResult {
        // A quick reachability + presence probe. `BatchMode=yes` keeps it from
        // hanging on a password prompt (the user's key/agent must already work,
        // exactly as `ssh <host>` in a plain terminal would need). The remote path
        // mirrors `Termiod.remoteBinary()` (`$HOME/.local/bin/termiod`).
        let probe = runProcess(
            "/usr/bin/ssh",
            ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host,
             "test -x $HOME/.local/bin/termiod && echo yes || echo no"]
        )
        guard let probe else {
            return .failure(RemoteSetupError(message: "Couldn't run ssh to reach \(host)."))
        }
        if probe.exitCode != 0 {
            // A non-zero ssh exit before our echo means the connection or auth
            // failed — surface ssh's own last line, which names the cause.
            let detail = probe.standardError
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .last(where: { !$0.isEmpty }) ?? "Connection failed"
            return .failure(RemoteSetupError(
                message: "Couldn't reach \(host) over SSH.\n\(detail)"))
        }
        if probe.standardOutput.contains("yes") {
            return .success // Already deployed — the common case after first use.
        }

        // Missing: deploy via the local termiod binary's `remote deploy`, which
        // cross-compiles the aarch64-musl daemon and scps it (termiod/DEPLOY.md).
        let localBinary = Termiod.daemonBinaryPath()
        guard FileManager.default.isExecutableFile(atPath: localBinary) else {
            return .failure(RemoteSetupError(
                message: "termiod isn't deployed on \(host), and the local termiod "
                    + "binary to deploy it wasn't found at \(localBinary)."))
        }
        let deploy = runProcess(localBinary, ["remote", "deploy", host])
        guard let deploy, deploy.exitCode == 0 else {
            let detail = deploy.map { output in
                (output.standardError + output.standardOutput)
                    .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                    .last(where: { !$0.isEmpty }) ?? "deploy failed"
            } ?? "couldn't run termiod remote deploy"
            return .failure(RemoteSetupError(
                message: "Couldn't deploy termiod to \(host).\n\(detail)"))
        }
        return .success
    }

    /// A captured subprocess result — exit code plus drained stdout/stderr.
    private struct ProcessOutput {
        let exitCode: Int32
        let standardOutput: String
        let standardError: String
    }

    /// Runs `executable args`, draining both pipes before waiting so neither can
    /// deadlock on a full buffer. `nil` only when the process couldn't launch.
    /// `nonisolated` so the off-main `performRemoteReadyCheck` can call it.
    private nonisolated static func runProcess(_ executable: String, _ args: [String]) -> ProcessOutput? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return nil }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessOutput(
            exitCode: process.terminationStatus,
            standardOutput: String(data: outData, encoding: .utf8) ?? "",
            standardError: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    /// The flag-off explainer: the remote feature is entirely the termiod backend,
    /// so without `TERMIO_TERMIOD=1` there's nothing to attach to.
    private func presentTermiodDisabledAlert() {
        let alert = NSAlert()
        alert.messageText = "Remote terminals need the termiod backend"
        alert.informativeText = "Set TERMIO_TERMIOD=1 and relaunch termio to open sessions on a remote host."
        alert.alertStyle = .informational
        alert.runModal()
    }

    /// A remote setup/clone failure, shown verbatim so the cause (unreachable,
    /// auth, deploy) is visible rather than a silently dead pane.
    func presentRemoteSetupFailure(host: String, message: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't set up \(host)"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

/// A small borderless "Setting up host…" panel shown while a remote deploy/clone
/// runs off the main thread — a spinner plus one line, centered on the key window.
/// Not an `NSAlert` (which is modal and would block the runloop the work reports
/// back on); a floating panel that the completion handler dismisses.
@MainActor
final class RemoteSetupHUD {
    private let panel: NSPanel
    private let message: String

    init(message: String) {
        self.message = message
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 84),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered, defer: true
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
    }

    func show() {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.startAnimation(nil)
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: message)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = panel.contentView ?? NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        panel.center()
        panel.orderFrontRegardless()
    }

    func dismiss() {
        panel.orderOut(nil)
    }
}
