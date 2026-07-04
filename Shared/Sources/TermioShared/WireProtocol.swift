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
    /// The client's first message on any connection: proves possession of the
    /// pairing token from the Mac's QR code. Until it lands, the server sends
    /// nothing and refuses every other message — the port may sit behind a
    /// public tunnel URL, where "connected" must not mean "trusted".
    case auth(token: String)
    /// The client asks to bridge a specific session's PTY (roster session id).
    /// Sent once, immediately after the socket opens; the server replays its
    /// recent output and starts streaming.
    case attach(sessionID: String)
    /// The client asks the Mac to create a session in a project — the phone's
    /// equivalent of the sidebar's new-session buttons. Answered with
    /// `.started` (or `.error`).
    case start(projectID: String, agent: String)
    /// A `start` succeeded; the new session is ready to `attach`.
    case started(sessionID: String)
    /// The client asks the Mac to close a session (the phone's swipe-to-remove).
    /// No success reply — the next roster push drops the row everywhere.
    case stop(sessionID: String)
    /// The client's terminal grid changed; the server resizes the PTY.
    case resize(cols: Int, rows: Int)
    /// The remote process exited.
    case exit(code: Int32)
    /// The client asks for one directory's entries (`path` relative to the
    /// project root, "" = the root itself). Answered with `.fileList`.
    case listFiles(projectID: String, path: String)
    /// One directory listing (server → client).
    case fileList(path: String, entries: [WireFileEntry])
    /// The client asks for a file's contents. Answered with `.file` or `.error`.
    case readFile(projectID: String, path: String)
    /// File contents (server → client).
    case file(WireFile)
    /// The client writes edited contents back. `baseMtime` is the mtime (ms)
    /// the edit started from — the server refuses if the file moved on (the
    /// agent may be writing it too); 0 skips the check (explicit overwrite).
    /// Answered with `.written` or `.error` (conflicts prefixed "conflict:").
    case writeFile(projectID: String, path: String, base64: String, baseMtime: Int)
    /// A `writeFile` landed; `mtime` is the file's new mtime (ms), the base
    /// for the next write.
    case written(path: String, mtime: Int)
    /// The client pushes an attachment for the agent (a photo or file picked
    /// on the phone). Unlike `writeFile` this creates: the server drops it
    /// under `<project>/.termio/uploads/` and answers `.uploaded`.
    case upload(projectID: String, name: String, base64: String)
    /// An `upload` landed; `path` is absolute on the Mac — ready to paste
    /// into an agent prompt (the Moshi pattern: agents take file paths).
    case uploaded(path: String)
    /// The server rejected a request (unknown session, no live PTY).
    case error(message: String)

    public func encoded() -> String {
        // Small, hand-stable JSON so both ends agree without a schema tool.
        switch self {
        case .auth(let token):
            return Self.json(["t": "auth", "token": token])
        case .attach(let sessionID):
            return #"{"t":"attach","session":"\#(sessionID)"}"#
        case .start(let projectID, let agent):
            return #"{"t":"start","project":"\#(projectID)","agent":"\#(agent)"}"#
        case .started(let sessionID):
            return #"{"t":"started","session":"\#(sessionID)"}"#
        case .stop(let sessionID):
            return #"{"t":"stop","session":"\#(sessionID)"}"#
        case .resize(let cols, let rows):
            return #"{"t":"resize","cols":\#(cols),"rows":\#(rows)}"#
        case .exit(let code):
            return #"{"t":"exit","code":\#(code)}"#
        // The file messages carry arbitrary user paths, so they go through
        // JSONSerialization instead of interpolation — escaping for free.
        case .listFiles(let projectID, let path):
            return Self.json(["t": "listFiles", "project": projectID, "path": path])
        case .fileList(let path, let entries):
            return Self.json([
                "t": "fileList", "path": path,
                "entries": entries.map { ["name": $0.name, "dir": $0.isDir, "changed": $0.changed] },
            ])
        case .readFile(let projectID, let path):
            return Self.json(["t": "readFile", "project": projectID, "path": path])
        case .file(let file):
            return Self.json([
                "t": "file", "path": file.path, "data": file.base64,
                "size": file.size, "binary": file.binary, "truncated": file.truncated,
                "mtime": file.mtime,
            ])
        case .writeFile(let projectID, let path, let base64, let baseMtime):
            return Self.json([
                "t": "writeFile", "project": projectID, "path": path,
                "data": base64, "baseMtime": baseMtime,
            ])
        case .written(let path, let mtime):
            return Self.json(["t": "written", "path": path, "mtime": mtime])
        case .upload(let projectID, let name, let base64):
            return Self.json(["t": "upload", "project": projectID, "name": name, "data": base64])
        case .uploaded(let path):
            return Self.json(["t": "uploaded", "path": path])
        case .error(let message):
            let escaped = message
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return #"{"t":"error","message":"\#(escaped)"}"#
        }
    }

    public static func decode(_ text: String) -> CompanionControl? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["t"] as? String
        else { return nil }
        switch type {
        case "auth":
            guard let token = obj["token"] as? String else { return nil }
            return .auth(token: token)
        case "attach":
            guard let sessionID = obj["session"] as? String else { return nil }
            return .attach(sessionID: sessionID)
        case "start":
            guard let projectID = obj["project"] as? String,
                  let agent = obj["agent"] as? String else { return nil }
            return .start(projectID: projectID, agent: agent)
        case "started":
            guard let sessionID = obj["session"] as? String else { return nil }
            return .started(sessionID: sessionID)
        case "stop":
            guard let sessionID = obj["session"] as? String else { return nil }
            return .stop(sessionID: sessionID)
        case "resize":
            guard let cols = obj["cols"] as? Int, let rows = obj["rows"] as? Int else { return nil }
            return .resize(cols: cols, rows: rows)
        case "exit":
            let code = (obj["code"] as? Int).map(Int32.init) ?? 0
            return .exit(code: code)
        case "listFiles":
            guard let projectID = obj["project"] as? String,
                  let path = obj["path"] as? String else { return nil }
            return .listFiles(projectID: projectID, path: path)
        case "fileList":
            guard let path = obj["path"] as? String,
                  let raw = obj["entries"] as? [[String: Any]] else { return nil }
            let entries = raw.compactMap { entry -> WireFileEntry? in
                guard let name = entry["name"] as? String else { return nil }
                return WireFileEntry(
                    name: name,
                    isDir: entry["dir"] as? Bool ?? false,
                    changed: entry["changed"] as? Bool ?? false
                )
            }
            return .fileList(path: path, entries: entries)
        case "readFile":
            guard let projectID = obj["project"] as? String,
                  let path = obj["path"] as? String else { return nil }
            return .readFile(projectID: projectID, path: path)
        case "file":
            guard let path = obj["path"] as? String,
                  let base64 = obj["data"] as? String else { return nil }
            return .file(WireFile(
                path: path,
                base64: base64,
                size: obj["size"] as? Int ?? 0,
                binary: obj["binary"] as? Bool ?? false,
                truncated: obj["truncated"] as? Bool ?? false,
                mtime: obj["mtime"] as? Int ?? 0
            ))
        case "writeFile":
            guard let projectID = obj["project"] as? String,
                  let path = obj["path"] as? String,
                  let base64 = obj["data"] as? String else { return nil }
            return .writeFile(
                projectID: projectID, path: path, base64: base64,
                baseMtime: obj["baseMtime"] as? Int ?? 0
            )
        case "written":
            guard let path = obj["path"] as? String,
                  let mtime = obj["mtime"] as? Int else { return nil }
            return .written(path: path, mtime: mtime)
        case "upload":
            guard let projectID = obj["project"] as? String,
                  let name = obj["name"] as? String,
                  let base64 = obj["data"] as? String else { return nil }
            return .upload(projectID: projectID, name: name, base64: base64)
        case "uploaded":
            guard let path = obj["path"] as? String else { return nil }
            return .uploaded(path: path)
        case "error":
            guard let message = obj["message"] as? String else { return nil }
            return .error(message: message)
        default:
            return nil
        }
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Files (read-only file plane)

