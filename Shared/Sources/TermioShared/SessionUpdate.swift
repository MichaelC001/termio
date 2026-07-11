import Foundation

/// The structured plane's event vocabulary: ACP v1 `session/update` shapes
/// (agentclientprotocol.com), carried over the companion socket as
/// `CompanionControl.sessionUpdate` text frames. Field names, discriminators,
/// and enum values match the ACP schema exactly, so a future native ACP peer
/// (or the official Kotlin SDK on Android) can speak it unchanged; termio's
/// envelope (auth, roster, subscribe) stays in `CompanionControl`.
///
/// Decoding is deliberately forgiving — the ACP schema itself marks most
/// fields `x-deserialize-default-on-error` — because the events are derived
/// from vendor transcript files whose formats are not a contract: an unknown
/// `sessionUpdate` becomes `.unknown`, unknown tool kinds/statuses fall back
/// to their defaults, and absent fields decode as nil rather than throwing.
public enum SessionUpdate: Codable, Sendable, Equatable {
    /// A chunk of the user's message (ACP `user_message_chunk`).
    case userMessageChunk(ContentChunk)
    /// A chunk of the agent's response (ACP `agent_message_chunk`).
    case agentMessageChunk(ContentChunk)
    /// A chunk of the agent's internal reasoning (ACP `agent_thought_chunk`).
    case agentThoughtChunk(ContentChunk)
    /// A new tool call was initiated (ACP `tool_call`).
    case toolCall(ToolCallEvent)
    /// Progress or results for an existing tool call (ACP `tool_call_update`).
    case toolCallUpdate(ToolCallUpdateEvent)
    /// Context-window occupancy (ACP `usage_update`).
    case usageUpdate(UsageUpdate)
    /// A variant this build doesn't know. Kept (not an error) so an older
    /// client survives a newer server.
    case unknown(sessionUpdate: String)

    private enum CodingKeys: String, CodingKey { case sessionUpdate }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let discriminator = (try? container.decode(String.self, forKey: .sessionUpdate)) ?? ""
        switch discriminator {
        case "user_message_chunk":
            self = .userMessageChunk(try ContentChunk(from: decoder))
        case "agent_message_chunk":
            self = .agentMessageChunk(try ContentChunk(from: decoder))
        case "agent_thought_chunk":
            self = .agentThoughtChunk(try ContentChunk(from: decoder))
        case "tool_call":
            self = .toolCall(try ToolCallEvent(from: decoder))
        case "tool_call_update":
            self = .toolCallUpdate(try ToolCallUpdateEvent(from: decoder))
        case "usage_update":
            self = .usageUpdate(try UsageUpdate(from: decoder))
        default:
            self = .unknown(sessionUpdate: discriminator)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .userMessageChunk(let chunk):
            try container.encode("user_message_chunk", forKey: .sessionUpdate)
            try chunk.encode(to: encoder)
        case .agentMessageChunk(let chunk):
            try container.encode("agent_message_chunk", forKey: .sessionUpdate)
            try chunk.encode(to: encoder)
        case .agentThoughtChunk(let chunk):
            try container.encode("agent_thought_chunk", forKey: .sessionUpdate)
            try chunk.encode(to: encoder)
        case .toolCall(let event):
            try container.encode("tool_call", forKey: .sessionUpdate)
            try event.encode(to: encoder)
        case .toolCallUpdate(let event):
            try container.encode("tool_call_update", forKey: .sessionUpdate)
            try event.encode(to: encoder)
        case .usageUpdate(let usage):
            try container.encode("usage_update", forKey: .sessionUpdate)
            try usage.encode(to: encoder)
        case .unknown(let discriminator):
            try container.encode(discriminator, forKey: .sessionUpdate)
        }
    }
}

/// ACP `ContentChunk`: one streamed item of message content. Chunks sharing a
/// `messageId` belong to the same message; a new id starts a new message.
public struct ContentChunk: Codable, Sendable, Equatable {
    public var content: ContentBlock
    public var messageId: String?
    public var _meta: [String: AnyCodable]?

    public init(content: ContentBlock, messageId: String? = nil, _meta: [String: AnyCodable]? = nil) {
        self.content = content
        self.messageId = messageId
        self._meta = _meta
    }
}

/// ACP `ContentBlock`, kept as a struct with the discriminator explicit so an
/// unfamiliar block type (image, resource…) still decodes instead of throwing;
/// termio's normalizer only ever emits `text`.
public struct ContentBlock: Codable, Sendable, Equatable {
    public var type: String
    public var text: String?
    public var _meta: [String: AnyCodable]?

    public init(type: String, text: String? = nil, _meta: [String: AnyCodable]? = nil) {
        self.type = type
        self.text = text
        self._meta = _meta
    }

    public static func text(_ text: String) -> ContentBlock {
        ContentBlock(type: "text", text: text)
    }
}

/// ACP `ToolKind` — what category of work a tool call is, for icon choice.
public enum ToolKind: String, Codable, Sendable, Equatable {
    case read, edit, delete, move, search, execute, think, fetch, other

