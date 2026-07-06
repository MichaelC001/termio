import Foundation

/// A project is a working directory (typically a git repo) that groups one or
/// more agent/terminal sessions, mirroring the sidebar grouping in unpeel.
struct Project: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String
    /// Absolute path used as the working directory for the project's sessions.
    var path: String
    /// Current git branch, shown in each session's top bar (display only for now).
    var branch: String
    var sessions: [Session]

    /// Optional sandbox configuration. `nil` (the default) runs this project's
    /// sessions directly on the host; a value runs them under an Apple Seatbelt profile
    /// (see `SeatbeltProfile`), which confines the agent's whole process tree.
    var sandbox: SandboxProfile?

    /// Whether the user has pinned this project to the top of the sidebar. Pinned
    /// projects always sort ahead of the rest, regardless of the chosen sort order
    /// (see `TermioStore.orderedProjects`).
    var pinned: Bool = false
}

extension Project {
    private enum CodingKeys: String, CodingKey {
        case id, name, path, branch, sessions, sandbox, pinned
    }

    /// Custom decoding so state files written before `pinned` existed still load: a
    /// missing flag defaults to not-pinned. Kept in an extension (not the main body)
    /// so the synthesized memberwise initializer survives for the call sites that
    /// build projects directly; encoding stays synthesized.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        branch = try container.decode(String.self, forKey: .branch)
        sessions = try container.decode([Session].self, forKey: .sessions)
        sandbox = try container.decodeIfPresent(SandboxProfile.self, forKey: .sandbox)
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }
}

