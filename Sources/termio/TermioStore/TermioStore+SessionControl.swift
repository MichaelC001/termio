import Foundation
import GhosttyTerminal

/// Handles `termio sessions …` requests from `SessionControlListener`. Every
/// operation is scoped to the caller's own project (resolved from the caller's
/// `TERMIO_SESSION` or, failing that, its working directory) so an agent can only
/// see and drive its siblings, never sessions in unrelated projects — unpeel's
/// "project-scoped by default" rule.
extension TermioStore {
    func handleSessionControl(_ request: ControlRequest) async -> Data {
        guard settings.sessionControlEnabled else {
            return controlError(request, "disabled",
                "Session control is off. Enable it in termio ▸ Settings ▸ Agents.")
        }
        guard let project = callerProject(session: request.callerSession, cwd: request.callerCwd) else {
            return controlError(request, "no_scope",
                "Couldn't tell which project you're in. Run this from inside a termio session.")
        }

        switch request.op {
        case "list": return listSessions(in: project, request: request)
        case "send", "answer": return await sendText(request, in: project)
        case "start": return startSession(request, in: project)
        case "stop": return stopSession(request, in: project)
        case "read":
            return controlError(request, "read_unavailable",
                "Reading a session's output isn't available in this build yet — it needs a "
                + "terminal-core buffer API. list / send / answer / start / stop work today.")
        default:
            return controlError(request, "bad_op", "Unknown op '\(request.op)'.")
        }
    }

    private func listSessions(in project: Project, request: ControlRequest) -> Data {
        let entries = project.sessions.map { session -> [String: Any] in
            [
                "id": Self.shortID(session.id),
                "title": displayTitle(for: session),
                "agent": session.agent.displayName,
                "status": Self.statusToken(status(for: session.id)),
                "description": statusDescription(for: session.id),
            ]
        }
        let lines = project.sessions.map { session -> String in
            let token = Self.statusToken(status(for: session.id))
            let description = statusDescription(for: session.id)
            let suffix = description.isEmpty ? "" : "  — \(description)"
            return "\(Self.shortID(session.id))  [\(token)]  \(displayTitle(for: session)) "
                + "(\(session.agent.displayName))\(suffix)"
        }
        let header = "\(project.name) — \(project.sessions.count) session(s)"
        let text = ([header] + lines).joined(separator: "\n")
        return control(request, ok: true, text: text, json: ["project": project.name, "sessions": entries])
    }

    private func sendText(_ request: ControlRequest, in project: Project) async -> Data {
        guard let payload = request.text, !payload.isEmpty else {
            return controlError(request, "no_text", "\(request.op) needs text to send.")
        }
        switch resolveTarget(request.target, in: project) {
        case .found(let session):
            // Get-or-create the surface so a prompt can be sent to a session that
            // hasn't been opened yet (this starts its shell, which is what we want).
            let surface = surface(for: session, in: project)
            if await deliver(payload, to: surface) {
                return sentReply(request, session)
            }

            // Delivery fails only when the libghostty surface isn't attached yet — a
            // session whose pane has never been shown, so its view never mounted.
            // Mounting requires it to be the selected pane: select it, give the
            // SwiftUI render + surface attach one cycle, then retry once. This is
            // the same recovery `TerminalPane.sendPaths` uses for dropped files.
            selectedSessionID = session.id
            try? await Task.sleep(for: .milliseconds(350))
            guard await deliver(payload, to: surface) else {
                return controlError(request, "not_live",
                    "\(displayTitle(for: session)) has no live terminal yet — open it once in termio.")
            }
            return sentReply(request, session)
        case .notFound:
            return controlError(request, "not_found", targetNotFoundMessage(request.target))
        case .ambiguous:
            return controlError(request, "ambiguous",
                "'\(request.target ?? "")' matches more than one session; use a longer id.")
        }
    }

    /// Types `text` into the surface, then sends Return as a *separate* write a
    /// beat later. The split matters: `TerminalViewState.send` routes through
    /// libghostty's text path (`ghostty_surface_text`), and an agent TUI like
    /// Claude Code treats a single burst that ends in `\r` as a pasted newline —
    /// it inserts a line break instead of submitting. Delivering the `\r` on its
    /// own, after a gap, makes it read as a discrete Enter keypress, which submits.
    /// Returns false when the surface has no live terminal attached yet (caller
    /// then mounts and retries).
    private func deliver(_ text: String, to surface: TerminalViewState) async -> Bool {
        guard surface.send(text) else { return false }
        try? await Task.sleep(for: .milliseconds(120))
        return surface.send("\r")
    }

