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
        // A remote session runs on the VPS, so the Mac's cwd, PATH-laden env,
        // and shell path are all wrong there — hand the remote its own login
        // shell (empty spec) and let it set up its own environment. Local
        // sessions keep the full spec, unchanged.
        let remoteHost = Termiod.remoteHost
        let specification = remoteHost == nil
            ? Termiod.CreateSpecification(
                cwd: cwd,
                argv: argv,
                env: env.map { [$0.key, $0.value] },
                rows: UInt16(clamping: lastHostGridRows),
                cols: UInt16(clamping: lastHostGridColumns))
            : Termiod.CreateSpecification(
                cwd: "",
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
}
