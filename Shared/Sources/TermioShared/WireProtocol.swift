import Foundation

/// The companion wire protocol, shared by the Mac companion server and the iOS
/// client so the two never drift. v1 is deliberately tiny:
///
/// - **Binary** WebSocket frames carry raw PTY bytes in both directions
///   (server → client = terminal output, client → server = keystrokes).
/// - **Text** WebSocket frames carry JSON control messages (resize, and room
///   to grow: attention, exit, seq catch-up).
///
/// E2E encryption wraps the binary payloads in a later pass; the framing here
/// is transport-agnostic (works identically over ws:// localhost, wss:// via a
/// tunnel, or a QUIC stream).
public enum CompanionControl: Codable, Sendable, Equatable {
    /// The client's terminal grid changed; the server resizes the PTY.
    case resize(cols: Int, rows: Int)
    /// The remote process exited.
    case exit(code: Int32)

    public func encoded() -> String {
        // Small, hand-stable JSON so both ends agree without a schema tool.
        switch self {
        case .resize(let cols, let rows):
            return #"{"t":"resize","cols":\#(cols),"rows":\#(rows)}"#
        case .exit(let code):
            return #"{"t":"exit","code":\#(code)}"#
        }
    }

    public static func decode(_ text: String) -> CompanionControl? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["t"] as? String
        else { return nil }
        switch type {
        case "resize":
            guard let cols = obj["cols"] as? Int, let rows = obj["rows"] as? Int else { return nil }
            return .resize(cols: cols, rows: rows)
        case "exit":
            let code = (obj["code"] as? Int).map(Int32.init) ?? 0
            return .exit(code: code)
        default:
            return nil
        }
    }
}

// MARK: - Roster (server → client)

/// One session as it appears in the phone's tree. `agent` and `status` are the
/// raw values of `AgentKind` / `SessionStatus` so the wire stays string-stable
/// and decoupled from either app's internal enums.
public struct RosterSession: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let agent: String   // "claude" | "codex" | "opencode" | "terminal"
    public let status: String  // "idle" | "working" | "done" | "needsAttention"

    public init(id: String, title: String, agent: String, status: String) {
        self.id = id
        self.title = title
        self.agent = agent
        self.status = status
    }
}

/// One project and its sessions.
public struct RosterProject: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let path: String
    public let sessions: [RosterSession]

    public init(id: String, name: String, path: String, sessions: [RosterSession]) {
        self.id = id
        self.name = name
        self.path = path
        self.sessions = sessions
    }
}

/// The full project/session roster the companion server pushes to the phone —
/// the same data the desktop sidebar shows. Sent on connect and whenever the
/// store's projects/statuses/titles change. Carried as a text frame tagged
/// `"roster"` so it coexists with the small `CompanionControl` messages.
public struct CompanionRoster: Codable, Sendable, Equatable {
    public let t: String
    public let projects: [RosterProject]

    public init(projects: [RosterProject]) {
        t = "roster"
        self.projects = projects
    }

    public func encodedJSON() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return #"{"t":"roster","projects":[]}"# }
        return String(decoding: data, as: UTF8.self)
    }

    /// Decode a text frame if it is a roster (tagged `"t":"roster"`), else nil.
    public static func decode(_ text: String) -> CompanionRoster? {
        guard let data = text.data(using: .utf8),
              let roster = try? JSONDecoder().decode(CompanionRoster.self, from: data),
              roster.t == "roster"
        else { return nil }
        return roster
    }
}
