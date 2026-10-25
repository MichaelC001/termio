import Foundation

/// What an app on a simulator said and how it died: its unified log, read with
/// `log show` inside the device, and the crash reports macOS writes for it.
/// Read on demand rather than captured from launch, so an app the agent did not
/// start through `termio sim launch` is covered too.
enum SimulatorDiagnostics {
    /// The largest reply a read may make — an agent reads this into its
    /// context, and a chatty app can log megabytes a minute.
    static let replyLimit = 100_000

    struct LogRead {
        let lines: [String]
        /// The last entry's timestamp: pass it back as `since` to read only
        /// what came after.
        let cursor: String?
        let truncated: Bool
    }

    /// `log show`'s levels, least to most severe; a read includes its level
    /// and every one above.
    static let levels = ["debug", "info", "default", "error", "fault"]

    /// Formats `log show --style ndjson` output: one line per entry, oldest
    /// first, keeping the last `tail` after `since` that contain `filter`.
    static func parseLog(
        _ ndjson: String, since: String?, tail: Int, minimumLevel: String, filter: String?
    ) -> LogRead {
        let floor = levels.firstIndex(of: minimumLevel) ?? 1
        var kept: [(timestamp: String, line: String)] = []
        for raw in ndjson.split(separator: "\n") {
            guard let data = raw.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  entry["eventType"] as? String == "logEvent",
                  let timestamp = entry["timestamp"] as? String
            else { continue }
            if let since, timestamp <= since { continue }
            let level = (entry["messageType"] as? String)?.lowercased() ?? "default"
            guard (levels.firstIndex(of: level) ?? 2) >= floor else { continue }
            let message = (entry["eventMessage"] as? String) ?? ""
            if let filter, !filter.isEmpty, !message.localizedCaseInsensitiveContains(filter) { continue }
            let subsystem = (entry["subsystem"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let category = (entry["category"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let source = [subsystem, category].compactMap { $0 }.joined(separator: ":")
            // "2026-10-24 19:18:11.403545-0700" → "19:18:11.403".
            let time = timestamp.split(separator: " ").dropFirst().first.map { String($0.prefix(12)) } ?? timestamp
            let line = "\(time) \(level)\(source.isEmpty ? "" : " [\(source)]") \(message)"
            kept.append((timestamp, line))
        }
        let window = kept.suffix(max(1, tail))
        var lines: [String] = []
        var size = 0
        var truncated = window.count < kept.count
        // Newest first while counting, so a cap keeps the recent end.
        for entry in window.reversed() {
            size += entry.line.utf8.count + 1
            if size > replyLimit {
                truncated = true
                break
            }
            lines.append(entry.line)
        }
        return LogRead(lines: lines.reversed(), cursor: kept.last?.timestamp, truncated: truncated)
    }

    /// The newest crash report for `executable` that ran on `udid`, summarised:
    /// the exception, the reason, and the crashed thread's frames. macOS writes
    /// the report a few seconds after the crash, sometimes much later.
    static func latestCrash(executable: String, udid: String, directory: URL? = nil) -> (summary: String, path: String)? {
        let folder = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        let candidates = names
            .filter { $0.hasPrefix("\(executable)-") && $0.hasSuffix(".ips") }
            .map { folder.appendingPathComponent($0) }
            .sorted { modified($0) > modified($1) }
        for url in candidates {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let summary = summarize(ips: text, udid: udid)
            else { continue }
            return (summary, url.path)
        }
        return nil
    }

    /// One `.ips` report: a header line of JSON, then the report as JSON. Nil
    /// when it is from another device, or not a crash report this can read.
    static func summarize(ips text: String, udid: String) -> String? {
        let parts = text.split(separator: "\n", maxSplits: 1)
        guard parts.count == 2,
              let header = try? JSONSerialization.jsonObject(with: Data(parts[0].utf8)) as? [String: Any],
              let body = try? JSONSerialization.jsonObject(with: Data(parts[1].utf8)) as? [String: Any],
              let path = body["procPath"] as? String, path.contains(udid)
        else { return nil }
        var lines: [String] = []
        let name = header["app_name"] as? String ?? body["procName"] as? String ?? "app"
        lines.append("\(name) crashed at \(header["timestamp"] as? String ?? "?")")
        if let exception = body["exception"] as? [String: Any] {
            let type = exception["type"] as? String ?? "?"
            let signal = exception["signal"] as? String
            lines.append("exception: \(type)\(signal.map { " (\($0))" } ?? "")")
        }
        if let termination = body["termination"] as? [String: Any], let indicator = termination["indicator"] as? String {
            lines.append("reason: \(indicator)")
        }
        if let asi = body["asi"] as? [String: [String]] {
            for message in asi.values.flatMap({ $0 }).prefix(3) { lines.append("message: \(message)") }
        }
        let images = (body["usedImages"] as? [[String: Any]]) ?? []
        if let threads = body["threads"] as? [[String: Any]] {
            let faulting = (body["faultingThread"] as? Int) ?? threads.firstIndex { $0["triggered"] as? Bool == true } ?? 0
            if faulting < threads.count, let frames = threads[faulting]["frames"] as? [[String: Any]] {
                lines.append("crashed thread \(faulting):")
                for (index, frame) in frames.prefix(25).enumerated() {
                    let image = (frame["imageIndex"] as? Int).flatMap { $0 < images.count ? images[$0]["name"] as? String : nil } ?? "?"
                    let symbol = frame["symbol"] as? String ?? String(format: "0x%llx", (frame["imageOffset"] as? Int) ?? 0)
                    // Compiler-generated thunks carry a file but no line; naming
                    // them is noise.
                    let location = (frame["sourceFile"] as? String).flatMap { file -> String? in
                        guard let line = frame["sourceLine"] as? Int, line > 0 else { return nil }
                        return " (\(file):\(line))"
                    } ?? ""
                    lines.append("  \(index) \(image) \(symbol)\(location)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func modified(_ url: URL) -> Date {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? .distantPast
    }
}

extension SimulatorHost {
    /// The app's log on `udid`, from the last `minutes`, or after `since`.
    func logs(
        udid: String, bundleID: String, since: String?, minutes: Int, tail: Int, level: String, filter: String?
    ) async throws -> SimulatorDiagnostics.LogRead {
        let executable = try await executableName(bundleID: bundleID, on: udid)
        var arguments = ["spawn", udid, "log", "show", "--style", "ndjson",
                         "--predicate", "process == \"\(executable)\""]
        if level == "debug" { arguments += ["--debug", "--info"] } else if level == "info" { arguments += ["--info"] }
        if let since, let start = since.split(separator: ".").first {
            arguments += ["--start", String(start)]
        } else {
            arguments += ["--last", "\(max(1, minutes))m"]
        }
        let output = try await simctl(arguments)
        return SimulatorDiagnostics.parseLog(output, since: since, tail: tail, minimumLevel: level, filter: filter)
    }

    /// The apps someone installed on `udid` — not Apple's — by name, for the
    /// logs drawer to pick from.
    func userApps(on udid: String) async throws -> [(name: String, bundleID: String)] {
        let output = try await simctl(["listapps", udid])
        // simctl prints an old-style property list, which the parser reads.
        guard let apps = try PropertyListSerialization.propertyList(from: Data(output.utf8), format: nil)
            as? [String: [String: Any]]
        else { throw SimulatorHostError.malformedReply }
        return apps.compactMap { bundleID, info in
            guard info["ApplicationType"] as? String == "User" else { return nil }
            let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? bundleID
            return (name, bundleID)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func crashReport(udid: String, bundleID: String) async throws -> (summary: String, path: String)? {
        let executable = try await executableName(bundleID: bundleID, on: udid)
        return SimulatorDiagnostics.latestCrash(executable: executable, udid: udid)
    }

    /// The process name an installed app runs as — its CFBundleExecutable —
    /// which is what both the log and the crash reports are keyed by.
    private func executableName(bundleID: String, on udid: String) async throws -> String {
        let container = try await simctl(["get_app_container", udid, bundleID, "app"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let plist = URL(fileURLWithPath: container).appendingPathComponent("Info.plist")
        guard let executable = NSDictionary(contentsOf: plist)?["CFBundleExecutable"] as? String else {
            throw SimulatorHostError.failed(localized("Couldn’t read \(bundleID)’s executable name."))
        }
        return executable
    }
}