    /// The success reply shared by the first-try and post-mount-retry send paths.
    private func sentReply(_ request: ControlRequest, _ session: Session) -> Data {
        control(request, ok: true,
            text: "sent to \(displayTitle(for: session))",
            json: ["target": Self.shortID(session.id), "title": displayTitle(for: session)])
    }

    private func startSession(_ request: ControlRequest, in project: Project) -> Data {
        guard let preset = AgentPreset.resolve(request.agent) else {
            let names = AgentPreset.allCases.map(\.rawValue).joined(separator: ", ")
            return controlError(request, "bad_agent",
                "Unknown agent '\(request.agent ?? "")'. Try one of: \(names).")
        }
        addSession(to: project.id, agent: preset)
        guard let id = selectedSessionID, let session = self.session(id) else {
            return controlError(request, "start_failed", "Could not start the session.")
        }
        return control(request, ok: true,
            text: "started \(displayTitle(for: session)) (\(Self.shortID(id)))",
            json: ["id": Self.shortID(id), "title": displayTitle(for: session),
                   "agent": session.agent.displayName])
    }

    private func stopSession(_ request: ControlRequest, in project: Project) -> Data {
        switch resolveTarget(request.target, in: project) {
        case .found(let session):
            let title = displayTitle(for: session)
            closeSession(session.id)
            return control(request, ok: true, text: "stopped \(title)", json: ["title": title])
        case .notFound:
            return controlError(request, "not_found", targetNotFoundMessage(request.target))
        case .ambiguous:
            return controlError(request, "ambiguous",
                "'\(request.target ?? "")' matches more than one session; use a longer id.")
        }
    }

    /// Resolves the calling agent to its project: by the `TERMIO_SESSION` the PTY
    /// carries (exact), else by a working directory that sits inside a project's
    /// directory or one of its session worktrees (the fallback for a plain shell).
    private func callerProject(session id: String?, cwd: String?) -> Project? {
        if let id, let uuid = UUID(uuidString: id), let project = project(for: uuid) {
            return project
        }
        guard let cwd else { return nil }
        let target = URL(fileURLWithPath: cwd).standardizedFileURL.path
        func contains(_ directory: String) -> Bool {
            let base = URL(fileURLWithPath: directory).standardizedFileURL.path
            return target == base || target.hasPrefix(base + "/")
        }
        // A session worktree is the most specific match, so prefer it.
        for project in projects {
            for session in project.sessions where session.worktreePath.map(contains) == true {
                return project
            }
        }
        return projects.first { contains($0.path) }
    }

    private enum TargetResolution {
        case found(Session)
        case notFound
        case ambiguous
    }

    /// Matches a target token within the caller's project by full id, id prefix, or
    /// title (case-insensitive). Ambiguity is reported rather than guessed.
    private func resolveTarget(_ token: String?, in project: Project) -> TargetResolution {
        guard let token = token?.trimmingCharacters(in: .whitespaces).lowercased(), !token.isEmpty else {
            return .notFound
        }
        // Match the *displayed* title only, never the stored one: `list` shows the
        // display title (terminals are re-indexed live), so that's what an agent
        // references. The stored title is an internal worktree-slug seed and can
        // collide with another session's display title — matching it would make an
        // unambiguous name read as ambiguous.
        let matches = project.sessions.filter { session in
            let id = session.id.uuidString.lowercased()
            return id == token
                || id.hasPrefix(token)
                || displayTitle(for: session).lowercased() == token
        }
        switch matches.count {
        case 0: return .notFound
        case 1: return .found(matches[0])
        default: return .ambiguous
        }
    }

    private func targetNotFoundMessage(_ token: String?) -> String {
        "No session '\(token ?? "")' in this project. Run `termio sessions list` to see ids."
    }

    private func control(_ request: ControlRequest, ok: Bool, text: String, json: [String: Any]) -> Data {
        if request.wantsJSON {
            var object = json
            object["ok"] = ok
            let data = (try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
            return data + Data("\n".utf8)
        }
        return Data((text.hasSuffix("\n") ? text : text + "\n").utf8)
    }

    private func controlError(_ request: ControlRequest, _ code: String, _ message: String) -> Data {
        control(request, ok: false, text: "error: \(message)", json: ["error": code, "message": message])
    }

    private static func shortID(_ id: Session.ID) -> String {
        String(id.uuidString.prefix(8)).lowercased()
    }

    private static func statusToken(_ status: SessionStatus) -> String {
        switch status {
        case .idle: return "idle"
        case .working: return "working"
        case .done: return "done"
        case .needsAttention: return "needs-you"
        }
    }
}