/// What a new session launches: a plain login shell, or a coding agent CLI.
/// The `command` is fed to libghostty's `command` config (run instead of the
/// shell); the `icon` is shown in the new-session picker and the sidebar row.
enum AgentPreset: String, CaseIterable, Identifiable, Hashable, Codable {
    case terminal
    case claudeCode
    case codex
    case opencode
    case pi

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .terminal: return "Terminal"
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        case .pi: return "Pi"
        }
    }

    /// Program launched in the session, or `nil` for the user's login shell.
    /// The agent CLIs are expected on `PATH`; if missing, the terminal shows
    /// the shell's "command not found", which is the right place to surface it.
    var command: String? {
        switch self {
        case .terminal: return nil
        case .claudeCode: return "claude"
        case .codex: return "codex"
        case .opencode: return "opencode"
        case .pi: return "pi"
        }
    }

    /// The flag that makes this agent bypass its own permission/approval prompts —
    /// the "YOLO" switch. Each CLI spells it differently, so it lives on the preset
    /// rather than being hardcoded in the UI. `nil` for the plain shell and for
    /// agents whose bypass flag isn't stable enough to wire to a one-click toggle
    /// (OpenCode's is still in flight, Pi has none documented); those still accept
    /// any flag through the free-text command override. Composed onto the resolved
    /// command by `AppSettings.command(for:)` when the user flips the switch.
    var permissionBypassFlag: String? {
        switch self {
        case .claudeCode: return "--dangerously-skip-permissions"
        case .codex: return "--dangerously-bypass-approvals-and-sandbox"
        case .terminal, .opencode, .pi: return nil
        }
    }

    /// Arguments (a shell-ready fragment) that tell this agent to NOT run its own
    /// Seatbelt sandbox, because termio's per-project profile is the single enforcement
    /// layer wrapping the whole session. This is *required*, not an optimization: macOS
    /// forbids applying a second sandbox inside an existing one, so an agent's inner
    /// `sandbox-exec` would fail to initialize once termio has already sandboxed the
    /// session. `nil` for agents with no internal sandbox. Appended by `SandboxLauncher`.
    var sandboxStandDownArguments: String? {
        switch self {
        case .claudeCode: return "--settings '{\"sandbox\":{\"enabled\":false}}'"
        case .codex: return "--sandbox danger-full-access"
        case .terminal, .opencode, .pi: return nil
        }
    }

    /// Whether this agent lets termio pin its conversation id *up front*, so a relaunch
    /// resumes the exact prior session: Claude Code via `--session-id` (create) /
    /// `--resume` (resume), Pi via its idempotent `--session-id`.
    var usesPinnedResumeID: Bool { self == .claudeCode || self == .pi }

    /// Whether this agent's id can't be set up front but *can* be discovered afterward
    /// from its own session store and then resumed by id (Codex `resume <id>`, OpenCode
    /// `--session <id>`). See `AgentSessionStore.discover`. Until the id is discovered,
    /// `resumeArguments` falls back to "continue the most recent session in the dir".
    var usesDiscoveredResumeID: Bool { self == .codex || self == .opencode }

    /// Inputs the resume decision needs that only `TermioStore` can supply.
    struct ResumeContext {
        /// The stable id termio pinned for this session (meaningful only when
        /// `usesPinnedResumeID`).
        var resumeID: String
        /// Whether this session's agent has been launched in a prior app run.
        var launchedBefore: Bool
        /// Whether Claude Code already has a saved conversation under `resumeID`.
        /// Resuming one that doesn't exist errors ("No conversation found"), so a
        /// pinned-but-never-used session is (re)created with `--session-id` instead.
        var pinnedConversationExists: Bool
    }

    /// The argument fragment to append to the resolved base command so this session
    /// continues its prior conversation on relaunch, or `nil` to launch fresh. Two
    /// families (see `usesPinnedResumeID`): id-pinning agents resume an exact session,
    /// the others continue the most recent session in the working directory.
    func resumeArguments(_ context: ResumeContext) -> String? {
        switch self {
        case .terminal:
            return nil
        case .claudeCode:
            // `--session-id` creates a session with our id (and errors if it already
            // exists); `--resume` resumes it (and errors if it doesn't). So create on
            // the first launch / while no conversation has been saved, and resume once
            // one exists — handling a session that was opened but never used.
            return context.pinnedConversationExists
                ? "--resume \(context.resumeID)"
                : "--session-id \(context.resumeID)"
        case .pi:
            // Pi's `--session-id` creates the session when missing and resumes it
            // otherwise, so the same flag is correct on every launch.
            return "--session-id \(context.resumeID)"
        case .codex:
            // Resume the exact session once its id has been discovered (see
            // `usesDiscoveredResumeID`); until then continue the most recent recorded
            // session in this directory (`--last` filters by cwd by default).
            if !context.resumeID.isEmpty { return "resume \(context.resumeID)" }
            return context.launchedBefore ? "resume --last" : nil
        case .opencode:
            // As Codex: resume by id when known, else continue this directory's last session.
            if !context.resumeID.isEmpty { return "--session \(context.resumeID)" }
            return context.launchedBefore ? "--continue" : nil
        }
    }

    /// The glyph for this preset. The plain terminal uses a Hugeicons stroke mark
    /// (more refined than SF Symbols' terminal glyph); the coding agents use their
    /// vendor's real brand mark, which SF Symbols has no equivalent for — see
    /// `BrandLogo`.
    var icon: AgentIcon {
        switch self {
        case .terminal: return .hugeIcon(.terminal)
        case .claudeCode: return .brand(.claude)
        case .codex: return .brand(.codex)
        case .opencode: return .brandImage(.openCode)
        case .pi: return .brandImage(.pi)
        }
    }
}

/// How an agent's glyph is drawn: a built-in SF Symbol, a Hugeicons stroke mark,
/// a vector brand logo, or a vendor's real favicon image. SF Symbols ships no
/// Claude/OpenAI mark, so those are carried as vector path data and rendered by
/// `BrandLogoShape`; the Hugeicons marks are stroked by `HugeIconShape`. Pi and
/// OpenCode use their actual favicon files (see `BrandImageAsset`) because their
/// marks carry detail — Pi's adaptive monochrome glyph, OpenCode's two-tone box —
/// that a single-fill vector path can't reproduce.
enum AgentIcon: Hashable {
    case systemSymbol(String)
    case hugeIcon(HugeIcon)
    case brand(BrandLogo)
    case brandImage(BrandImageAsset)
}

/// A vendor brand mark carried as its real favicon image, bundled under
/// `Resources` and rendered by `BrandImageView`. Downloaded from each vendor's
/// site: Pi from `pi.dev/favicon.svg`, OpenCode from `opencode.ai`'s favicon.
/// Both are opaque dark app-icon tiles, so they read as small branded tiles.
enum BrandImageAsset: Hashable {
    case pi
    case openCode

