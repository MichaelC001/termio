import Foundation
import TermioShared

/// One agent's bridge from its own on-disk transcript to the structured plane:
/// ACP-shaped `SessionUpdate` events derived *beside* the PTY, never by
/// changing how the agent runs (docs/design/mobile-agent-ui-protocol.md §7).
///
/// Every session is a PTY; an adapter is the optional sidecar for its agent.
/// No adapter isn't a mode — it's absence: the byte plane still exists
/// unconditionally, so a bare shell's phone view is simply the terminal.
/// Adapters grow monotonically (transcript today; hook-driven approvals and
/// resume argv in later phases) without the pipeline or clients changing.
protocol AgentAdapter: Sendable {
    /// The agent's companion wire name (`AgentDefinition.wireName`).
    var agentID: String { get }

    /// The transcript this session writes, or nil while none exists on disk
    /// yet. The hook-delivered path (`TermioStore.transcriptPaths`) wins over
    /// this when present; this is the from-disk fallback.
    func transcriptURL(for session: Session) -> URL?

    /// Follows a transcript as an event stream: with `replay` every event
    /// already on disk is parsed first (the `session/load`-style catch-up,
    /// equally valid for a dormant session), then appended lines keep
    /// yielding until the consumer cancels. Each call owns an independent
    /// cursor, so subscribers never disturb each other.
    func events(tailing url: URL, replay: Bool) -> AsyncStream<SessionUpdate>
}

/// Claude Code's adapter: its transcript is one JSON object per line under
/// `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`.
struct ClaudeAdapter: AgentAdapter {
    let agentID = "claude"

    func transcriptURL(for session: Session) -> URL? {
        // termio pins Claude's conversation id up front (Session.resumeID),
        // so the transcript resolves directly by filename.
        session.resumeID
            .flatMap(ClaudeConversation.transcriptPath)
            .map { URL(fileURLWithPath: $0) }
    }

    func events(tailing url: URL, replay: Bool) -> AsyncStream<SessionUpdate> {
        TranscriptTailer.stream(path: url.path, replay: replay) {
            ClaudeTranscriptMapper.updates(fromLine: $0)
        }
    }
}

/// Codex's adapter: its rollout JSONL under `~/.codex/sessions/YYYY/MM/DD/`
/// *is* the transcript. Codex hands termio neither a hook-delivered path nor
/// a pinnable session id, so the file is discovered store-side by launch-time
/// match (`TermioStore.resolveTranscriptPath` → `AgentSessionStore`) — that
/// needs store state (project directory, launch instant) an adapter doesn't
/// hold, which is why `transcriptURL` stays nil here.
struct CodexAdapter: AgentAdapter {
    let agentID = "codex"

    func transcriptURL(for session: Session) -> URL? { nil }

    func events(tailing url: URL, replay: Bool) -> AsyncStream<SessionUpdate> {
        TranscriptTailer.stream(path: url.path, replay: replay) {
            CodexTranscriptMapper.updates(fromLine: $0)
        }
    }
}

/// Previews ride the wire capped: a tool result can be megabytes of build
/// output, and the phone renders a card, not a pager.
private let toolOutputCap = 2_000
/// Diff texts cap higher — the expanded diff view wants real content —
/// but still bounded so one whole-file write can't bloat a frame.
private let diffTextCap = 20_000

private func capped(_ text: String, at limit: Int) -> String {
    guard text.count > limit else { return text }
    return text.prefix(limit) + "\n… (truncated)"
}

/// Reads a JSONL transcript incrementally — newly appended complete lines
/// since the last drain — and maps each line through `map` to zero or more
/// `SessionUpdate`s. The offset only ever advances past a trailing newline,
/// so a line the agent is mid-writing is re-read whole on the next tick.
struct TranscriptTailer {
    let path: String
    let map: @Sendable ([String: Any]) -> [SessionUpdate]
    private var offset: UInt64 = 0

    /// How often an idle tail re-checks the file for appended lines. The
    /// structured plane is allowed to lag the byte plane by transcript-flush
    /// latency anyway (design §10), so sub-second polling buys nothing.
    private static let pollNanoseconds: UInt64 = 700_000_000

