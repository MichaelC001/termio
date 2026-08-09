import Foundation

/// The slice of a user's Ghostty configuration termio inherits: font and theme. Parsed once at
/// launch and layered *under* termio's own settings via the UserDefaults registration domain
/// (see `AppSettings.init`) — a value set in termio always wins, Ghostty fills what termio never
/// touched, and the built-in defaults back both. No Ghostty install means an empty config and
/// the built-ins stand untouched.
///
/// Only top-level `key = value` lines are read; `config-file` includes are deliberately not
/// followed — this is a launch-time convenience, not a reimplementation of Ghostty's loader.
struct GhosttyUserConfig {
    /// `font-family` values in declaration order — Ghostty treats repeats as a fallback chain
    /// and an empty value as a chain reset. The first entry is the primary face.
    var fontFamilies: [String] = []
    var fontSize: Double?
    /// `theme` verbatim: a bare name, or Ghostty's `light:Name,dark:Name` split form.
    var theme: String?

    var isEmpty: Bool { fontFamilies.isEmpty && fontSize == nil && theme == nil }

    /// The theme name for each appearance. A bare name applies to both, matching Ghostty.
    var themeNames: (light: String?, dark: String?) {
        guard let theme else { return (nil, nil) }
        guard theme.contains(":") else { return (theme, theme) }
        var light: String?
        var dark: String?
        for part in theme.split(separator: ",") {
            let pair = part.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let mode = pair[0].trimmingCharacters(in: .whitespaces)
            let name = pair[1].trimmingCharacters(in: .whitespaces)
            if mode == "light" { light = name }
            if mode == "dark" { dark = name }
        }
        return (light, dark)
    }

    /// Reads the files Ghostty itself loads on macOS, in Ghostty's order — the XDG file first,
    /// the Application Support file after, so the latter wins for single-value keys while
    /// `font-family` keeps accumulating across both.
    static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     environment: [String: String] = ProcessInfo.processInfo.environment) -> GhosttyUserConfig {
        let xdgBase = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".config")
        let paths = [
            xdgBase.appendingPathComponent("ghostty/config"),
            home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty/config"),
        ]
        var config = GhosttyUserConfig()
        for path in paths {
            guard let text = try? String(contentsOf: path, encoding: .utf8) else { continue }
            config.merge(parsing: text)
        }
        return config
    }

    /// Folds one config file's text into the receiver: later lines win for single-value keys,
    /// `font-family` accumulates, comments and unknown keys are skipped.
    mutating func merge(parsing text: String) {
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            switch key {
            case "font-family":
                if value.isEmpty {
                    fontFamilies = []
                } else if !fontFamilies.contains(value) {
                    // Deduped: Ghostty's two config files often repeat the same face, and a
                    // duplicate fallback buys nothing.
                    fontFamilies.append(value)
                }
            case "font-size":
                fontSize = Double(value)
            case "theme":
                theme = value.isEmpty ? nil : value
            default:
                break
            }
        }
    }
}
