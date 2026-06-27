import Combine
import Foundation

/// Terminal cursor shape. Raw values are deliberately the exact Ghostty config
/// tokens, so persistence, the settings picker, and the `TermioStore` mapping all
/// share one type without any string literals drifting apart.
enum CursorStyle: String, CaseIterable, Identifiable {
    case block
    case bar
    case underline

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .block: return "Block"
        case .bar: return "Bar"
        case .underline: return "Underline"
        }
    }
}

/// App-wide, persisted preferences. Plain values only — the translation into
/// libghostty configuration lives in `TermioStore`, so this type stays free of
/// terminal-core types and is trivial to read, test, and persist.
///
/// Backed by `UserDefaults`: every property writes through on change (`didSet`),
/// and `registerDefaults()` seeds the fallbacks so a fresh install reads sensible
/// values without special-casing "unset" everywhere. `objectWillChange` (from
/// `@Published`) is what `TermioStore` listens to in order to re-apply appearance
/// to already-open terminals.
@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    private enum Key {
        static let fontFamily = "appearance.fontFamily"
        static let fontSize = "appearance.fontSize"
        static let fontThicken = "appearance.fontThicken"
        static let themeName = "appearance.themeName"
        static let cursorStyle = "appearance.cursorStyle"
        static let cursorBlink = "appearance.cursorBlink"
        static let windowPadding = "appearance.windowPadding"
        static let backgroundOpacity = "appearance.backgroundOpacity"
        static let backgroundBlur = "appearance.backgroundBlur"
        static let scrollbackMegabytes = "terminal.scrollbackMegabytes"
        static let copyOnSelect = "terminal.copyOnSelect"
        static let interfaceFontFamily = "interface.fontFamily"
        static let interfaceFontSize = "interface.fontSize"
        static let interfaceRowPadding = "interface.rowPadding"
        static let agentCommands = "agents.commandOverrides"
        static let disabledAgents = "agents.disabled"
        static let worktreeEnabled = "worktree.enabled"
        static let worktreeBaseDirectory = "worktree.baseDirectory"
        static let worktreeBranchPrefix = "worktree.branchPrefix"
    }

    // MARK: Appearance

    /// Terminal font family. Empty means "let libghostty pick its default
    /// monospace", so we never force a face the user doesn't have installed.
    @Published var fontFamily: String {
        didSet { defaults.set(fontFamily, forKey: Key.fontFamily) }
    }

    @Published var fontSize: Double {
        didSet { defaults.set(fontSize, forKey: Key.fontSize) }
    }

    /// Synthesizes a heavier weight by drawing glyphs slightly thicker — a small
    /// readability win on long agent transcripts.
    @Published var fontThicken: Bool {
        didSet { defaults.set(fontThicken, forKey: Key.fontThicken) }
    }

    /// Name of a Ghostty bundled theme, or empty for the terminal core's default
    /// colors. Resolved against `GhosttyThemeCatalog` in `TermioStore`.
    @Published var themeName: String {
        didSet { defaults.set(themeName, forKey: Key.themeName) }
    }

    /// Cursor shape. The app-side `CursorStyle` keeps this type free of
    /// terminal-core types while staying type-safe end to end; it persists as its
    /// raw token and `TermioStore` maps it to libghostty.
    @Published var cursorStyle: CursorStyle {
        didSet { defaults.set(cursorStyle.rawValue, forKey: Key.cursorStyle) }
    }

    @Published var cursorBlink: Bool {
        didSet { defaults.set(cursorBlink, forKey: Key.cursorBlink) }
    }

    /// Inset (points) between the terminal grid and the window edge, applied on
    /// both axes. Comfort spacing so agent output doesn't run into the chrome.
    @Published var windowPadding: Int {
        didSet { defaults.set(windowPadding, forKey: Key.windowPadding) }
    }

    /// Terminal background alpha (0.2–1.0). Below 1.0 the window goes non-opaque
    /// so the desktop shows through; 1.0 keeps the normal solid look.
    @Published var backgroundOpacity: Double {
        didSet { defaults.set(backgroundOpacity, forKey: Key.backgroundOpacity) }
    }

    /// Blur radius applied behind a translucent background (0 = off). Only visible
    /// when `backgroundOpacity` is below 1.0.
    @Published var backgroundBlur: Int {
        didSet { defaults.set(backgroundBlur, forKey: Key.backgroundBlur) }
    }

    // MARK: Terminal

    /// Scrollback buffer size in megabytes. Agents emit a lot of output, so the
    /// default history is generous; capped to keep memory bounded.
    @Published var scrollbackMegabytes: Int {
        didSet { defaults.set(scrollbackMegabytes, forKey: Key.scrollbackMegabytes) }
    }

    /// When on, selecting text copies it straight to the system clipboard.
    @Published var copyOnSelect: Bool {
        didSet { defaults.set(copyOnSelect, forKey: Key.copyOnSelect) }
    }

    // MARK: Interface

    /// Font family for the app's own chrome (the project/session sidebar). Empty
    /// means the system UI font. Unlike the terminal font this need not be
    /// monospaced.
    @Published var interfaceFontFamily: String {
        didSet { defaults.set(interfaceFontFamily, forKey: Key.interfaceFontFamily) }
    }

    @Published var interfaceFontSize: Double {
        didSet { defaults.set(interfaceFontSize, forKey: Key.interfaceFontSize) }
    }

    /// Vertical padding (points) on each sidebar row — the VSCode-style density
    /// control, from compact to roomy.
    @Published var interfaceRowPadding: Double {
        didSet { defaults.set(interfaceRowPadding, forKey: Key.interfaceRowPadding) }
    }

    // MARK: Agents

    /// Per-agent command overrides keyed by `AgentPreset.rawValue`. An entry lets
    /// the user run, say, `claude --dangerously-skip-permissions` instead of the
    /// built-in default. An empty/whitespace value is treated as "no override".
    @Published var agentCommandOverrides: [String: String] {
        didSet { defaults.set(agentCommandOverrides, forKey: Key.agentCommands) }
    }

    /// Agent presets hidden from the sidebar quick-add row, by `rawValue`. Stored
    /// as the disabled set so the default (nothing stored) means "all enabled".
    @Published var disabledAgents: Set<String> {
        didSet { defaults.set(Array(disabledAgents), forKey: Key.disabledAgents) }
    }

    // MARK: Worktree

    /// When enabled, a new session in a git project runs in its own `git worktree`
    /// so an agent's edits stay isolated on a branch instead of mutating the
    /// project's checked-out tree.
    @Published var worktreeEnabled: Bool {
        didSet { defaults.set(worktreeEnabled, forKey: Key.worktreeEnabled) }
    }

    /// Where worktrees are created. An absolute path is used as-is; a relative one
    /// is resolved against each project's directory (so the default keeps worktrees
    /// next to, but outside, the repo).
    @Published var worktreeBaseDirectory: String {
        didSet { defaults.set(worktreeBaseDirectory, forKey: Key.worktreeBaseDirectory) }
    }

    /// Prefix for the branch each worktree is created on (branch name is the prefix
    /// plus a slug of the session title).
    @Published var worktreeBranchPrefix: String {
        didSet { defaults.set(worktreeBranchPrefix, forKey: Key.worktreeBranchPrefix) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.fontFamily: "",
            Key.fontSize: 13.0,
            Key.fontThicken: false,
            Key.themeName: "",
            Key.cursorStyle: "block",
            Key.cursorBlink: true,
            Key.windowPadding: 2,
            Key.backgroundOpacity: 1.0,
            Key.backgroundBlur: 0,
            Key.scrollbackMegabytes: 10,
            Key.copyOnSelect: false,
            Key.interfaceFontFamily: "",
            Key.interfaceFontSize: 13.0,
            Key.interfaceRowPadding: 3.0,
            Key.worktreeEnabled: false,
            Key.worktreeBaseDirectory: "../.termio-worktrees",
            Key.worktreeBranchPrefix: "termio/",
        ])

        fontFamily = defaults.string(forKey: Key.fontFamily) ?? ""
        fontSize = defaults.double(forKey: Key.fontSize)
        fontThicken = defaults.bool(forKey: Key.fontThicken)
        themeName = defaults.string(forKey: Key.themeName) ?? ""
        cursorStyle = defaults.string(forKey: Key.cursorStyle).flatMap(CursorStyle.init) ?? .block
        cursorBlink = defaults.bool(forKey: Key.cursorBlink)
        windowPadding = defaults.integer(forKey: Key.windowPadding)
        backgroundOpacity = defaults.double(forKey: Key.backgroundOpacity)
        backgroundBlur = defaults.integer(forKey: Key.backgroundBlur)
        scrollbackMegabytes = defaults.integer(forKey: Key.scrollbackMegabytes)
        copyOnSelect = defaults.bool(forKey: Key.copyOnSelect)
        interfaceFontFamily = defaults.string(forKey: Key.interfaceFontFamily) ?? ""
        interfaceFontSize = defaults.double(forKey: Key.interfaceFontSize)
        interfaceRowPadding = defaults.double(forKey: Key.interfaceRowPadding)
        agentCommandOverrides = defaults.dictionary(forKey: Key.agentCommands) as? [String: String] ?? [:]
        disabledAgents = Set(defaults.stringArray(forKey: Key.disabledAgents) ?? [])
        worktreeEnabled = defaults.bool(forKey: Key.worktreeEnabled)
        worktreeBaseDirectory = defaults.string(forKey: Key.worktreeBaseDirectory) ?? "../.termio-worktrees"
        worktreeBranchPrefix = defaults.string(forKey: Key.worktreeBranchPrefix) ?? "termio/"
    }

    /// Effective command for an agent: the user's override if it's non-empty,
    /// otherwise the preset's built-in default (`nil` for a plain login shell).
    func command(for agent: AgentPreset) -> String? {
        let override = agentCommandOverrides[agent.rawValue]?.trimmingCharacters(in: .whitespaces)
        if let override, !override.isEmpty { return override }
        return agent.command
    }

    func isAgentEnabled(_ agent: AgentPreset) -> Bool {
        !disabledAgents.contains(agent.rawValue)
    }

    func setAgent(_ agent: AgentPreset, enabled: Bool) {
        if enabled {
            disabledAgents.remove(agent.rawValue)
        } else {
            disabledAgents.insert(agent.rawValue)
        }
    }
}