    init(path: String, map: @escaping @Sendable ([String: Any]) -> [SessionUpdate]) {
        self.path = path
        self.map = map
    }

    /// One tailer wrapped as the adapter event stream: replay parses what is
    /// already on disk first, then appended lines keep yielding until the
    /// consumer cancels.
    static func stream(
        path: String, replay: Bool,
        map: @escaping @Sendable ([String: Any]) -> [SessionUpdate]
    ) -> AsyncStream<SessionUpdate> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                var tailer = TranscriptTailer(path: path, map: map)
                if !replay { tailer.skipToEnd() }
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

    /// Position past everything currently on disk — the no-replay start.
    mutating func skipToEnd() {
        guard let handle = FileHandle(forReadingAtPath: path),
              let end = try? handle.seekToEnd() else { return }
        offset = end
        try? handle.close()
    }

    mutating func drain() -> [SessionUpdate] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd(), end > offset else { return [] }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.read(upToCount: Int(end - offset)),
              let lastNewline = data.lastIndex(of: 0x0A) else { return [] }
        let complete = data[data.startIndex ... lastNewline]
        offset += UInt64(complete.count)

        return complete
            .split(separator: 0x0A)
            .compactMap { line -> [String: Any]? in
                try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            }
            .flatMap(map)
    }
}

// MARK: - Claude JSONL line → ACP updates

/// The incremental sibling of `SessionTraceRenderer`'s one-shot loop and just
/// as lenient — the format is Claude's private detail, not a contract, so
/// anything unrecognized is skipped, never fatal.
enum ClaudeTranscriptMapper {
    /// Claude Code's context window, for `usage_update.size`. The transcript
    /// reports consumption, not capacity, so this is the known constant.
    private static let contextWindowSize = 200_000

    static func updates(fromLine entry: [String: Any]) -> [SessionUpdate] {
        // Sidechains are subagent traffic; meta lines are plumbing notes.
        guard entry["isSidechain"] as? Bool != true,
              entry["isMeta"] as? Bool != true,
              let type = entry["type"] as? String,
              let message = entry["message"] as? [String: Any]
        else { return [] }
        let messageId = entry["uuid"] as? String

        switch type {
        case "user": return userUpdates(message, messageId: messageId)
        case "assistant": return assistantUpdates(message, messageId: messageId)
        default: return []
        }
    }