    /// Base name of the bundled resource file (without extension).
    var resourceName: String {
        switch self {
        case .pi: return "pi-favicon"
        case .openCode: return "opencode-favicon"
        }
    }

    /// File extension of the bundled resource: Pi ships as a vector SVG, OpenCode
    /// only publishes a raster favicon.
    var fileExtension: String {
        switch self {
        case .pi: return "svg"
        case .openCode: return "png"
        }
    }
}

/// A Hugeicons stroke glyph, stored as its source SVG path data on a 24×24
/// viewBox. Unlike `BrandLogo` (filled vendor marks), these are drawn as a
/// rounded *stroke* by `HugeIconShape`, matching Hugeicons' 1.5px line style.
/// Multiple `<path>` elements from the source are concatenated into one data
/// string — each starts with `M`, so the parser treats them as separate subpaths.
enum HugeIcon: Hashable {
    case terminal
    case folder
    case folderOpen

    /// Side length of the source SVG's square viewBox (Hugeicons uses 24).
    var viewBox: CGFloat { 24 }

    var pathData: String {
        switch self {
        case .terminal:
            return "M7.5 7.5L8.72654 8.55719C9.24218 9.00163 9.5 9.22386 9.5 9.5C9.5 9.77614 9.24218 9.99836 8.72654 10.4428L7.5 11.5 M11.5 12.5H15.5 M12 21C15.7497 21 17.6246 21 18.9389 20.0451C19.3634 19.7367 19.7367 19.3634 20.0451 18.9389C21 17.6246 21 15.7497 21 12C21 8.25027 21 6.3754 20.0451 5.06107C19.7367 4.6366 19.3634 4.26331 18.9389 3.95491C17.6246 3 15.7497 3 12 3C8.25027 3 6.3754 3 5.06107 3.95491C4.6366 4.26331 4.26331 4.6366 3.95491 5.06107C3 6.3754 3 8.25027 3 12C3 15.7497 3 17.6246 3.95491 18.9389C4.26331 19.3634 4.6366 19.7367 5.06107 20.0451C6.3754 21 8.25027 21 12 21Z"
        case .folder:
            return "M8 7H16.75C18.8567 7 19.91 7 20.6667 7.50559C20.9943 7.72447 21.2755 8.00572 21.4944 8.33329C22 9.08996 22 10.1433 22 12.25C22 15.7612 22 17.5167 21.1573 18.7779C20.7926 19.3238 20.3238 19.7926 19.7779 20.1573C18.5167 21 16.7612 21 13.25 21H12C7.28595 21 4.92893 21 3.46447 19.5355C2 18.0711 2 15.714 2 11V7.94427C2 6.1278 2 5.21956 2.38032 4.53806C2.65142 4.05227 3.05227 3.65142 3.53806 3.38032C4.21956 3 5.1278 3 6.94427 3C8.10802 3 8.6899 3 9.19926 3.19101C10.3622 3.62712 10.8418 4.68358 11.3666 5.73313L12 7"
        case .folderOpen:
            // Hugeicons "folder-03": a single smooth rounded tray (the open body)
            // plus a simple tabbed back flap. Chosen over "folder-open" — whose two
            // stacked, flared trapezoids turn muddy at the sidebar's small size —
            // because the one rounded body reads cleanly there and still pairs with
            // folder-01's angled tab for the closed state.
            return "M2.36064 15.1788C1.98502 13.2956 1.79721 12.354 2.33084 11.7159C2.36642 11.6734 2.40405 11.6323 2.44361 11.5927C3.03686 11 4.08674 11 6.1865 11H17.8135C19.9133 11 20.9631 11 21.5564 11.5927C21.5959 11.6323 21.6336 11.6734 21.6692 11.7159C22.2028 12.354 22.015 13.2956 21.6394 15.1788C21.0993 17.8865 20.8292 19.2404 19.8109 20.0721C19.7414 20.1288 19.6698 20.1833 19.5961 20.2354C18.5163 21 17.0068 21 13.9876 21H10.0124C6.99323 21 5.48367 21 4.40387 20.2354C4.33022 20.1833 4.2586 20.1288 4.18914 20.0721C3.17075 19.2404 2.90072 17.8865 2.36064 15.1788Z M4 11V5.5C4 4.11929 5.11929 3 6.5 3H8.92963C9.59834 3 10.2228 3.3342 10.5937 3.8906L12 6M12 6H8.5M12 6H17.5C18.8807 6 20 7.11929 20 8.5V11"
        }
    }
}

