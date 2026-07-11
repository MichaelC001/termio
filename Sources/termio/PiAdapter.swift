import Foundation
import TermioShared

/// Pi's adapter: its transcript is one JSON object per line under
/// `~/.pi/agent/sessions/<encoded-cwd>/<launch-timestamp>_<session-id>.jsonl`.
/// termio pins Pi's session id up front (`--session-id`, `Session.resumeID`),
/// but the filename carries a launch-timestamp prefix, so the transcript
/// resolves by globbing the session folders for the `_<id>.jsonl` suffix
/// rather than reconstructing Pi's cwd encoding (its private detail) — the
/// same stance as `ClaudeConversation.transcriptPath`.
struct PiAdapter: AgentAdapter {
    let agentID = "pi"

    func transcriptURL(for session: Session) -> URL? {
        guard let id = session.resumeID else { return nil }
        let sessions = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/sessions", isDirectory: true)
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: sessions, includingPropertiesForKeys: nil) else { return nil }
        // Pi keeps termio's pinned UUID in the filename uppercase; compare
        // case-insensitively rather than trust either side's casing.
        let suffix = "_\(id.lowercased()).jsonl"
        for folder in folders {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil) else { continue }
            if let match = files.first(where: {
                $0.lastPathComponent.lowercased().hasSuffix(suffix)
            }) { return match }
        }
        return nil
    }

    func events(tailing url: URL, replay: Bool) -> AsyncStream<SessionUpdate> {
        TranscriptTailer.stream(path: url.path, replay: replay) {
            PiTranscriptMapper.updates(fromLine: $0)
        }
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

// MARK: - Pi JSONL line → ACP updates

/// As lenient as `ClaudeTranscriptMapper` — the format is Pi's private
/// detail, not a contract, so anything unrecognized is skipped, never fatal.
/// Every line is `{type, id, parentId, timestamp, …}`; only `type:"message"`
/// carries conversation (`session` / `model_change` / `thinking_level_change`
/// are bookkeeping). Entries form a parent-linked tree for forking; the
/// linear tail simply ignores `parentId`.
enum PiTranscriptMapper {
    static func updates(fromLine entry: [String: Any]) -> [SessionUpdate] {
        guard entry["type"] as? String == "message",
              let message = entry["message"] as? [String: Any]
        else { return [] }
        let messageId = entry["id"] as? String

        switch message["role"] as? String {
        case "user": return userUpdates(message, messageId: messageId)
        case "assistant": return assistantUpdates(message, messageId: messageId)
        case "toolResult": return toolResultUpdates(message)
        default: return []
        }
    }

    /// A `user` message is purely the human's prompt (tool results ride their
    /// own `toolResult` role, unlike Claude's user-role piggyback).
    private static func userUpdates(_ message: [String: Any], messageId: String?) -> [SessionUpdate] {
        var texts: [String] = []
        if let text = message["content"] as? String {
            texts.append(text)
        } else if let blocks = message["content"] as? [[String: Any]] {
            for block in blocks where block["type"] as? String == "text" {
                if let text = block["text"] as? String { texts.append(text) }
            }
        }
        let prompt = texts.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return [] }
        return [.userMessageChunk(ContentChunk(content: .text(prompt), messageId: messageId))]
    }

    /// An `assistant` message's content blocks map one-to-one: `text` →
    /// message chunk, `thinking` → thought chunk (`thinkingSignature` is
    /// provider ciphertext, ignored), `toolCall` → a new `tool_call`; the
    /// message's token usage becomes a `usage_update`.
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
            case "toolCall":
                if let call = toolCall(block) { updates.append(.toolCall(call)) }
            default:
                break
            }
        }
        if let usage = usageUpdate(message["usage"] as? [String: Any],
                                   model: message["model"] as? String,
                                   provider: message["provider"] as? String) {
            updates.append(usage)
        }
        return updates
    }

    /// A `toolResult` message resolves its pending `tool_call`:
    /// `{toolCallId, toolName, content: [{type: "text", text}], isError}`.
    private static func toolResultUpdates(_ message: [String: Any]) -> [SessionUpdate] {
        guard let toolCallId = message["toolCallId"] as? String else { return [] }
        let failed = (message["isError"] as? Bool) ?? false
        let output = ((message["content"] as? [[String: Any]]) ?? [])
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
        return [.toolCallUpdate(ToolCallUpdateEvent(
            toolCallId: toolCallId,
            status: failed ? .failed : .completed,
            content: output.isEmpty ? nil : [.text(capped(output, at: toolOutputCap))]
        ))]
    }

    private static func toolCall(_ block: [String: Any]) -> ToolCallEvent? {
        guard let toolCallId = block["id"] as? String else { return nil }
        let name = block["name"] as? String ?? "tool"
        let arguments = block["arguments"] as? [String: Any] ?? [:]
        let summary = toolSummary(arguments)
        let path = arguments["path"] as? String
        return ToolCallEvent(
            toolCallId: toolCallId,
            title: summary.isEmpty ? name : "\(name): \(summary)",
            kind: kind(forTool: name),
            status: .inProgress,
            content: diffContents(tool: name, arguments: arguments),
            locations: path.map { [ToolCallLocation(path: $0)] }
        )
    }

    /// Pi's file-editing tools carry their whole change in the arguments, so
    /// the `tool_call` ships ACP diff content up front. `edit` has worn two
    /// shapes on disk: current Pi sends `{path, edits: [{oldText, newText}]}`,
    /// older transcripts a flat `{path, oldText, newText}` — both are mapped.
    private static func diffContents(tool: String, arguments: [String: Any]) -> [ToolCallContent]? {
        guard let path = arguments["path"] as? String else { return nil }
        switch tool {
        case "edit":
            if let edits = arguments["edits"] as? [[String: Any]] {
                let diffs = edits.compactMap { edit -> ToolCallContent? in
                    guard let newText = edit["newText"] as? String else { return nil }
                    return .diff(
                        path: path,
                        oldText: (edit["oldText"] as? String).map { capped($0, at: diffTextCap) },
                        newText: capped(newText, at: diffTextCap)
                    )
                }
                return diffs.isEmpty ? nil : diffs
            }
            guard let newText = arguments["newText"] as? String else { return nil }
            return [.diff(
                path: path,
                oldText: (arguments["oldText"] as? String).map { capped($0, at: diffTextCap) },
                newText: capped(newText, at: diffTextCap)
            )]
        case "write":
            guard let content = arguments["content"] as? String else { return nil }
            return [.diff(path: path, oldText: nil, newText: capped(content, at: diffTextCap))]
        default:
            return nil
        }
    }

    /// Pi tool names → ACP tool kinds, for the phone's card icons. Pi's
    /// built-ins are exactly `read, bash, edit, write, grep, find, ls`
    /// (docs/sdk.md in the pi package); the fetch names cover the common
    /// community packages, everything else falls to `.other`.
    private static func kind(forTool name: String) -> ToolKind {
        switch name {
        case "bash": .execute
        case "read": .read
        case "edit", "write": .edit
        case "grep", "find", "ls", "glob": .search
        case "fetch", "webfetch": .fetch
        default: .other
        }
    }

    /// The one line that best names a tool call: a command, a pattern, a
    /// path — whichever the arguments carry. Pattern outranks path because
    /// grep/find carry both and `grep: foo` beats `grep: .` as a card title.
    private static func toolSummary(_ arguments: [String: Any]) -> String {
        for key in ["command", "pattern", "path", "url", "query"] {
            if let value = arguments[key] as? String, !value.isEmpty {
                return String(value.prefix(160))
            }
        }
        return ""
    }

    /// The message's own usage as context occupancy. Pi's `totalTokens` is
    /// the components' sum (verified against real transcripts), so it's the
    /// value with the fallback of summing when absent.
    private static func usageUpdate(_ usage: [String: Any]?, model: String?, provider: String?) -> SessionUpdate? {
        guard let usage else { return nil }
        var used = (usage["totalTokens"] as? Int) ?? 0
        if used == 0 {
            used = ((usage["input"] as? Int) ?? 0)
                + ((usage["output"] as? Int) ?? 0)
                + ((usage["cacheRead"] as? Int) ?? 0)
                + ((usage["cacheWrite"] as? Int) ?? 0)
        }
        guard used > 0 else { return nil }
        return .usageUpdate(UsageUpdate(
            used: used, size: contextWindowSize(model: model, provider: provider)
        ))
    }

    /// Context window for `usage_update.size`. The transcript reports
    /// consumption, not capacity — the same known-constant stance as
    /// `ClaudeTranscriptMapper.contextWindowSize`, but keyed by model family
    /// because Pi runs many. Values transcribed from Pi's own bundled model
    /// catalog (`@earendil-works/pi-ai` provider tables, pi 0.80.6); a family
    /// the table misses gets Claude's 200k as the conservative default.
    private static func contextWindowSize(model: String?, provider: String?) -> Int {
        guard let model = model?.lowercased() else { return 200_000 }
        if model.hasPrefix("claude") {
            // The 1M-window generation is opus ≥ 4.6, sonnet ≥ 4.5, and
            // fable; earlier opus and all haiku are 200k.
            let oneMillion = [
                "claude-fable", "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8",
                "claude-sonnet-4-5", "claude-sonnet-4-6", "claude-sonnet-5",
            ]
            return oneMillion.contains(where: model.hasPrefix) ? 1_000_000 : 200_000
        }
        if model.hasPrefix("gpt-5") {
            // The OpenAI API serves gpt-5.x at 400k; the Codex-subscription
            // provider (what Pi transcripts actually record) steps 272k →
            // 372k across 5.4 → 5.6, with the spark mini at 128k.
            if provider?.lowercased() == "openai" { return 400_000 }
            if model.hasPrefix("gpt-5.6") { return 372_000 }
            if model.hasPrefix("gpt-5.3-codex-spark") { return 128_000 }
            return 272_000
        }
        if model.hasPrefix("gemini") { return 1_048_576 }
        if model.hasPrefix("kimi") || model.hasPrefix("k2") { return 262_144 }
        return 200_000
    }
}