    /// A `user` line is the human's prompt *or* tool results riding back on
    /// the user role. Text becomes `user_message_chunk`; each `tool_result`
    /// block resolves its pending `tool_call`; command echoes and hook output
    /// (tag-wrapped, "<"-prefixed) are plumbing, not conversation.
    private static func userUpdates(_ message: [String: Any], messageId: String?) -> [SessionUpdate] {
        var updates: [SessionUpdate] = []
        var texts: [String] = []

        if let text = message["content"] as? String {
            texts.append(text)
        } else if let blocks = message["content"] as? [[String: Any]] {
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String { texts.append(text) }
                case "tool_result":
                    guard let toolCallId = block["tool_use_id"] as? String else { continue }
                    let failed = (block["is_error"] as? Bool) ?? false
                    let output = toolResultText(block["content"])
                    updates.append(.toolCallUpdate(ToolCallUpdateEvent(
                        toolCallId: toolCallId,
                        status: failed ? .failed : .completed,
                        content: output.isEmpty ? nil : [.text(capped(output, at: toolOutputCap))]
                    )))
                default:
                    break
                }
            }
        }

        let prompt = texts.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty, !prompt.hasPrefix("<"), !prompt.hasPrefix("[Request interrupted") {
            updates.insert(.userMessageChunk(ContentChunk(
                content: .text(prompt), messageId: messageId
            )), at: 0)
        }
        return updates
    }

    /// An `assistant` line's content blocks map one-to-one: `text` →
    /// message chunk, `thinking` → thought chunk, `tool_use` → a new
    /// `tool_call` (in progress until its result lands); the message's token
    /// usage becomes a `usage_update`.
    private static func assistantUpdates(_ message: [String: Any], messageId: String?) -> [SessionUpdate] {
        var updates: [SessionUpdate] = []
        for block in (message["content"] as? [[String: Any]]) ?? [] {
            switch block["type"] as? String {
            case "text":
                let text = (block["text"] as? String ?? "")
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                updates.append(.agentMessageChunk(ContentChunk(
                    content: .text(text), messageId: messageId
                )))
            case "thinking":
                let thought = (block["thinking"] as? String ?? "")
                guard !thought.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                updates.append(.agentThoughtChunk(ContentChunk(
                    content: .text(thought), messageId: messageId
                )))
            case "tool_use":
                if let call = toolCall(block) { updates.append(.toolCall(call)) }
            default:
                break
            }
        }
        if let usage = usageUpdate(message["usage"] as? [String: Any]) {
            updates.append(usage)
        }
        return updates
    }

    private static func toolCall(_ block: [String: Any]) -> ToolCallEvent? {
        guard let toolCallId = block["id"] as? String else { return nil }
        let name = block["name"] as? String ?? "tool"
        let input = block["input"] as? [String: Any] ?? [:]
        let summary = toolSummary(input)
        let path = input["file_path"] as? String ?? input["path"] as? String
        return ToolCallEvent(
            toolCallId: toolCallId,
            title: summary.isEmpty ? name : "\(name): \(summary)",
            kind: kind(forTool: name),
            status: .inProgress,
            content: diffContents(tool: name, input: input),
            locations: path.map { [ToolCallLocation(path: $0)] }
        )
    }

    /// The file-editing tools carry their whole change in the input, so the
    /// `tool_call` can ship ACP diff content up front — no waiting on results.
    private static func diffContents(tool: String, input: [String: Any]) -> [ToolCallContent]? {
        guard let path = input["file_path"] as? String else { return nil }
        switch tool {
        case "Edit":
            guard let newText = input["new_string"] as? String else { return nil }
            return [.diff(
                path: path,
                oldText: (input["old_string"] as? String).map { capped($0, at: diffTextCap) },
                newText: capped(newText, at: diffTextCap)
            )]
        case "Write":
            guard let content = input["content"] as? String else { return nil }
            return [.diff(path: path, oldText: nil, newText: capped(content, at: diffTextCap))]
        case "MultiEdit":
            let edits = (input["edits"] as? [[String: Any]] ?? []).compactMap { edit -> ToolCallContent? in
                guard let newText = edit["new_string"] as? String else { return nil }
                return .diff(
                    path: path,
                    oldText: (edit["old_string"] as? String).map { capped($0, at: diffTextCap) },
                    newText: capped(newText, at: diffTextCap)
                )
            }
            return edits.isEmpty ? nil : edits
        default:
            return nil
        }
    }

    /// Claude tool names → ACP tool kinds, for the phone's card icons.
    private static func kind(forTool name: String) -> ToolKind {
        switch name {
        case "Read", "NotebookRead": .read
        case "Edit", "Write", "MultiEdit", "NotebookEdit": .edit
        case "Bash", "BashOutput", "KillShell": .execute
        case "Grep", "Glob", "LS", "WebSearch": .search
        case "WebFetch": .fetch
        case "TodoWrite": .think
        default: .other
        }
    }

    /// The one line that best names a tool call: a command, a path, a pattern —
    /// whichever the input carries (same heuristic as the desktop trace).
    private static func toolSummary(_ input: [String: Any]) -> String {
        for key in ["command", "file_path", "path", "pattern", "description", "prompt", "url", "query", "skill"] {
            if let value = input[key] as? String, !value.isEmpty {
                return String(value.prefix(160))
            }
        }
        return ""
    }

    /// The message's own usage as context occupancy: everything that entered
    /// the window this turn (fresh input, cache reads/writes, output).
    private static func usageUpdate(_ usage: [String: Any]?) -> SessionUpdate? {
        guard let usage else { return nil }
        let used = ((usage["input_tokens"] as? Int) ?? 0)
            + ((usage["cache_read_input_tokens"] as? Int) ?? 0)
            + ((usage["cache_creation_input_tokens"] as? Int) ?? 0)
            + ((usage["output_tokens"] as? Int) ?? 0)
        guard used > 0 else { return nil }
        return .usageUpdate(UsageUpdate(used: used, size: contextWindowSize))
    }

    private static func toolResultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }
}

