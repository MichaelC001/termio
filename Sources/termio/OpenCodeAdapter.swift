import Foundation
import SQLite3
import TermioShared

/// OpenCode's adapter: since v1.17 its conversation lives in SQLite
/// (`~/.local/share/opencode/opencode.db`, WAL mode) — `part` rows carrying
/// JSON payloads that are INSERTed and then UPDATEd *in place* while the
/// agent streams — so the structured plane is derived by polling SQL, not by
/// tailing a JSONL file. A database plus a row filter can't ride a plain file
/// path, so the address `events` receives is a `db-path#session-id`
/// pseudo-path, resolved store-side by
/// `AgentSessionStore.opencodeStructuredAddress`.
struct OpenCodeAdapter: AgentAdapter {
    let agentID = "opencode"

    /// nil for the same reason as `CodexAdapter`: OpenCode accepts no pinned
    /// session id at launch, so discovery needs store state (project
    /// directory, launch instant) an adapter doesn't hold.
    func transcriptURL(for session: Session) -> URL? { nil }

    func events(tailing url: URL, replay: Bool) -> AsyncStream<SessionUpdate> {
        // `URL(fileURLWithPath:)` keeps the "#" as a path character (percent-
        // encoded in the absolute string, decoded again by `.path`), so the
        // session id is recovered by splitting on the last "#".
        let address = url.path
        guard let marker = address.range(of: "#", options: .backwards) else {
            return AsyncStream { $0.finish() }
        }
        return OpenCodeTailer.stream(
            dbPath: String(address[..<marker.lowerBound]),
            sessionID: String(address[marker.upperBound...]),
            replay: replay
        )
    }
}

/// Same caps as the other mappers (file-private there): tool results ride
/// the wire as cards, diffs as the expanded view — both bounded.
private let toolOutputCap = 2_000
private let diffTextCap = 20_000

private func capped(_ text: String, at limit: Int) -> String {
    guard text.count > limit else { return text }
    return text.prefix(limit) + "\n… (truncated)"
}

// MARK: - OpenCode SQLite store (read-only)

/// Read-only access to OpenCode's SQLite store, shared by the tailer here
/// and the launch-time discovery in `AgentSessionStore`. Every call opens
/// its own `SQLITE_OPEN_READONLY` connection and closes it before returning:
/// WAL mode makes reads beside OpenCode's live writer safe, and a per-call
/// connection keeps the poll robust against the file being swapped out
/// underneath — the same stance as `TranscriptTailer` reopening its file
/// every drain.
enum OpenCodeStore {
    static var databasePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db").path
    }

    struct SessionRow {
        let id: String
        let directory: String
        let created: Int64
    }

    /// Session rows created at/after `threshold` (ms since epoch) — the
    /// launch-time discovery scan. Directory matching stays in Swift so both
    /// sides go through the same symlink canonicalization.
    static func sessions(createdAtOrAfter threshold: Int64) -> [SessionRow] {
        var rows: [SessionRow] = []
        query(
            dbPath: databasePath,
            sql: "SELECT id, directory, time_created FROM session WHERE time_created >= ?1",
            bind: { sqlite3_bind_int64($0, 1, threshold) }
        ) { statement in
            guard let id = text(statement, 0), let directory = text(statement, 1) else { return }
            rows.append(SessionRow(
                id: id, directory: directory, created: sqlite3_column_int64(statement, 2)
            ))
        }
        return rows
    }

    /// Prepares and steps `sql` on a fresh read-only connection, calling
    /// `onRow` per result row, then finalizes the statement and closes the
    /// connection. Any failure (db missing, locked, malformed query) yields
    /// zero rows — every caller treats absence as "nothing discovered yet"
    /// and tries again on a later tick.
    static func query(
        dbPath: String, sql: String,
        bind: (OpaquePointer) -> Void,
        onRow: (OpaquePointer) -> Void
    ) {
        var db: OpaquePointer?
        // Per the SQLite docs the handle must be closed even when open fails.
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        while sqlite3_step(statement) == SQLITE_ROW { onRow(statement) }
    }

    static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    /// SQLITE_TRANSIENT (the -1 destructor): have SQLite copy the string
    /// before Swift releases the bridged buffer.
    static func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
}

