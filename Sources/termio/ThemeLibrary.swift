import Foundation
import GhosttyTheme

/// termio's terminal-theme catalog: the themes libghostty bundles, plus any the
/// user drops into termio's `Themes` folder.
///
/// A custom theme is just a Ghostty-format theme file — the same `key = value`
/// text Ghostty itself reads from `~/.config/ghostty/themes` (`background = #hex`,
/// `palette = 0=#hex`, …) — so the thousands of community color schemes work
/// unchanged. This is the VSCode/Zed model: drop a file into the folder and it
/// shows up in the theme pickers under "Custom", no rebuild, no registration.
///
/// A user theme shadows a bundled theme of the same name, so a file named
/// "Dracula" overrides the built-in one. Loading is lenient: a malformed file is
/// skipped rather than failing the whole load.
@MainActor
enum ThemeLibrary {
    /// Where users drop custom theme files, alongside termio's other support data
    /// (`~/Library/Application Support/termio/Themes`).
    static var directory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            .map { $0.appendingPathComponent("termio", isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".termio", isDirectory: true)
        return base.appendingPathComponent("Themes", isDirectory: true)
    }

    /// Custom themes parsed from `directory`, cached after the first load. Call
    /// `reload()` to pick up files added or edited while the app is running.
    private static var cachedUserThemes: [GhosttyThemeDefinition]?

    static var userThemes: [GhosttyThemeDefinition] {
        if let cachedUserThemes { return cachedUserThemes }
        let loaded = loadUserThemes()
        cachedUserThemes = loaded
        return loaded
    }

    /// Re-reads the `Themes` folder and refreshes the cache, returning the fresh
    /// list. The pickers call this on appear (so newly dropped files show up) and
    /// from a "Reload" button (so an edit to an open theme takes effect live).
    @discardableResult
    static func reload() -> [GhosttyThemeDefinition] {
        let loaded = loadUserThemes()
        cachedUserThemes = loaded
        return loaded
    }

    /// Resolves a theme by name. User themes are checked first so a custom file can
    /// shadow a bundled theme; otherwise the bundled catalog answers.
    static func theme(named name: String) -> GhosttyThemeDefinition? {
        userThemes.first { $0.name == name } ?? GhosttyThemeCatalog.theme(named: name)
    }

    /// Every bundled theme name, sorted — the picker's full "All Themes" list.
    /// Enumerating the catalog is not free, so it is computed once for the process.
    static let bundledThemeNames: [String] = GhosttyThemeCatalog.search("").map(\.name).sorted()

    /// A curated shortlist of widely-used themes, surfaced at the top of the pickers
    /// so the common picks are one glance away instead of buried in the 400+ bundled
    /// catalog. Kept in popularity order (not alphabetized) since that is what a
    /// quick-pick list is for. Filtered to names the catalog actually resolves, so a
    /// future package rename drops the stale entry instead of showing a dead row.
    static let popularThemeNames: [String] = [
        "Dracula",
        "Nord",
        "TokyoNight Storm",
        "Catppuccin Mocha",
        "Catppuccin Latte",
        "Gruvbox Dark",
        "Gruvbox Light",
        "Atom One Dark",
        "Monokai Pro",
        "Rose Pine",
        "Rose Pine Dawn",
        "Night Owl",
        "Ayu Mirage",
        "Snazzy",
        "Cobalt2",
        "GitHub Dark Default",
        "Tomorrow Night",
        "Nightfox",
        "Everforest Dark Hard",
        "iTerm2 Solarized Dark",
    ].filter { GhosttyThemeCatalog.theme(named: $0) != nil }

    /// Custom theme names, sorted — the picker's "Custom" group.
    static var userThemeNames: [String] {
        userThemes.map(\.name).sorted { $0.lowercased() < $1.lowercased() }
    }

    /// Creates the `Themes` folder if it does not exist yet and returns it, so
    /// "Open Themes Folder" always lands somewhere real even on a fresh install.
    @discardableResult
    static func ensureDirectoryExists() -> URL {
        let url = directory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func loadUserThemes() -> [GhosttyThemeDefinition] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.compactMap { url in
            guard url.hasDirectoryPath == false,
                  let contents = try? String(contentsOf: url, encoding: .utf8)
            else { return nil }
            // A theme's name is its file name (sans extension), matching how Ghostty
            // names themes after their file. Files may have no extension at all.
            return parse(name: url.deletingPathExtension().lastPathComponent, contents: contents)
        }
    }

    /// Parses one Ghostty-format theme file into a definition. Returns `nil` when
    /// the file lacks the background/foreground a usable theme needs. Hex values
    /// keep the catalog's bare (no leading `#`) convention so they flow through the
    /// existing `toTerminalConfiguration` and chrome-color paths unchanged.
    static func parse(name: String, contents: String) -> GhosttyThemeDefinition? {
        var background: String?
        var foreground: String?
        var cursorColor: String?
        var cursorText: String?
        var selectionBackground: String?
        var selectionForeground: String?
        var palette: [Int: String] = [:]

        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Ghostty config comments begin a line with `#`; a `#` mid-line is the
            // start of a hex value, not a comment.
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "background": background = strippedHex(value)
            case "foreground": foreground = strippedHex(value)
            case "cursor-color": cursorColor = strippedHex(value)
            case "cursor-text": cursorText = strippedHex(value)
            case "selection-background": selectionBackground = strippedHex(value)
            case "selection-foreground": selectionForeground = strippedHex(value)
            case "palette":
                // The value is itself `index=#hex`.
                guard let equals = value.firstIndex(of: "=") else { continue }
                let indexText = value[..<equals].trimmingCharacters(in: .whitespaces)
                let colorText = value[value.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                if let index = Int(indexText) {
                    palette[index] = strippedHex(colorText)
                }
            default:
                continue
            }
        }

        guard let background, let foreground else { return nil }
        return GhosttyThemeDefinition(
            name: name,
            background: background,
            foreground: foreground,
            cursorColor: cursorColor,
            cursorText: cursorText,
            selectionBackground: selectionBackground,
            selectionForeground: selectionForeground,
            palette: palette
        )
    }

    /// Drops a leading `#` so parsed hex matches the bundled catalog's bare form.
    private static func strippedHex(_ value: String) -> String {
        value.hasPrefix("#") ? String(value.dropFirst()) : value
    }
}