/// A vendor brand mark, stored as its official SVG path so it renders crisp at any
/// size without shipping binary image assets. Rendered in the vendor's brand color
/// by `BrandLogoShape`; see `BrandLogo.tint`. Pi and OpenCode are not here — their
/// marks ship as real favicon images via `BrandImageAsset`.
enum BrandLogo: Hashable {
    case claude
    case codex

    /// Side length of the source SVG's square viewBox (both marks use 24).
    var viewBox: CGFloat { 24 }

    /// Whether the mark's holes are cut with the even-odd fill rule. Codex's mark
    /// (from lobehub) declares `fill-rule="evenodd"` to carve the `</` and `_`
    /// glyphs out of the rounded blob; Claude's single outline needs nonzero.
    var usesEvenOddFill: Bool {
        switch self {
        case .codex: return true
        case .claude: return false
        }
    }

    var pathData: String {
        switch self {
        case .claude:
            return "m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z"
        case .codex:
            // OpenAI Codex mark (lobehub.com): a rounded blob with `</` and `_`
            // glyphs cut out via even-odd fill. Source viewBox 24, `currentColor`.
            return "M8.086.457a6.105 6.105 0 013.046-.415c1.333.153 2.521.72 3.564 1.7a.117.117 0 00.107.029c1.408-.346 2.762-.224 4.061.366l.063.03.154.076c1.357.703 2.33 1.77 2.918 3.198.278.679.418 1.388.421 2.126a5.655 5.655 0 01-.18 1.631.167.167 0 00.04.155 5.982 5.982 0 011.578 2.891c.385 1.901-.01 3.615-1.183 5.14l-.182.22a6.063 6.063 0 01-2.934 1.851.162.162 0 00-.108.102c-.255.736-.511 1.364-.987 1.992-1.199 1.582-2.962 2.462-4.948 2.451-1.583-.008-2.986-.587-4.21-1.736a.145.145 0 00-.14-.032c-.518.167-1.04.191-1.604.185a5.924 5.924 0 01-2.595-.622 6.058 6.058 0 01-2.146-1.781c-.203-.269-.404-.522-.551-.821a7.74 7.74 0 01-.495-1.283 6.11 6.11 0 01-.017-3.064.166.166 0 00.008-.074.115.115 0 00-.037-.064 5.958 5.958 0 01-1.38-2.202 5.196 5.196 0 01-.333-1.589 6.915 6.915 0 01.188-2.132c.45-1.484 1.309-2.648 2.577-3.493.282-.188.55-.334.802-.438.286-.12.573-.22.861-.304a.129.129 0 00.087-.087A6.016 6.016 0 015.635 2.31C6.315 1.464 7.132.846 8.086.457zm-.804 7.85a.848.848 0 00-1.473.842l1.694 2.965-1.688 2.848a.849.849 0 001.46.864l1.94-3.272a.849.849 0 00.007-.854l-1.94-3.393zm5.446 6.24a.849.849 0 000 1.695h4.848a.849.849 0 000-1.696h-4.848z"
        }
    }
}

/// A session's live activity, shown as a dot in the sidebar and aggregated into
/// the menu-bar pulse. Driven by two layers: the zero-config libghostty surface
/// signals the `TerminalViewState` publishes (bell / desktop notification), and,
/// when enabled, the per-agent hooks reported into `HookListener`.
///
/// The four states follow the cleanest model among the reference tools
/// (open-vibe-island): a finished turn is `done`, *not* "needs you" —
/// `needsAttention` is reserved for an agent actually blocked on the user (a
/// permission prompt or a desktop notification / bell). This keeps "the agent is
/// ready for you" (calm) distinct from "the agent is waiting on you" (urgent).
enum SessionStatus: Hashable {
    /// Nothing pending, or the user is already looking at the session.
    case idle
    /// The agent is actively processing a turn (shown as the spinning icon).
    case working
    /// The agent finished its turn while the user was elsewhere — a calm
    /// "ready for you" cue, not a demand.
    case done
    /// The agent is blocked waiting on the user (permission prompt, or a bell /
    /// desktop notification it raised). The one state that demands attention.
    case needsAttention

