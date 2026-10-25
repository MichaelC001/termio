import Foundation
import os

/// The helper's half of the line protocol with the app: one JSON object per line
/// in each direction over stdio. A request carries an `id` the reply echoes; an
/// event (`frame`, `detached`) carries none. Stdout is the only channel that
/// reaches the app, so every write goes through one lock — replies and frame
/// ticks come from different tasks, and two of them interleaving mid-line would
/// hand the app a line that is neither.
enum Wire {
    private static let lock = OSAllocatedUnfairLock()

    static func reply(_ id: Int, result: [String: Any]) {
        write(["id": id, "ok": true, "result": result])
    }

    static func fail(_ id: Int, _ message: String) {
        write(["id": id, "ok": false, "error": message])
    }

    static func event(_ name: String, _ fields: [String: Any] = [:]) {
        var line = fields
        line["event"] = name
        write(line)
    }

    /// A reply whose result is already encoded JSON (an accessibility document),
    /// spliced in rather than decoded and re-encoded.
    static func reply(_ id: Int, rawResult: Data) {
        var line = Data("{\"id\":\(id),\"ok\":true,\"result\":".utf8)
        line.append(rawResult)
        line.append(Data("}\n".utf8))
        let finished = line
        lock.withLock { FileHandle.standardOutput.write(finished) }
    }

    private static func write(_ object: [String: Any]) {
        guard var line = try? JSONSerialization.data(withJSONObject: object) else {
            log("dropped an unencodable line")
            return
        }
        line.append(0x0A)
        let finished = line
        lock.withLock { FileHandle.standardOutput.write(finished) }
    }

    /// Stderr is the helper's log: the app forwards it to its own log, so a
    /// failure inside the private frameworks is readable after the fact.
    static func log(_ message: String) {
        FileHandle.standardError.write(Data("termio-sim: \(message)\n".utf8))
    }
}

/// One decoded request line. Parameters stay untyped because every op takes a
/// different handful; the accessors below fail loudly instead of defaulting, so a
/// malformed request is answered with what was missing.
struct Request {
    let id: Int
    let op: String
    let parameters: [String: Any]

    init?(line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let id = object["id"] as? Int, let op = object["op"] as? String
        else { return nil }
        self.id = id
        self.op = op
        self.parameters = object
    }

    func string(_ key: String) throws -> String {
        guard let value = parameters[key] as? String, !value.isEmpty else {
            throw HelperError.missing(key)
        }
        return value
    }

    func optionalString(_ key: String) -> String? {
        (parameters[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Points and counts. Bounded, because idb turns them into integers and
    /// nanoseconds, and a value past those traps — taking the shared helper,
    /// and every device it drives, down with it.
    func number(_ key: String) throws -> Double {
        guard let value = parameters[key] as? NSNumber else { throw HelperError.missing(key) }
        return try Self.bounded(value.doubleValue, key, limit: 100_000)
    }

    func optionalNumber(_ key: String) throws -> Double? {
        guard let value = parameters[key] as? NSNumber else { return nil }
        return try Self.bounded(value.doubleValue, key, limit: 100_000)
    }

    /// Seconds, at most a minute.
    func duration(_ key: String) throws -> Double? {
        guard let value = parameters[key] as? NSNumber else { return nil }
        return try Self.bounded(value.doubleValue, key, limit: 60)
    }

    private static func bounded(_ value: Double, _ key: String, limit: Double) throws -> Double {
        guard value.isFinite, abs(value) <= limit else { throw HelperError.outOfRange(key, limit) }
        return value
    }
}

enum HelperError: LocalizedError {
    case missing(String)
    case outOfRange(String, Double)
    case unknownOperation(String)
    case noSuchDevice(String)
    case notBooted(String, String)
    case notAttached(String)
    case unknownButton(String)
    case unknownKey(String)
    case screenshotFailed(String)
    case pathTooLong
    case noElement(String)

    var errorDescription: String? {
        switch self {
        case .missing(let key): "missing parameter '\(key)'"
        case .outOfRange(let key, let limit): "'\(key)' must be a finite number no larger than \(Int(limit))"
        case .unknownOperation(let op): "unknown op '\(op)'"
        case .noSuchDevice(let udid): "no simulator with UDID \(udid)"
        case .notBooted(let udid, let state): "simulator \(udid) is not booted (state: \(state))"
        case .notAttached(let udid): "simulator \(udid) has no display attached"
        case .unknownButton(let name): "unknown button '\(name)'"
        case .unknownKey(let name): "unknown key '\(name)'"
        case .screenshotFailed(let path): "could not write a screenshot to \(path)"
        case .pathTooLong: "the path's dt_ms add up to more than 30 seconds"
        case .noElement(let label): "no element on screen has a label containing \"\(label)\""
        }
    }
}