// MARK: - OpenCode part rows → ACP updates

/// Follows one OpenCode session's `part` rows as an event stream. Unlike the
/// JSONL tailers there is no append-only file to offset into: the cursor is
/// `time_updated`, and each part carries per-stream memory — how much of its
/// text has already been emitted (a streaming part's whole text is rewritten
/// on every UPDATE, and chunks are append-semantics on the wire, so only the
/// new suffix rides) and which tool status was last announced (only
/// transitions ride). Every `stream` call owns all of that state
/// independently, so subscribers never disturb each other (design §8 rule 2).
///
/// As lenient as the other mappers: the schema is OpenCode's private detail,
/// not a contract, so anything unrecognized is skipped, never fatal.
struct OpenCodeTailer {
    let dbPath: String
    let sessionID: String
    private var cursor: Int64 = 0
    private var emittedTextLength: [String: Int] = [:]
    private var emittedToolStatus: [String: String] = [:]
    private var emittedUsage: Set<String> = []

    /// Same cadence and rationale as `TranscriptTailer.pollNanoseconds`: the
    /// structured plane is allowed to lag the byte plane by flush latency
    /// anyway (design §10), so sub-second polling buys nothing.
    private static let pollNanoseconds: UInt64 = 700_000_000

    init(dbPath: String, sessionID: String) {
        self.dbPath = dbPath
        self.sessionID = sessionID
    }

