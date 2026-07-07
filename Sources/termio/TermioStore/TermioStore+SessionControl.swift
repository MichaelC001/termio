import Foundation
import GhosttyKit
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
            let state = surface(for: session, in: project)

            // The libghostty surface attaches lazily on the pane's first render, so a
            // session never shown in the UI has no surface yet. Selecting it adds it to
            // the mounted set; give the render one cycle. (A session shown even once
            // stays mounted, so this only foregrounds on the very first drive.)
            if state.surface == nil {
                selectedSessionID = session.id
                try? await Task.sleep(for: .milliseconds(400))
            }
            guard let surfaceHandle = Self.rawSurface(from: state) else {
                return controlError(request, "not_live",
                    "\(displayTitle(for: session)) has no live terminal yet — open it once in termio.")
            }

            // Type the prompt through the text path (fine for the body), then submit
            // with a real Return *key event*. A trailing "\r" in the text is delivered
            // as a bracketed paste, which an agent TUI (Claude Code) reads as a newline
            // — never a submit. `ghostty_surface_key` drives the surface directly, with
            // no focus or first-responder needed; this is exactly how Ghostty's own
            // AppleScript `send key` submits Enter.
            _ = state.send(payload)
            try? await Task.sleep(for: .milliseconds(40))
            Self.pressReturn(on: surfaceHandle)
            return sentReply(request, session)
        case .notFound:
            return controlError(request, "not_found", targetNotFoundMessage(request.target))
        case .ambiguous:
            return controlError(request, "ambiguous",
                "'\(request.target ?? "")' matches more than one session; use a longer id.")
        }
    }

    /// The raw `ghostty_surface_t` behind a session's surface. `TerminalSurface`
    /// exposes only `sendText` publicly and keeps the C handle in a private stored
    /// property, so reach it by reflection — the only way to call `ghostty_surface_key`
    /// (the key-event C entry point, whose Swift wrapper the package marks `internal`).
    private static func rawSurface(from state: TerminalViewState) -> ghostty_surface_t? {
        guard let terminalSurface = state.surface else { return nil }
        for child in Mirror(reflecting: terminalSurface).children where child.label == "surface" {
            if let handle = child.value as? ghostty_surface_t { return handle }
        }
        return nil
    }

    /// Sends a Return key press (and release) to the surface — the submit a user makes
    /// by pressing Enter. `keycode` is the native macOS virtual key for Return
    /// (`kVK_Return`, 0x24) and `text` is left nil so Ghostty's own key encoder emits
    /// the correct bytes for whatever keyboard mode the program negotiated.
    private static func pressReturn(on surface: ghostty_surface_t) {
        var event = ghostty_input_key_s()
        event.action = GHOSTTY_ACTION_PRESS
        event.mods = GHOSTTY_MODS_NONE
        event.consumed_mods = GHOSTTY_MODS_NONE
        event.keycode = 0x24
        event.text = nil
        event.unshifted_codepoint = 0
        event.composing = false
        _ = ghostty_surface_key(surface, event)
        event.action = GHOSTTY_ACTION_RELEASE
        _ = ghostty_surface_key(surface, event)
    }

    /// The success reply for a send/answer. Beyond confirming delivery, it hands back
    /// the session's transcript address and a cursor (its line count at send time), so
    /// the caller can read the agent's response straight from its own structured log —
    /// `read`, or the caller's own file tools, resume from `cursor`. The transcript is
    /// known only once a hook has reported it (Claude Code), so it's omitted otherwise.
    private func sentReply(_ request: ControlRequest, _ session: Session) -> Data {
        var json: [String: Any] = [
            "target": Self.shortID(session.id),
            "title": displayTitle(for: session),
        ]
        var text = "sent to \(displayTitle(for: session))"
        if let transcript = transcriptPaths[session.id] {
            let cursor = Self.lineCount(of: transcript)
            json["transcript"] = transcript
            json["cursor"] = cursor
            text += "\n  transcript: \(transcript)\n  cursor: \(cursor)  (read the response from here on)"
        }
        return control(request, ok: true, text: text, json: json)
    }

    /// Lines currently in a file, counted cheaply by newline bytes — the cursor a
    /// caller resumes a transcript read from.
    private static func lineCount(of path: String) -> Int {
        guard let data = FileManager.default.contents(atPath: path) else { return 0 }
        return data.reduce(into: 0) { count, byte in if byte == 0x0A { count += 1 } }
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