    /// SF Symbol drawn as the status dot in the sidebar and the per-session row
    /// in the menu-bar roster.
    var symbolName: String {
        switch self {
        case .idle: return "circle.fill"
        case .working: return "circle.dotted"
        case .done: return "circle.fill"
        case .needsAttention: return "exclamationmark.circle.fill"
        }
    }
}

/// A single terminal session within a project. Each session owns one live
/// libghostty terminal surface (see `TermioStore.surface(for:in:)`).
struct Session: Identifiable, Hashable, Codable {
    var id = UUID()
    var title: String
    /// Which agent (or plain shell) this session runs.
    var agent: AgentPreset
    var createdAt: Date

    /// Absolute path of a git worktree this session runs in, or `nil` (the common
    /// case) to run directly in the project's directory. termio no longer creates
    /// worktrees itself — a worktree is just a folder the user opens as a project —
    /// but the field is honored so any session persisted from an older build still
    /// launches in its recorded directory.
    var worktreePath: String?

    /// The stable id termio hands the agent so a relaunch resumes *this exact*
    /// conversation rather than starting a new one. Assigned on first launch for
    /// agents that can pin their session id (Claude Code, Pi — see
    /// `AgentPreset.usesPinnedResumeID`) and `nil` otherwise; Codex/OpenCode resume the
    /// most recent session in the directory and never need one. Persisted, so it
    /// survives the app quitting.
    var resumeID: String?

    /// Whether this session's agent has been launched at least once (in this or a
    /// prior run). Persisted so that on the next launch the agent is resumed instead of
    /// started fresh.
    var launched = false

    /// The last meaningful terminal title (`OSC 0/2`) the session's agent reported,
    /// e.g. Claude Code's conversation topic. Persisted so the sidebar keeps the
    /// adopted label across app restarts — the agent only re-emits a title once it
    /// is actively conversing again, which used to leave every row back at the
    /// default agent name after a relaunch. Display-only; `title` stays untouched.
    var liveTitle: String?

    /// When the agent was first launched, used to correlate Codex/OpenCode's own
    /// session record (matched by working directory) back to *this* session — their
    /// CLIs won't accept an id up front, so the id is discovered afterward from the
    /// record created at this moment (see `AgentSessionStore.discover`). `nil` until
    /// first launch, and unused by the pinned-id agents (Claude Code, Pi).
    var launchedAt: Date?

    /// Program passed to libghostty's `command` config; derived from `agent`.
    /// User overrides and the resume arguments are resolved in `TermioStore` via
    /// `AppSettings.command(for:)` and `AgentPreset.resumeArguments(_:)`.
    var command: String? { agent.command }

    init(title: String, agent: AgentPreset = .terminal, createdAt: Date = Date()) {
        self.title = title
        self.agent = agent
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, agent, createdAt, worktreePath, resumeID, launched, launchedAt,
             liveTitle
    }

    /// Custom decoding so state files written before the resume fields existed still
    /// load: the new keys default to "no id, never launched", which makes an upgraded
    /// session start fresh once and then be resumable from then on. (Encoding stays
    /// synthesized.)
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        agent = try container.decode(AgentPreset.self, forKey: .agent)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        worktreePath = try container.decodeIfPresent(String.self, forKey: .worktreePath)
        resumeID = try container.decodeIfPresent(String.self, forKey: .resumeID)
        launched = try container.decodeIfPresent(Bool.self, forKey: .launched) ?? false
        launchedAt = try container.decodeIfPresent(Date.self, forKey: .launchedAt)
        liveTitle = try container.decodeIfPresent(String.self, forKey: .liveTitle)
    }
}

extension Project {
    /// First-run state for a fresh install: a single Home project with one shell
    /// session rooted at the user's home directory, so a new user lands in a
    /// working terminal instead of dev-machine placeholders.
    ///
    /// The working directory must be the home directory — never
    /// `currentDirectoryPath`, which is `/` when the app is launched from Finder
    /// (that is what left the shell sitting at `/ %` on first launch).
    static func firstRunProjects() -> [Project] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        return [
            Project(
                name: "home",
                path: home,
                branch: "—",
                sessions: [
                    Session(title: "shell"),
                ]
            ),
        ]
    }
}
