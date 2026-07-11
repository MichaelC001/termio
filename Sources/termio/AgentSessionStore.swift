import Foundation

/// Discovers the conversation id that an agent which can't be handed one up front
/// (Codex, OpenCode) created for a session, so a relaunch can resume that *exact*
/// session by id rather than just continuing whatever ran last in the directory.
///
/// Neither CLI accepts a session id at launch, so the id is learned afterward: termio
/// records when it launched the agent (`Session.launchedAt`) and then matches the
/// agent's own session record by (a) working directory and (b) the file's creation
/// time. Creation time is read from the *filesystem* — the same system clock as
/// `launchedAt`, and (unlike modification time) it doesn't move as the conversation
/// grows — so the record created right when we launched is the one we bind to.
///
/// This reads each agent's *private* on-disk layout (Codex's `~/.codex/sessions`
/// rollout files, OpenCode's `~/.local/share/opencode/opencode.db` SQLite store),
/// which is undocumented and can change between agent versions. Every read is
/// therefore best-effort: any miss returns `nil`, and the caller falls back to
/// continuing the most recent session in the directory.
enum AgentSessionStore {
    static func discover(agent: AgentPreset, directory: String, after launchedAt: Date?) -> String? {
        guard let launchedAt else { return nil }
        if agent == .codex {
            return matchCodex(directory: directory, after: launchedAt)?.id
        }
        if agent == .opencode {
            return matchOpenCode(directory: directory, after: launchedAt, newest: false)
        }
        return nil
    }

    /// The on-disk conversation transcript for an agent that doesn't hand termio a
    /// transcript path through its hooks the way Claude Code does. Codex writes a
    /// rollout JSONL per session under `~/.codex/sessions`; that file *is* the
    /// transcript, so the Info pane can render a trace from it. Returns the file path,
    /// or `nil` when none matches (yet) or the agent has no readable transcript.
    ///
    /// Only Codex is supported. OpenCode deliberately stays nil: its conversation
    /// lives in SQLite, and this function's result feeds `transcriptPaths` — a cache
    /// whose other consumers (the Info pane's trace, the phone's trace HTML, the
    /// `sessions send` transcript/cursor reply) all read the value as a JSONL *file*.
    /// The structured plane addresses OpenCode through
    /// `opencodeStructuredAddress` instead, which never enters that cache.
    static func discoverTranscript(agent: AgentPreset, directory: String, after launchedAt: Date?) -> String? {
        guard agent == .codex, let launchedAt else { return nil }
        return matchCodex(directory: directory, after: launchedAt)?.url.path
    }

    /// The structured-plane address for an OpenCode session: the SQLite database
    /// path and the session row's id, joined as a `db-path#session-id` pseudo-path
    /// (`OpenCodeAdapter.events` splits it back apart). NOT a readable file — see
    /// `discoverTranscript` for why it must be kept out of `transcriptPaths`.
    /// Unlike `discover`, which binds to the record born when termio launched the
    /// agent, this takes the *newest* matching session: the OpenCode TUI can start
    /// fresh sessions in place, and the phone lens should follow the live one.
    static func opencodeStructuredAddress(directory: String, after launchedAt: Date?) -> String? {
        guard let launchedAt else { return nil }
        return matchOpenCode(directory: directory, after: launchedAt, newest: true)
            .map { OpenCodeStore.databasePath + "#" + $0 }
    }

    /// A small negative tolerance: the agent writes its record just after we launch it,
    /// so its creation time should be ≥ `launchedAt`, but allow for clock granularity.
    private static let tolerance: TimeInterval = 2

    /// Codex writes one rollout file per session at `~/.codex/sessions/YYYY/MM/DD/`,
    /// whose first line is a `session_meta` event carrying the session `id` and `cwd`.
    private static func matchCodex(directory: String, after launchedAt: Date) -> (url: URL, id: String)? {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        let target = canonical(directory)
        return bestMatch(in: root, ext: "jsonl", after: launchedAt) { url in
            guard let line = firstLine(of: url),
                  let object = json(line),
                  object["type"] as? String == "session_meta",
                  let payload = object["payload"] as? [String: Any],
                  let id = payload["id"] as? String,
                  let cwd = payload["cwd"] as? String,
                  canonical(cwd) == target
            else { return nil }
            return id
        }
    }

    /// OpenCode (v1.17+) keeps its sessions in SQLite — the `session` table carries
    /// the `id`, the absolute `directory` the session ran in, and `time_created` in
    /// ms since epoch. (The old per-record JSON tree under `storage/session` is dead
    /// data, unwritten since 2026-01, so it is no longer consulted.) `newest: false`
    /// binds to the earliest record created after launch — the session born when we
    /// launched this one, the same semantics as `bestMatch` — while `newest: true`
    /// follows the most recently started match.
    private static func matchOpenCode(directory: String, after launchedAt: Date, newest: Bool) -> String? {
        let target = canonical(directory)
        let threshold = Int64((launchedAt.timeIntervalSince1970 - tolerance) * 1000)
        let matches = OpenCodeStore.sessions(createdAtOrAfter: threshold)
            .filter { canonical($0.directory) == target }
        let match = newest
            ? matches.max { $0.created < $1.created }
            : matches.min { $0.created < $1.created }
        return match?.id
    }

    /// Walks `root` for `ext` files created at/after `launchedAt`, runs `identify` (which
    /// confirms the working directory and returns the session id), and returns the URL and
    /// id of the *earliest-created* match — the session born when we launched this one.
    private static func bestMatch(in root: URL, ext: String, after launchedAt: Date,
                                  identify: (URL) -> String?) -> (url: URL, id: String)? {
        let keys: [URLResourceKey] = [.creationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys) else { return nil }

        let threshold = launchedAt.addingTimeInterval(-tolerance)
        var best: (url: URL, id: String, created: Date)?
        for case let url as URL in enumerator {
            guard url.pathExtension == ext,
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let created = values.creationDate, created >= threshold,
                  best == nil || created < best!.created,
                  let id = identify(url)
            else { continue }
            best = (url, id, created)
        }
        return best.map { ($0.url, $0.id) }
    }

    /// Resolves symlinks and standardizes a path so termio's recorded workspace and the
    /// agent's recorded cwd compare equal even when one side went through `/private`.
    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func json(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// The first line of a (possibly large) JSONL file, read from a bounded prefix so a
    /// long transcript isn't slurped whole just to reach its `session_meta` header.
    private static func firstLine(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let chunk = try? handle.read(upToCount: 64 * 1024),
              let text = String(data: chunk, encoding: .utf8) else { return nil }
        return text.split(separator: "\n", maxSplits: 1).first.map(String.init)
    }
}