// MARK: - Codex rollout line → ACP updates

/// The incremental sibling of `SessionTraceRenderer.analyzeCodex`, equally
/// lenient: every rollout line is `{timestamp, type, payload}`; conversation
/// text arrives as `event_msg`, tool activity as `response_item` correlated
/// by `call_id`, the running token total as `token_count`. Anything else
/// (raw protocol messages, encrypted reasoning, world state) is skipped.
enum CodexTranscriptMapper {
    static func updates(fromLine entry: [String: Any]) -> [SessionUpdate] {
        guard let payload = entry["payload"] as? [String: Any] else { return [] }
        switch entry["type"] as? String {
        case "event_msg": return eventUpdates(payload)
        case "response_item": return responseUpdates(payload)
        default: return []
        }
    }

    private static func eventUpdates(_ payload: [String: Any]) -> [SessionUpdate] {
        switch payload["type"] as? String {
        case "user_message":
            guard let text = trimmed(payload["message"]) else { return [] }
            return [.userMessageChunk(ContentChunk(content: .text(text)))]
        case "agent_message":
            guard let text = trimmed(payload["message"]) else { return [] }
            return [.agentMessageChunk(ContentChunk(content: .text(text)))]
        case "agent_reasoning":
            guard let text = trimmed(payload["text"]) else { return [] }
            return [.agentThoughtChunk(ContentChunk(content: .text(text)))]
        case "token_count":
            return usageUpdate(payload["info"] as? [String: Any])
        default:
            return []
        }
    }

    private static func responseUpdates(_ payload: [String: Any]) -> [SessionUpdate] {
        switch payload["type"] as? String {
        // `custom_tool_call` is how apply_patch rides in current Codex builds
        // (its `input` is the raw patch text, not JSON); both shapes share the
        // `call_id` correlation with their `…_output` sibling.
        case "function_call", "custom_tool_call":
            return toolCall(payload).map { [.toolCall($0)] } ?? []
        case "function_call_output", "custom_tool_call_output":
            return toolCallUpdate(payload).map { [.toolCallUpdate($0)] } ?? []
        default:
            return []
        }
    }

    private static func toolCall(_ payload: [String: Any]) -> ToolCallEvent? {
        guard let callId = payload["call_id"] as? String else { return nil }
        let name = payload["name"] as? String ?? "tool"
        // A function call's arguments are a JSON *string*; a custom tool call
        // carries its payload verbatim in `input` (apply_patch's patch text).
        let arguments = decodedArguments(payload["arguments"])

        if name == "apply_patch",
           let patch = (payload["input"] as? String) ?? (arguments["input"] as? String) {
            let diffs = patchDiffs(patch)
            let paths = diffs.compactMap(\.path)
            let files = paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            return ToolCallEvent(
                toolCallId: callId,
                title: files.isEmpty ? name : "\(name): \(files)",
                kind: .edit,
                status: .inProgress,
                // When the patch resists per-file extraction, the raw text is
                // still an honest card body.
                content: diffs.isEmpty ? [.text(capped(patch, at: toolOutputCap))] : diffs,
                locations: paths.isEmpty ? nil : paths.map { ToolCallLocation(path: $0) }
            )
        }

        let summary = toolSummary(arguments)
        return ToolCallEvent(
            toolCallId: callId,
            title: summary.isEmpty ? name : "\(name): \(summary)",
            kind: kind(forTool: name),
            status: .inProgress
        )
    }

    private static func toolCallUpdate(_ payload: [String: Any]) -> ToolCallUpdateEvent? {
        guard let callId = payload["call_id"] as? String else { return nil }
        let output = (payload["output"] as? String) ?? ""
        return ToolCallUpdateEvent(
            toolCallId: callId,
            status: outputFailed(output) ? .failed : .completed,
            content: output.isEmpty ? nil : [.text(capped(output, at: toolOutputCap))]
        )
    }

    /// Codex tool names → ACP tool kinds, for the phone's card icons.
    private static func kind(forTool name: String) -> ToolKind {
        switch name {
        case "exec_command", "shell", "local_shell", "write_stdin": .execute
        case "apply_patch": .edit
        case "update_plan": .think
        case "view_image": .read
        case "web_search": .search
        default: .other
        }
    }