/// One entry in a `fileList` reply — a name plus just enough for the phone's
/// tree: directory or file, and whether the working diff touches it.
public struct WireFileEntry: Codable, Sendable, Equatable {
    public let name: String
    public let isDir: Bool
    public let changed: Bool

    public init(name: String, isDir: Bool, changed: Bool = false) {
        self.name = name
        self.isDir = isDir
        self.changed = changed
    }
}

/// A `readFile` reply. Content rides as base64 inside the JSON text frame;
/// `truncated` marks a size-cap cut, `binary` marks content the phone should
/// hand to Quick Look rather than render as text.
public struct WireFile: Codable, Sendable, Equatable {
    public let path: String
    public let base64: String
    public let size: Int
    public let binary: Bool
    public let truncated: Bool
    /// mtime in milliseconds — the base for conflict-checked writes.
    /// 0 when the serving peer predates the write plane.
    public let mtime: Int

    public init(path: String, base64: String, size: Int, binary: Bool, truncated: Bool, mtime: Int = 0) {
        self.path = path
        self.base64 = base64
        self.size = size
        self.binary = binary
        self.truncated = truncated
        self.mtime = mtime
    }

    public var data: Data? { Data(base64Encoded: base64) }
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
    /// One line of live activity — the tool a working turn is in, or what the
    /// agent is waiting on ("Working — Bash", "Waiting for you"). The phone
    /// shows it as the row's preview line, Messages-style. Optional so older
    /// peers that don't send it still decode; nil when there is nothing to say.
    public let subtitle: String?

    public init(id: String, title: String, agent: String, status: String, subtitle: String? = nil) {
        self.id = id
        self.title = title
        self.agent = agent
        self.status = status
        self.subtitle = subtitle
    }
}

/// One project and its sessions.
public struct RosterProject: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let path: String
    /// Current git branch of the checkout, nil for non-repos. Optional so
    /// older peers that don't send it still decode.
    public let branch: String?
    public let sessions: [RosterSession]

    public init(id: String, name: String, path: String, branch: String? = nil, sessions: [RosterSession]) {
        self.id = id
        self.name = name
        self.path = path
        self.branch = branch
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