    /// One tailer wrapped as the adapter event stream: replay maps every row
    /// already in the store first, then further INSERTs/UPDATEs keep
    /// yielding until the consumer cancels.
    static func stream(dbPath: String, sessionID: String, replay: Bool) -> AsyncStream<SessionUpdate> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                var tailer = OpenCodeTailer(dbPath: dbPath, sessionID: sessionID)
                if !replay { tailer.skipToNow() }
                while !Task.isCancelled {
                    for update in tailer.drain() {
                        continuation.yield(update)
                    }
                    try? await Task.sleep(nanoseconds: Self.pollNanoseconds)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One poll's slice: parts touched at/after the cursor, joined to their
    /// message for the two fields a part doesn't carry itself — the
    /// speaker's role, and the model for the context-window table. `>=`
    /// rather than `>` because several writes can share one millisecond
    /// timestamp: boundary rows are re-read next tick, and the per-part
    /// memory makes re-emission a no-op.
    private static let partsQuery = """
    SELECT p.id, p.time_updated, p.data, \
    json_extract(m.data, '$.role'), json_extract(m.data, '$.modelID'), p.message_id \
    FROM part AS p JOIN message AS m ON m.id = p.message_id \
    WHERE p.session_id = ?1 AND p.time_updated >= ?2 \
    ORDER BY p.time_updated, p.id
    """

    /// Position past everything currently in the store — the no-replay start.
    mutating func skipToNow() {
        var next: Int64 = 0
        OpenCodeStore.query(
            dbPath: dbPath,
            sql: "SELECT COALESCE(MAX(time_updated), 0) + 1 FROM part WHERE session_id = ?1",
            bind: { OpenCodeStore.bindText($0, 1, sessionID) }
        ) { next = sqlite3_column_int64($0, 0) }
        cursor = next
    }

    mutating func drain() -> [SessionUpdate] {
        var updates: [SessionUpdate] = []
        var maxSeen = cursor
        OpenCodeStore.query(
            dbPath: dbPath, sql: Self.partsQuery,
            bind: { statement in
                OpenCodeStore.bindText(statement, 1, sessionID)
                sqlite3_bind_int64(statement, 2, cursor)
            }
        ) { statement in
            guard let partID = OpenCodeStore.text(statement, 0),
                  let payload = OpenCodeStore.text(statement, 2),
                  let data = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
            else { return }
            maxSeen = max(maxSeen, sqlite3_column_int64(statement, 1))
            updates.append(contentsOf: self.updates(
                partID: partID, data: data,
                role: OpenCodeStore.text(statement, 3) ?? "",
                modelID: OpenCodeStore.text(statement, 4),
                messageID: OpenCodeStore.text(statement, 5)
            ))
        }
        cursor = maxSeen
        return updates
    }

    /// `part.data.type` ∈ text | reasoning | tool | patch | step-start |
    /// step-finish. `step-start` is bookkeeping, and `patch` is a file-level
    /// change summary whose diffs already rode in on the edit/write tool
    /// inputs — both skipped.
    private mutating func updates(
        partID: String, data: [String: Any],
        role: String, modelID: String?, messageID: String?
    ) -> [SessionUpdate] {
        switch data["type"] as? String {
        case "text":
            // Synthetic parts are injected plumbing (system-reminders,
            // search-mode prefixes), not conversation.
            guard data["synthetic"] as? Bool != true,
                  let suffix = freshSuffix(partID: partID, text: data["text"] as? String)
            else { return [] }
            let chunk = ContentChunk(content: .text(suffix), messageId: messageID)
            return [role == "user" ? .userMessageChunk(chunk) : .agentMessageChunk(chunk)]
        case "reasoning":
            guard data["synthetic"] as? Bool != true,
                  let suffix = freshSuffix(partID: partID, text: data["text"] as? String)
            else { return [] }
            return [.agentThoughtChunk(ContentChunk(content: .text(suffix), messageId: messageID))]
        case "tool":
            return toolUpdates(partID: partID, data: data)
        case "step-finish":
            return usageUpdate(partID: partID, data: data, modelID: modelID)
        default:
            return []
        }
    }

    /// The not-yet-emitted tail of a (possibly still streaming) text part,
    /// nil when the re-read row holds nothing new. A part that is so far
    /// whitespace-only is held back without recording a length, so it is
    /// either skipped for good or emitted whole once real content lands.
    private mutating func freshSuffix(partID: String, text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let emitted = emittedTextLength[partID] ?? 0
        if emitted == 0,
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        guard text.count > emitted else { return nil }
        emittedTextLength[partID] = text.count
        return String(text.dropFirst(emitted))
    }

    /// A tool part is one row for the call's whole lifecycle:
    /// `state.status` walks pending → running → completed|error in place.
    /// First sight emits the `tool_call` (in progress — pending→running is
    /// not a wire event); the terminal transition emits one
    /// `tool_call_update` carrying the output and a refreshed title/diff,
    /// since the first sighting may have caught the row while its input was
    /// still filling in.
    private mutating func toolUpdates(partID: String, data: [String: Any]) -> [SessionUpdate] {
        let callID = data["callID"] as? String ?? partID
        let tool = data["tool"] as? String ?? "tool"
        let state = data["state"] as? [String: Any] ?? [:]
        let status = state["status"] as? String ?? "pending"
        let input = state["input"] as? [String: Any] ?? [:]
        let summary = Self.toolSummary(input)
        var updates: [SessionUpdate] = []

        if emittedToolStatus[partID] == nil {
            emittedToolStatus[partID] = "running"
            updates.append(.toolCall(ToolCallEvent(
                toolCallId: callID,
                title: summary.isEmpty ? tool : "\(tool): \(summary)",
                kind: Self.kind(forTool: tool),
                status: .inProgress,
                content: Self.diffContents(tool: tool, input: input),
                locations: (input["filePath"] as? String).map { [ToolCallLocation(path: $0)] }
            )))
        }

        guard status == "completed" || status == "error",
              emittedToolStatus[partID] != status else { return updates }
        emittedToolStatus[partID] = status
        let output = state["output"] as? String ?? ""
        updates.append(.toolCallUpdate(ToolCallUpdateEvent(
            toolCallId: callID,
            title: summary.isEmpty ? nil : "\(tool): \(summary)",
            status: status == "error" ? .failed : .completed,
            content: output.isEmpty
                ? Self.diffContents(tool: tool, input: input)
                : [.text(capped(output, at: toolOutputCap))]
        )))
        return updates
    }

    /// A `step-finish` part's token block as context occupancy. `total` is
    /// the components' sum including cache reads/writes (verified against
    /// the real db); summing is the fallback for rows without it.
    private mutating func usageUpdate(
        partID: String, data: [String: Any], modelID: String?
    ) -> [SessionUpdate] {
        guard !emittedUsage.contains(partID),
              let tokens = data["tokens"] as? [String: Any] else { return [] }
        var used = (tokens["total"] as? Int) ?? 0
        if used == 0 {
            let cache = tokens["cache"] as? [String: Any] ?? [:]
            used = ((tokens["input"] as? Int) ?? 0)
                + ((tokens["output"] as? Int) ?? 0)
                + ((tokens["reasoning"] as? Int) ?? 0)
                + ((cache["read"] as? Int) ?? 0)
                + ((cache["write"] as? Int) ?? 0)
        }
        guard used > 0 else { return [] }
        emittedUsage.insert(partID)
        return [.usageUpdate(UsageUpdate(
            used: used, size: Self.contextWindowSize(model: modelID)
        ))]
    }

    /// The file-editing tools carry their whole change in the input
    /// (`{filePath, oldString, newString}` / `{filePath, content}`), so the
    /// `tool_call` ships ACP diff content up front — no waiting on results.
    private static func diffContents(tool: String, input: [String: Any]) -> [ToolCallContent]? {
        guard let path = input["filePath"] as? String else { return nil }
        switch tool {
        case "edit":
            guard let newText = input["newString"] as? String else { return nil }
            return [.diff(
                path: path,
                oldText: (input["oldString"] as? String).map { capped($0, at: diffTextCap) },
                newText: capped(newText, at: diffTextCap)
            )]
        case "write":
            guard let content = input["content"] as? String else { return nil }
            return [.diff(path: path, oldText: nil, newText: capped(content, at: diffTextCap))]
        default:
            return nil
        }
    }

    /// OpenCode tool names → ACP tool kinds, for the phone's card icons.
    private static func kind(forTool name: String) -> ToolKind {
        switch name {
        case "bash": .execute
        case "read": .read
        case "edit", "write", "patch": .edit
        case "grep", "glob", "list": .search
        case "webfetch": .fetch
        case "todowrite", "todoread": .think
        default: .other
        }
    }

    /// The one line that best names a tool call: a command, a path, a
    /// pattern — whichever the input carries (same heuristic as
    /// `ClaudeTranscriptMapper.toolSummary`).
    private static func toolSummary(_ input: [String: Any]) -> String {
        for key in ["command", "filePath", "pattern", "url", "query", "description", "prompt"] {
            if let value = input[key] as? String, !value.isEmpty {
                return String(value.prefix(160))
            }
        }
        return ""
    }

    /// Context window for `usage_update.size`. OpenCode records consumption
    /// per step but not the model's capacity, so a small constant table
    /// keyed by model family (`message.data.modelID`) — the same known-
    /// constant stance as `ClaudeTranscriptMapper.contextWindowSize` and
    /// Pi's table, with 200k as the default for the long tail of models.
    private static func contextWindowSize(model: String?) -> Int {
        guard let model = model?.lowercased() else { return 200_000 }
        if model.hasPrefix("claude") { return 200_000 }
        if model.hasPrefix("gpt-5") || model.hasPrefix("codex") { return 272_000 }
        if model.contains("gemini") { return 1_048_576 }
        return 200_000
    }
}