    /// The one line that best names a tool call, from the decoded arguments —
    /// `exec_command` carries `cmd`, older `shell` a `command` string or argv.
    private static func toolSummary(_ arguments: [String: Any]) -> String {
        for key in ["cmd", "command", "path", "file_path", "query", "url"] {
            if let value = arguments[key] as? String, !value.isEmpty {
                return String(value.prefix(160))
            }
            if let argv = arguments[key] as? [String], !argv.isEmpty {
                return String(argv.joined(separator: " ").prefix(160))
            }
        }
        return ""
    }

    /// Codex exec results embed the process exit line ("Process exited with
    /// code N" / "Exit code: N"); a non-zero code marks a failed call. When
    /// absent (non-exec tools) we don't guess and treat it as success — the
    /// same heuristic as `SessionTraceRenderer.codexOutputFailed`.
    private static func outputFailed(_ output: String) -> Bool {
        for marker in ["exited with code ", "Exit code: "] {
            guard let range = output.range(of: marker) else { continue }
            let code = output[range.upperBound...].prefix { $0.isNumber }
            return !code.isEmpty && code != "0"
        }
        return false
    }

    /// Codex reports running totals each turn rather than per-message deltas,
    /// so every `token_count` supersedes the last. `last_token_usage` is the
    /// most recent request — cached input is a subset of `input_tokens`, so
    /// input + output *is* the context occupancy; the cumulative
    /// `total_token_usage` would overshoot the window on long sessions.
    private static func usageUpdate(_ info: [String: Any]?) -> [SessionUpdate] {
        guard let info,
              let size = info["model_context_window"] as? Int, size > 0,
              let usage = (info["last_token_usage"] ?? info["total_token_usage"]) as? [String: Any]
        else { return [] }
        let used = ((usage["input_tokens"] as? Int) ?? 0)
            + ((usage["output_tokens"] as? Int) ?? 0)
        guard used > 0 else { return [] }
        return [.usageUpdate(UsageUpdate(used: used, size: size))]
    }

    private static func decodedArguments(_ raw: Any?) -> [String: Any] {
        guard let text = raw as? String,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    /// Best-effort per-file diffs from an apply_patch envelope (`*** Begin
    /// Patch` … `*** End Patch`). An Add File's body is the whole new file;
    /// an Update File's hunks can't reconstruct the full before/after, so the
    /// old/new texts are the hunks' context-plus-removed and context-plus-
    /// added lines — enough for the phone's line diff to show the change.
    private static func patchDiffs(_ patch: String) -> [ToolCallContent] {
        var diffs: [ToolCallContent] = []
        var path: String?
        var isNewFile = false
        var oldLines: [String] = []
        var newLines: [String] = []

        func flush() {
            defer { path = nil; isNewFile = false; oldLines = []; newLines = [] }
            guard let path, !newLines.isEmpty || !oldLines.isEmpty else { return }
            diffs.append(.diff(
                path: path,
                oldText: isNewFile ? nil : capped(oldLines.joined(separator: "\n"), at: diffTextCap),
                newText: capped(newLines.joined(separator: "\n"), at: diffTextCap)
            ))
        }

        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if let file = marked(line, "*** Add File: ") {
                flush(); path = file; isNewFile = true
            } else if let file = marked(line, "*** Update File: ") {
                flush(); path = file
            } else if line.hasPrefix("*** Delete File: ") {
                flush()
            } else if line.hasPrefix("*** ") || line.hasPrefix("@@") {
                continue
            } else if line.hasPrefix("+") {
                newLines.append(String(line.dropFirst()))
            } else if line.hasPrefix("-") {
                oldLines.append(String(line.dropFirst()))
            } else if path != nil {
                let context = line.hasPrefix(" ") ? String(line.dropFirst()) : String(line)
                oldLines.append(context)
                newLines.append(context)
            }
        }
        flush()
        return diffs
    }

    private static func marked(_ line: Substring, _ marker: String) -> String? {
        guard line.hasPrefix(marker) else { return nil }
        return line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
    }

    private static func trimmed(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : text
    }
}
