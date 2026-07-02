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