    /// ACP marks this field `x-deserialize-default-on-error`: an unknown kind
    /// (a newer peer's vocabulary) degrades to `.other`, never a decode error.
    public init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = ToolKind(rawValue: raw) ?? .other
    }
}

/// ACP `ToolCallStatus` — a tool call's lifecycle state.
public enum ToolCallStatus: String, Codable, Sendable, Equatable {
    case pending
    case inProgress = "in_progress"
    case completed
    case failed

    /// Unknown statuses degrade to `.pending` (the schema's default) rather
    /// than failing the whole frame.
    public init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = ToolCallStatus(rawValue: raw) ?? .pending
    }
}

/// ACP `ToolCallContent`: what a tool call produced. The variants flatten
/// their payload beside the `type` discriminator on the wire (`content` |
/// `diff` | `terminal`), so this is one struct of optionals — the `diff`
/// fields (`path`/`oldText`/`newText`) sit at the top level per the schema.
public struct ToolCallContent: Codable, Sendable, Equatable {
    public var type: String
    /// `type == "content"`: a standard content block.
    public var content: ContentBlock?
    /// `type == "diff"`: the modified file's absolute path.
    public var path: String?
    /// `type == "diff"`: original content — nil for a new file.
    public var oldText: String?
    /// `type == "diff"`: content after the modification.
    public var newText: String?
    public var _meta: [String: AnyCodable]?

    public init(
        type: String, content: ContentBlock? = nil, path: String? = nil,
        oldText: String? = nil, newText: String? = nil, _meta: [String: AnyCodable]? = nil
    ) {
        self.type = type
        self.content = content
        self.path = path
        self.oldText = oldText
        self.newText = newText
        self._meta = _meta
    }

    public static func text(_ text: String) -> ToolCallContent {
        ToolCallContent(type: "content", content: .text(text))
    }

    public static func diff(path: String, oldText: String?, newText: String) -> ToolCallContent {
        ToolCallContent(type: "diff", path: path, oldText: oldText, newText: newText)
    }
}

/// ACP `ToolCallLocation`: a file the tool call touches, for follow-along UI.
public struct ToolCallLocation: Codable, Sendable, Equatable {
    public var path: String
    public var line: Int?
    public var _meta: [String: AnyCodable]?

    public init(path: String, line: Int? = nil, _meta: [String: AnyCodable]? = nil) {
        self.path = path
        self.line = line
        self._meta = _meta
    }
}

/// ACP `ToolCall`: a new tool invocation (the `tool_call` update's payload).
public struct ToolCallEvent: Codable, Sendable, Equatable {
    public var toolCallId: String
    public var title: String
    public var kind: ToolKind?
    public var status: ToolCallStatus?
    public var content: [ToolCallContent]?
    public var locations: [ToolCallLocation]?
    public var rawInput: [String: AnyCodable]?
    public var _meta: [String: AnyCodable]?

    private enum CodingKeys: String, CodingKey {
        case toolCallId, title, kind, status, content, locations, rawInput, _meta
    }

    public init(
        toolCallId: String, title: String, kind: ToolKind? = nil,
        status: ToolCallStatus? = nil, content: [ToolCallContent]? = nil,
        locations: [ToolCallLocation]? = nil, rawInput: [String: AnyCodable]? = nil,
        _meta: [String: AnyCodable]? = nil
    ) {
        self.toolCallId = toolCallId
        self.title = title
        self.kind = kind
        self.status = status
        self.content = content
        self.locations = locations
        self.rawInput = rawInput
        self._meta = _meta
    }
}

/// ACP `ToolCallUpdate`: a delta to an existing tool call — everything but
/// the id is optional, only changed fields ride.
public struct ToolCallUpdateEvent: Codable, Sendable, Equatable {
    public var toolCallId: String
    public var title: String?
    public var kind: ToolKind?
    public var status: ToolCallStatus?
    public var content: [ToolCallContent]?
    public var locations: [ToolCallLocation]?
    public var _meta: [String: AnyCodable]?

    public init(
        toolCallId: String, title: String? = nil, kind: ToolKind? = nil,
        status: ToolCallStatus? = nil, content: [ToolCallContent]? = nil,
        locations: [ToolCallLocation]? = nil, _meta: [String: AnyCodable]? = nil
    ) {
        self.toolCallId = toolCallId
        self.title = title
        self.kind = kind
        self.status = status
        self.content = content
        self.locations = locations
        self._meta = _meta
    }
}

/// ACP `UsageUpdate`: context-window occupancy for the session.
public struct UsageUpdate: Codable, Sendable, Equatable {
    /// Tokens currently in context.
    public var used: Int
    /// Total context window size in tokens.
    public var size: Int
    public var _meta: [String: AnyCodable]?

    public init(used: Int, size: Int, _meta: [String: AnyCodable]? = nil) {
        self.used = used
        self.size = size
        self._meta = _meta
    }
}

/// A JSON value for the `_meta` / `rawInput` escape hatches ACP reserves on
/// every type — free-form data neither side may assume the shape of.
public enum AnyCodable: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AnyCodable])
    case object([String: AnyCodable])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AnyCodable].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: AnyCodable].self) {
            self = .object(value)
        } else {
            self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
