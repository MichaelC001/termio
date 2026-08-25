import Darwin
import Foundation

/// A normalized status report sent by an agent's hook into termio's local socket.
/// The agent-specific knowledge ("this lifecycle event means the agent is now
/// working") is baked into the hook command installed per agent, so every agent
/// speaks the same tiny vocabulary and termio needs no per-agent parsing:
///
/// - `termioSession` — the `TERMIO_SESSION` env value termio stamped into the PTY
///   (see `TermioStore.surface`), echoed back so the event maps to the exact
///   session even when several share one project directory.
/// - `state` — one of `working` / `attention` / `done` / `idle`.
/// - `cwd` — the agent's working directory, a correlation fallback for any agent
///   whose environment didn't carry `TERMIO_SESSION` through to the hook.
struct StatusReport: Decodable {
    let termioSession: String?
    let state: String
    let tool: String?
    let cwd: String?
    /// The agent's own conversation log for this session (Claude Code's
    /// `transcript_path`), forwarded by the hook so termio can hand a caller the
    /// address of the raw Q&A instead of scraping the terminal. Absent for agents
    /// whose hook doesn't carry it.
    let transcriptPath: String?
    /// The agent's own id for the conversation this session is currently writing,
    /// forwarded by hooks/plugins whose host exposes it (the manifest's
    /// `hooks.conversation` locator). Lets termio advance the resume pin the moment
    /// the agent rotates conversations in-process (`/new`), without needing the id
    /// to be encoded in a transcript filename. Absent for identity-blind hooks.
    let conversationID: String?
    /// Raw first-prompt title candidate forwarded by hook hosts that expose one.
    /// `TermioStore` normalizes and bounds it before persisting anything.
    let promptTitle: String?

    private enum CodingKeys: String, CodingKey {
        case termioSession = "termio_session"
        case state
        case tool
        case cwd
        case transcriptPath = "transcript_path"
        case conversationID = "conversation_id"
        case promptTitle = "prompt_title"
    }
}

/// Turns an agent hook's raw user prompt into a quiet sidebar fallback. This is
/// intentionally deterministic: hooks run before the model, so the title must be
/// available immediately without another request or a transcript-format dependency.
enum AgentPromptTitle {
    static let maximumLength = 64

    /// Markdown a prompt often opens with. It decorates; it never names the topic.
    private static let decoration: Set<Character> = ["#", ">", "*", "-", "•", "`"]

    static func normalized(_ raw: String) -> String? {
        let collapsed = raw.split(whereSeparator: isNoise).joined(separator: " ")
        let title = collapsed.drop { decoration.contains($0) || $0 == " " }
        guard !title.isEmpty else { return nil }
        guard title.count > maximumLength else { return String(title) }
        return bounded(title) + "…"
    }

    /// A control character travels in a prompt as literally as a newline does, and on
    /// one sidebar line both are noise rather than text.
    private static func isNoise(_ character: Character) -> Bool {
        character.isWhitespace
            || character.unicodeScalars.allSatisfy(CharacterSet.controlCharacters.contains)
    }

    /// Cuts to fit, preferring a word boundary — but only one past the halfway mark,
    /// so a long opening word cannot shrink the label to a syllable.
    private static func bounded(_ title: Substring) -> String {
        let head = title.prefix(maximumLength - 1)
        guard let lastSpace = head.lastIndex(of: " "),
              head.distance(from: head.startIndex, to: lastSpace) >= maximumLength / 2
        else { return String(head) }
        return String(head[..<lastSpace])
    }
}

/// A local Unix-domain socket that agent hooks report into. This is what gives
/// termio per-turn activity ("working", the rotating spinner): the zero-config
/// bell/OSC signals fire on command *finish*, never *start*, so "is the agent
/// thinking right now" can't be inferred from them alone. Each agent's hook
/// command (installed by `AgentStatusHooks`) pipes a `StatusReport` straight here.
///
/// This type owns only the transport: it decodes one `StatusReport` per connection
/// and hands it to `onReport` on the main actor. Correlating a report to a session
/// and the resulting state transition live in `TermioStore`.
final class HookListener {
    /// The socket file, under termio's Application Support directory — the same
    /// place the session tree is saved.
    static var socketURL: URL {
        AppChannel.supportDirectory.appendingPathComponent("agent-status.sock")
    }

    private let onReport: @MainActor (StatusReport) -> Void
    private let queue = DispatchQueue(label: "com.termio.hook-listener")
    private var source: DispatchSourceRead?
    private var listenDescriptor: Int32 = -1
    /// Watches the socket *file* we bound, so an instance that loses the path to
    /// someone else's `unlink` finds out (see `LocalSocket.watchForReplacement`).
    private var pathWatch: DispatchSourceFileSystemObject?
    /// Runs only while another instance holds the path, and takes it back when
    /// that one goes away (see `LocalSocket.retryWhenFree`).
    private var reclaim: DispatchSourceTimer?

    init(onReport: @escaping @MainActor (StatusReport) -> Void) {
        self.onReport = onReport
    }

    /// Binds the socket and begins accepting connections. All socket work happens
    /// on a private serial queue; failures are logged and degrade to "no hook
    /// signal" rather than trapping, per the project's no-crash rule.
    func start() {
        queue.async { [weak self] in self?.bindAndListen() }
    }

    private func bindAndListen() {
        let url = Self.socketURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let path = url.path
        // Only clear a socket file nothing is listening on — the same guard session
        // control uses, and for a worse failure. Unlinking whatever is there lets a
        // second instance steal the channel: the running app keeps its now-unnamed
        // socket, every hook connects to the new file, and once the thief exits the
        // file it leaves behind refuses every connection. Hooks fire constantly, so
        // the command they run ends in `2>/dev/null || true` and cannot say a word
        // about it — the status plane just goes quiet, permanently, with agents
        // still working and every row calm.
        if LocalSocket.isLive(path) {
            Self.log("""
                another termio already answers at \(path) — leaving agent status to it \
                (relaunch this process with TERMIO_CHANNEL=dev for a channel of its own; \
                that steers this run, not how a bundle was built)
                """)
            // Standing down is not a decision for the rest of the run: the other
            // instance is usually a short-lived `swift run`, and when it goes the
            // path is ours to take.
            if reclaim == nil {
                reclaim = LocalSocket.retryWhenFree(path: path, on: queue) { [weak self] in
                    self?.bindAndListen()
                }
            }
            return
        }
        reclaim?.cancel()
        reclaim = nil
        // Nothing answers, so any file here is a leftover: clearing it is what
        // keeps bind() from failing with EADDRINUSE.
        unlink(path)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { Self.log("socket() failed: \(errno)"); return }

        guard var address = LocalSocket.address(for: path) else {
            Self.log("socket path too long: \(path)")
            close(descriptor)
            return
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, size) }
        }
        guard bound == 0 else { Self.log("bind() failed: \(errno)"); close(descriptor); return }
        guard listen(descriptor, 16) == 0 else {
            Self.log("listen() failed: \(errno)"); close(descriptor); return
        }
        // Non-blocking listen socket so the accept loop drains every pending
        // connection per readable event and then stops cleanly on EAGAIN.
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(descriptor) }
        listenDescriptor = descriptor
        self.source = source
        source.resume()
        pathWatch = LocalSocket.watchForReplacement(of: path, on: queue) { [weak self] in
            guard let self else { return }
            Self.log("agent status socket was replaced — rebinding")
            self.pathWatch?.cancel()
            self.pathWatch = nil
            self.source?.cancel()
            self.source = nil
            self.listenDescriptor = -1
            self.bindAndListen()
        }
    }

    private func acceptPending() {
        while true {
            let client = accept(listenDescriptor, nil, nil)
            if client < 0 { break }
            handle(client)
        }
    }

    private func handle(_ descriptor: Int32) {
        defer { close(descriptor) }
        // A receive timeout is the backstop for a client that connects and then
        // neither sends a full payload nor closes — it can't wedge the queue.
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        // Decode after each chunk so we react the instant a complete JSON object
        // has arrived, regardless of whether the sender (`nc`) keeps the
        // connection open afterwards. The cap guards against a runaway stream.
        while data.count < 64 * 1024 {
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
            if let report = Self.decode(data) { dispatch(report); return }
        }
        if let report = Self.decode(data) { dispatch(report) }
    }

    private static func decode(_ data: Data) -> StatusReport? {
        try? JSONDecoder().decode(StatusReport.self, from: data)
    }

    private func dispatch(_ report: StatusReport) {
        let handler = onReport
        Task { @MainActor in handler(report) }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("termio: hook listener \(message)\n".utf8))
    }
}

/// Installs (and removes) the per-agent integrations that report a session's
/// activity into `HookListener`. Each agent has a different lifecycle mechanism —
/// Claude Code and Codex run shell hooks, OpenCode and Pi load a small plugin — but
/// they all speak one wire format: a normalized `{termio_session, state}` object
/// piped into the socket, with the state ("working"/"attention"/"done") fixed per
/// event. The session id rides in via the `TERMIO_SESSION` the PTY carries, so
/// correlation is exact regardless of agent or shared directory.
///
/// Conservative by construction: each installer preserves the user's existing
/// config, only ever adds/removes entries it recognizes as its own (their command
/// contains the socket filename), and refuses to overwrite a file it can't parse.
enum AgentStatusHooks {
    /// The substring that identifies a *legacy* raw-socket entry as termio's — the
    /// `printf … | nc -U …/agent-status.sock` hooks older builds installed, and the
    /// `// Socket marker: …` comment still embedded in the plugin files. Kept so a new
    /// build strips any leftover raw-nc hooks before writing its CLI-based ones.
    static let marker = "agent-status.sock"

    /// The substring that identifies a current, CLI-based hook as termio's: every hook
    /// termio now installs invokes the public `termio agent report <state>` contract, so
    /// the ` agent report ` fragment is our fingerprint. Strip logic matches either this
    /// or the legacy `marker`, so upgrades cleanly replace old hooks with new ones.
    static let cliMarker = "agent report"

    /// Fingerprints of third-party status hooks that full-replace the shared `hooks`
    /// block (Claude's `settings.json`, Codex's `hooks.json`) instead of merging, wiping
    /// termio's entries. We strip these on install so a destructive writer can't out-merge
    /// us. Each substring is specific to one tool's command, so a user's own hook is never
    /// matched — extend only with equally specific fingerprints.
    static let conflictingHookMarkers = [
        "SUPERSET_HOME_DIR",
        "SUPERSET_AGENT_ID",
    ]

    /// Re-applies every agent's integration (or removes them all) to match `enabled`.
    /// Returns which agents' configs took the hooks, so a Settings row can confirm
    /// the install rather than leaving the click silent; the uninstall path reports
    /// nothing, since no UI asks about it.
    @discardableResult
    static func sync(enabled: Bool, target: AgentIntegrationTarget = .thisMac) -> InstallOutcome {
        // Every local hook references the channel-stable CLI copy, so make sure it
        // carries this build's content before (re)stamping its path anywhere. A
        // device's hooks invoke its own `termiod`, which `termiod remote deploy`
        // keeps current — there is nothing here to refresh for it.
        if target.isLocal { CommandLineTool.refreshSupportCopy() }
        var outcome = InstallOutcome()
        if enabled {
            // A full user override may intentionally remove/redirect a shipped hook.
            // Remove that old managed wiring before installing the merged catalog.
            for installer in staleBundledInstallers(target) { installer.uninstall() }
            for (name, installer) in installers(target) {
                outcome.record(name, installed: installer.install())
            }
        } else {
            for installer in allKnownInstallers(target) { installer.uninstall() }
        }
        return outcome
    }

    /// Each hook-carrying agent's display name paired with its installer, so an
    /// install result can be reported per agent rather than as one opaque total.
    private static func installers(
        _ target: AgentIntegrationTarget
    ) -> [(name: String, installer: AgentStatusInstaller)] {
        AgentCatalog.shared.all.compactMap { agent in
            agent.hookSpec
                .flatMap { installer(id: agent.id, spec: $0, target: target) }
                .map { (agent.displayName, $0) }
        }
    }

    private static func staleBundledInstallers(
        _ target: AgentIntegrationTarget
    ) -> [AgentStatusInstaller] {
        AgentCatalog.shared.staleBundledHookSpecs.compactMap {
            installer(id: "bundled", spec: $0, target: target)
        }
    }

    private static func allKnownInstallers(
        _ target: AgentIntegrationTarget
    ) -> [AgentStatusInstaller] {
        let specs = AgentCatalog.shared.bundled.compactMap(\.hookSpec)
            + AgentCatalog.shared.all.compactMap(\.hookSpec)
        return Set(specs).compactMap { installer(id: "catalog", spec: $0, target: target) }
    }

    private static func installer(
        id: String, spec: AgentHookSpec, target: AgentIntegrationTarget
    ) -> AgentStatusInstaller? {
        switch spec.type {
        case .json: return JSONHookFile.manifest(id: id, spec: spec, target: target)
        case .toml: return TOMLHookBlock.manifest(id: id, spec: spec, target: target)
        case .plugin: return PluginFile.manifest(id: id, spec: spec, target: target)
        case .scripts: return ScriptHookDirectory.manifest(id: id, spec: spec, target: target)
        }
    }

    /// The shell command a hook runs: invoke the public `termio agent report <state>`
    /// contract, which reads the session id ($TERMIO_SESSION the PTY carries) and cwd
    /// ($PWD), then writes the normalized report to the status socket. This replaces the
    /// per-dialect `printf … | nc` termio used to bake into every hook file; the socket
    /// path and JSON shaping now live behind the one documented command (see
    /// `scripts/termio`, and the design doc §4). Used by the shell-hook agents and
    /// stamped into the plugin agents' JavaScript too, so every installer converges on
    /// the same contract.
    ///
    /// The stamped path is the channel-stable CLI copy — never the bundle, whose
    /// location can vanish (a dev build launched from a deleted git worktree). The CLI
    /// broadcasts each report to every channel's status socket, so which channel's copy
    /// a hook happens to invoke doesn't matter; the receiving apps route by session id.
    /// Status reporting stays best-effort either way: the whole command degrades to a
    /// silent no-op if the copy is missing, instead of spamming every agent turn with
    /// hook-failure noise.
    static func reportCommand(
        state: String, withTranscript: Bool = false, conversationField: String? = nil,
        toolField: String? = nil, promptTitleField: String? = nil,
        dialect: HookDialect = .claudeNested,
        reporter: HookReporter = .termioCLI
    ) -> String {
        // A device has no `termio` and no app to report to; its hooks talk to the
        // daemon that owns their PTY, which broadcasts `E status` to every viewer.
        // The stdin-mining options have no counterpart in `SetStatus` and are
        // dropped rather than emitted as flags the remote binary would reject —
        // see `HookReporter.termiodDaemon`.
        guard reporter == .termioCLI else {
            var command = "\(reporter.shellBinaryPath) set-status"
            command += " \"$TERMIOD_SESSION_ID\" \(state)"
            command += dialect == .cursorFlat
                ? " 2>/dev/null; printf '{}'"
                : " 2>/dev/null || true"
            return command + " \(hookVersionComment)"
        }
        var command = "\(reporter.shellBinaryPath) agent report \(state)"
        // Claude feeds each hook a JSON blob on stdin carrying `transcript_path`; the
        // CLI mines it out (jq-free) so termio can address the raw Q&A log. Only enabled
        // for agents that reliably provide stdin, so the CLI's `cat` can't block.
        if withTranscript { command += " --transcript" }
        // Some agents' stdin blob also names the live conversation id (Codex
        // `session_id`, Grok `sessionId`); the manifest declares the field and the CLI
        // mines it, so termio can follow an in-process `/new` rotation. Same stdin
        // caveat as `--transcript`. The field name is validated at manifest load to be
        // a bare identifier, so it embeds safely.
        if let conversationField { command += " --conversation-from \(conversationField)" }
        // Tool events' stdin blob names the running tool (Claude `tool_name`); the
        // CLI mines it so reports can tell real work from a prose-only turn. Events
        // whose blob lacks the field simply omit it — same stdin caveat as above.
        if let toolField { command += " --tool-from \(toolField)" }
        // Prompt-aware hosts can seed a compact sidebar label before they have a
        // useful native terminal title. The receiving app normalizes and accepts
        // only the first value for a conversation.
        if let promptTitleField { command += " --prompt-title-from \(promptTitleField)" }
        // Cursor reads the hook's stdout as its JSON reply, so the CLI must stay silent
        // and print a benign `{}`. (Claude/Codex ignore hook stdout, so they don't.)
        // The fallback keeps that contract even when the CLI itself couldn't run.
        if dialect == .cursorFlat {
            command += " --reply 2>/dev/null || printf '{}'"
        } else {
            command += " 2>/dev/null || true"
        }
        // Stamp the build version as a trailing shell comment (ignored at runtime): the
        // command string changes each release, so the idempotent `write()` re-installs the
        // hook on the first launch after an upgrade.
        command += " \(hookVersionComment)"
        return command
    }

    /// Marker + version stamped into every installed hook (`# termio-hooks v0.21.0`).
    static let hookVersionMarker = "# termio-hooks v"
    static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    }
    static var hookVersionComment: String { "\(hookVersionMarker)\(appVersion)" }

    /// Absolute path to this channel's stable `termio`/`termio-dev` CLI copy under
    /// Application Support (see `CommandLineTool.supportCopyURL`), stamped into each
    /// hook command so it resolves regardless of PATH, the `/usr/local/bin` symlink,
    /// or where the app bundle happens to live.
    static var cliPath: String {
        CommandLineTool.supportCopyURL.path
    }

    /// Single-quotes a path for safe embedding in a hook shell command (the bundle path
    /// can contain spaces, e.g. under `/Applications/termio dev.app`).
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("termio: agent hooks \(message)\n".utf8))
    }
}

private protocol AgentStatusInstaller {
    /// Whether the agent's config carries termio's current hooks afterwards —
    /// including the common no-op case where it already did. `false` means the
    /// config was left alone on purpose (unparseable, or not ours to overwrite) or
    /// the write failed; the reason is logged.
    func install() -> Bool
    func uninstall()
}

/// The on-disk shape of a JSON hook file. Agents that configure hooks via a JSON
/// file still disagree on structure, so the installer branches on this.
enum HookDialect: Hashable {
    /// Claude Code / Codex: `{ "hooks": { "<Event>": [ { "matcher"?, "hooks": [ {type,command} ] } ] } }`,
    /// and the agent ignores the hook's stdout.
    case claudeNested
    /// Cursor: `{ "version": 1, "hooks": { "<Event>": [ { "command" } ] } }` — a
    /// required top-level `version`, flat one-key entries, and the hook's stdout is
    /// read back as its JSON reply (so the report prints a clean empty object).
    case cursorFlat
    /// Copilot CLI: Cursor's flat shape plus a `type` on each entry —
    /// `{ "version": 1, "hooks": { "<Event>": [ { "type": "command", "command" } ] } }`.
    /// Its config lives in a file termio owns under `~/.copilot/hooks/`, and it reads
    /// hook stdout as free text (its own examples print banners), so the report stays
    /// on the silent form. PascalCase event names select the payload whose fields are
    /// snake_case — the same `session_id` / `tool_name` the other agents supply.
    case copilotFlat
    /// Kimi's marker-delimited TOML array-of-tables block.
    case kimiTOML
    /// Shipped plugin templates. Each names a closed host API; manifests provide
    /// only the destination directory and event→state data.
    case openCodePlugin
    case piPlugin
    case ampPlugin
    /// Cline: a directory of executables named after the lifecycle event
    /// (`~/.cline/hooks/TaskStart`), with no host config to merge.
    case clineScripts
}

/// Installs hooks for agents whose config is a JSON file with the Claude-Code
/// shape — `{ "hooks": { "<Event>": [ { "matcher"?, "hooks": [ {type,command} ] } ] } }`.
/// Claude Code (`~/.claude/settings.json`) and Codex (`~/.codex/hooks.json`) both
/// use exactly this structure, differing only in path and event names.
private struct JSONHookFile: AgentStatusInstaller {
    /// The manifest's path, unexpanded — `~` is the target machine's home, which
    /// only `store` can resolve.
    let path: String
    let store: AgentConfigStore
    let reporter: HookReporter
    /// `(event name, normalized state, matcher)`. `matcher` is `"*"` for Claude's
    /// tool events (the shape it expects) and `nil` everywhere else — Codex treats
    /// a missing matcher as "match every occurrence".
    let events: [AgentHookEvent]
    /// Whether this agent's hooks pass a JSON payload on stdin we can mine for the
    /// session's `transcript_path`. Only enabled for agents verified to always
    /// supply stdin (Claude Code, Codex), so the capturing `cat` can't block.
    var capturesTranscript: Bool = false
    /// The stdin JSON field naming the live conversation id (`hooks.conversation`
    /// in the manifest), or `nil` for identity-blind hooks. Same stdin caveat as
    /// `capturesTranscript`.
    var conversationField: String?
    /// The stdin JSON field naming the tool a hook event fires for (`hooks.tool`
    /// in the manifest), or `nil` when the agent exposes none. Same stdin caveat.
    var toolField: String?
    /// The stdin JSON field carrying a first-prompt title candidate.
    var promptTitleField: String?
    /// The file's structural shape (see `HookDialect`). Defaults to Claude's, which
    /// Codex also uses; Cursor overrides it.
    var dialect: HookDialect = .claudeNested
    /// Dedicated `termio.json` files can disappear when their last managed hook is
    /// removed. Shared host files such as `settings.json` must remain in place.
    var removesFileWhenEmpty = false
    /// Previous termio-owned filenames to strip during both install and uninstall.
    /// Keeping this on the installer prevents a rename from loading duplicate hooks.
    var legacyPaths: [String] = []

    static func manifest(
        id: String, spec: AgentHookSpec, target: AgentIntegrationTarget
    ) -> JSONHookFile? {
        guard spec.type == .json, let file = spec.file else {
            AgentStatusHooks.log("\(id): incomplete JSON hook manifest")
            return nil
        }
        let isDedicatedTermioFile = (file as NSString).lastPathComponent == "termio.json"
        let legacyPaths = isDedicatedTermioFile
            ? [(file as NSString).deletingLastPathComponent + "/termio-status.json"]
            : []
        return JSONHookFile(
            path: file,
            store: target.store,
            reporter: target.reporter,
            events: spec.events,
            capturesTranscript: spec.capturesTranscript,
            conversationField: spec.conversation,
            toolField: spec.tool,
            promptTitleField: spec.promptTitle,
            dialect: spec.dialect,
            removesFileWhenEmpty: isDedicatedTermioFile,
            legacyPaths: legacyPaths)
    }

    private enum FileState {
        /// No file, or a zero-byte one — nothing to merge into either way. Carries
        /// whatever is there so the commit's precondition can still name it.
        case missing(Data?)
        case unreadable
        case ok([String: Any], Data)
    }

    func install() -> Bool {
        let root: [String: Any]
        /// The exact bytes this merge is computed from; the write commits against
        /// them so a config edited in between is refused rather than discarded.
        let expected: Data?
        switch readState(at: path) {
        case .ok(let dictionary, let data): root = dictionary; expected = data
        case .missing(let data): root = [:]; expected = data
        case .unreadable:
            AgentStatusHooks.log("refusing to modify unparseable \(path)")
            return false
        }

        var settings = root
        // Cursor and Copilot require a top-level schema version; add it only when the
        // user's file doesn't already carry one, so we never overwrite their choice.
        if dialect == .cursorFlat || dialect == .copilotFlat, settings["version"] == nil {
            settings["version"] = 1
        }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        // Strip every prior termio entry first — across all events, not just the
        // ones we're about to re-add — so an event we no longer manage (e.g. a
        // mapping we dropped between versions) doesn't leave an orphan behind.
        stripTermioEntries(from: &hooks)
        // Then drop known conflicting third-party hooks that full-replace the block, so
        // the next destructive writer can't win again — this makes our install authoritative.
        stripConflictingEntries(from: &hooks)
        for event in events {
            var groups = hooks[event.name] as? [[String: Any]] ?? []
            let command = AgentStatusHooks.reportCommand(
                state: event.state, withTranscript: capturesTranscript,
                conversationField: conversationField, toolField: toolField,
                promptTitleField: promptTitleField, dialect: dialect, reporter: reporter)
            let group: [String: Any]
            if dialect == .cursorFlat {
                group = ["command": command]
            } else if dialect == .copilotFlat {
                group = ["type": "command", "command": command]
            } else {
                var nested: [String: Any] = ["hooks": [["type": "command", "command": command]]]
                if let matcher = event.matcher { nested["matcher"] = matcher }
                group = nested
            }
            groups.append(group)
            hooks[event.name] = groups
        }
        settings["hooks"] = hooks
        guard write(settings, to: path, ifUnchangedFrom: expected) else { return false }

        // Publish the replacement before removing its predecessor. If the new file
        // could not be written, retain the working legacy integration for next launch.
        guard store.exists(path) else { return false }
        for legacyPath in legacyPaths {
            uninstall(at: legacyPath, removeFileWhenEmpty: true)
        }
        return true
    }

    func uninstall() {
        uninstall(at: path, removeFileWhenEmpty: removesFileWhenEmpty)
        for legacyPath in legacyPaths {
            uninstall(at: legacyPath, removeFileWhenEmpty: true)
        }
    }

    private func uninstall(at candidatePath: String, removeFileWhenEmpty: Bool) {
        // Nothing to remove if the file is absent; never overwrite one we can't read.
        guard case .ok(let root, let expected) = readState(at: candidatePath) else { return }
        var settings = root
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
        stripTermioEntries(from: &hooks)
        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }
        if removeFileWhenEmpty, settings.isEmpty {
            store.remove(candidatePath)
        } else {
            write(settings, to: candidatePath, ifUnchangedFrom: expected)
        }
    }

    /// Removes termio's own groups from every hook event, dropping any event left
    /// with no groups. Identifying our entries by the socket marker means user
    /// hooks are never touched.
    private func stripTermioEntries(from hooks: inout [String: Any]) {
        for key in Array(hooks.keys) {
            guard var groups = hooks[key] as? [[String: Any]] else { continue }
            groups.removeAll { isTermioGroup($0) }
            if groups.isEmpty {
                hooks.removeValue(forKey: key)
            } else {
                hooks[key] = groups
            }
        }
    }

    private func stripConflictingEntries(from hooks: inout [String: Any]) {
        for key in Array(hooks.keys) {
            guard var groups = hooks[key] as? [[String: Any]] else { continue }
            groups.removeAll { isConflictingGroup($0) }
            if groups.isEmpty {
                hooks.removeValue(forKey: key)
            } else {
                hooks[key] = groups
            }
        }
    }

    private func isConflictingGroup(_ group: [String: Any]) -> Bool {
        func isTheirs(_ command: String) -> Bool {
            AgentStatusHooks.conflictingHookMarkers.contains { command.contains($0) }
        }
        if let command = group["command"] as? String { return isTheirs(command) }
        guard let hooks = group["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { ($0["command"] as? String).map(isTheirs) == true }
    }

    private func isTermioGroup(_ group: [String: Any]) -> Bool {
        // Recognize both the current CLI-based hook (` agent report `) and any legacy
        // raw-socket hook (`…/agent-status.sock`) an older build left, so an upgrade
        // strips the old before writing the new instead of doubling up. Cursor's flat
        // entry carries the command directly; Claude/Codex nest it.
        func isOurs(_ command: String) -> Bool {
            command.contains(AgentStatusHooks.cliMarker) || command.contains(AgentStatusHooks.marker)
        }
        if let command = group["command"] as? String { return isOurs(command) }
        guard let hooks = group["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { ($0["command"] as? String).map(isOurs) == true }
    }

    private func readState(at candidatePath: String) -> FileState {
        guard store.exists(candidatePath) else { return .missing(nil) }
        guard let data = store.read(candidatePath) else { return .unreadable }
        if data.isEmpty { return .missing(data) }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return .unreadable }
        return .ok(dictionary, data)
    }

    /// Returns whether the file now holds `settings` — true both for a fresh write
    /// and for the skipped identical one, false only when the write threw.
    @discardableResult
    private func write(
        _ settings: [String: Any], to destinationPath: String, ifUnchangedFrom expected: Data?
    ) -> Bool {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: settings,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            // Skip a write whose bytes already match — the common case on every
            // launch — so a user-owned file sees no churn at all. `.sortedKeys` is
            // what makes those bytes stable.
            if data == expected { return true }
            return store.write(data, to: destinationPath, ifUnchangedFrom: expected)
        } catch {
            AgentStatusHooks.log("could not encode \(destinationPath): \(error)")
            return false
        }
    }
}

/// Installs agents whose hook contract is a *directory of executables* named after
/// the lifecycle event rather than a config file to merge: Cline runs
/// `~/.cline/hooks/TaskStart` and friends, matching by filename. Each script is a
/// two-line shell wrapper around the same public report contract every other dialect
/// invokes, so nothing agent-specific runs. A file is written or removed only when it
/// carries termio's marker, so a user's own hook of that name is never claimed, and an
/// event termio no longer manages has its old script swept on the next install.
private struct ScriptHookDirectory: AgentStatusInstaller {
    let directory: String
    let store: AgentConfigStore
    let reporter: HookReporter
    let events: [AgentHookEvent]

    static func manifest(
        id: String, spec: AgentHookSpec, target: AgentIntegrationTarget
    ) -> ScriptHookDirectory? {
        guard spec.type == .scripts, let directory = spec.directory else {
            AgentStatusHooks.log("\(id): incomplete script hook manifest")
            return nil
        }
        guard spec.dialect == .clineScripts else {
            AgentStatusHooks.log("\(id): hook dialect is not a script directory")
            return nil
        }
        return ScriptHookDirectory(
            directory: directory, store: target.store, reporter: target.reporter,
            events: spec.events)
    }

    func install() -> Bool {
        sweepOwnedScripts(keeping: Set(events.map(\.name)))
        var installed = true
        for event in events {
            let path = directory + "/" + event.name
            let contents = script(for: event)
            if let existing = store.readText(path), existing != contents, !isOwned(existing) {
                AgentStatusHooks.log("refusing to overwrite non-termio hook \(path)")
                installed = false
                continue
            }
            // Always written rather than skipped-when-identical: the agent execs
            // these by name, so the mode is as much a part of the install as the
            // bytes, and a file left non-executable by anything else is repaired
            // by re-writing it.
            if !store.write(Data(contents.utf8), to: path, executable: true) {
                installed = false
            }
        }
        return installed
    }

    func uninstall() {
        sweepOwnedScripts(keeping: [])
    }

    /// Removes every script in the directory that is ours and not in `keeping`.
    private func sweepOwnedScripts(keeping: Set<String>) {
        guard let names = store.listDirectory(directory) else { return }
        for name in names where !keeping.contains(name) {
            let path = directory + "/" + name
            guard let existing = store.readText(path), isOwned(existing) else { continue }
            store.remove(path)
        }
    }

    private func script(for event: AgentHookEvent) -> String {
        let command = AgentStatusHooks.reportCommand(state: event.state, reporter: reporter)
        return "#!/bin/sh\n\(command)\n"
    }

    private func isOwned(_ source: String) -> Bool {
        source.contains(AgentStatusHooks.marker) || source.contains(AgentStatusHooks.cliMarker)
    }
}

/// Installs agents whose integration is a single dropped-in plugin/extension file
/// (no host config to merge): OpenCode loads a plugin from `~/.config/opencode/plugin/`,
/// Pi an extension from `~/.pi/agent/extensions/`, Amp one from `~/.config/amp/plugins/`.
/// All three run in-process in the PTY and emit the same normalized report —
/// OpenCode via its session lifecycle events, Pi via `agent_start`/`agent_end`,
/// Amp via `agent.start`/`agent.end`. Uninstall removes the file only if it's ours.
///
/// Unlike every other dialect, the hook here is generated *source*, not a command
/// string, so the machine reaches further into the template than a swapped binary
/// path: this Mac reads `TERMIO_SESSION` and reports through the `termio` CLI to
/// the app's socket, and a device reads `TERMIOD_SESSION_ID` and reports through
/// `termiod set-status` to the daemon that owns its PTY.
private struct PluginFile: AgentStatusInstaller {
    let path: String
    let store: AgentConfigStore
    let contents: String
    let legacyPaths: [String]

    static func manifest(
        id: String, spec: AgentHookSpec, target: AgentIntegrationTarget
    ) -> PluginFile? {
        guard spec.type == .plugin, let directory = spec.directory else {
            AgentStatusHooks.log("\(id): incomplete plugin hook manifest")
            return nil
        }
        // `termiod set-status` carries a state and a title and nothing else, so a
        // device build of any of these templates drops the conversation plumbing
        // rather than tracking an id the daemon has no field for. Stated once
        // here instead of three times, because it is one fact about the daemon
        // rather than three facts about plugin APIs (`HookReporter`).
        let conversation = target.isLocal ? spec.conversation : nil
        let reporter = target.reporter
        let filename: String
        let legacyFilename: String
        let contents: String
        switch spec.dialect {
        case .openCodePlugin:
            filename = "termio.js"
            legacyFilename = "termio-status.js"
            contents = openCodeSource(
                events: spec.events, conversationPath: conversation, reporter: reporter)
        case .piPlugin:
            filename = "termio.js"
            legacyFilename = "termio-status.js"
            contents = piSource(
                events: spec.events, conversation: conversation, reporter: reporter)
        case .ampPlugin:
            filename = "termio.ts"
            legacyFilename = "termio-status.ts"
            contents = ampSource(events: spec.events, reporter: reporter)
        default:
            AgentStatusHooks.log("\(id): hook dialect is not a plugin template")
            return nil
        }
        return PluginFile(
            path: directory + "/" + filename,
            store: target.store,
            contents: contents,
            legacyPaths: [directory + "/" + legacyFilename])
    }

    func install() -> Bool {
        if store.exists(path) {
            // `termio.js` is a deliberately simple name, so never claim a user's
            // pre-existing file merely because it occupies our desired path.
            guard let existing = store.readText(path), existing == contents || isOwned(existing)
            else {
                AgentStatusHooks.log("refusing to overwrite non-termio plugin \(path)")
                return false
            }
        }
        guard store.writeIfChanged(Data(contents.utf8), to: path) else { return false }
        for legacyPath in legacyPaths {
            removeOwnedFile(at: legacyPath)
        }
        return true
    }

    func uninstall() {
        removeOwnedFile(at: path)
        for legacyPath in legacyPaths {
            removeOwnedFile(at: legacyPath)
        }
    }

    private func removeOwnedFile(at candidatePath: String) {
        // Only remove a file we recognize as ours, so a user file that happens to
        // share the name is never deleted.
        guard let existing = store.readText(candidatePath), isOwned(existing) else { return }
        store.remove(candidatePath)
    }

    private func isOwned(_ source: String) -> Bool {
        source.contains(AgentStatusHooks.marker)
            || source.contains(AgentStatusHooks.cliMarker)
    }

    private static var cliPath: String { AgentStatusHooks.cliPath }

    /// `const cli = …` for a generated plugin: this Mac's channel-stable CLI copy
    /// as a literal, or the device's `termiod` joined to the target's own `$HOME`
    /// at load time.
    private static func cliDeclaration(for reporter: HookReporter) -> String {
        "const cli = \(reporter.javaScriptBinaryExpression(quotedAs: jsString));"
    }

    /// The body of a device plugin's `report`. The session id comes from the
    /// environment the daemon owns (`session::daemon_owned_env` exports
    /// `TERMIOD_SESSION_ID` after the client's `env`, so it cannot be spoofed),
    /// and a plugin loaded outside a termiod session reports nothing rather than
    /// invoking `set-status` with an empty id the daemon would reject.
    private static func daemonReportBody(shell: String) -> String {
        """
            if (!session) return;
            return \(shell)`${cli} set-status ${session} ${state}`.quiet().nothrow();
        """
    }

    /// The `const session = …` line that body needs, or nothing on this Mac,
    /// where the id rides in on `TERMIO_SESSION` and the CLI reads it itself.
    private static func sessionDeclaration(for reporter: HookReporter) -> String {
        reporter == .termioCLI ? "" : "\n  const session = process.env.TERMIOD_SESSION_ID;"
    }

    /// OpenCode plugin: a session is `busy` while working and emits `session.idle`
    /// when the turn ends; `permission.updated` means it's waiting on the user. Each
    /// maps to the public report contract shelled out via Bun's `$`. The session id
    /// comes from `TERMIO_SESSION`, which the PTY carries into the in-process plugin.
    ///
    /// `conversationPath` (the manifest's `hooks.conversation`) is the dot key path
    /// in the event object naming OpenCode's own conversation id; when set, each
    /// report also carries it so termio can follow an in-process new-session
    /// rotation. Subagent child sessions share this event bus, and adopting a
    /// child's id would mis-pin the tab, so the plugin learns which ids are
    /// top-level from `session.created`/`session.updated` (child sessions carry
    /// `parentID`) and forwards only those.
    private static func openCodeSource(
        events: [AgentHookEvent], conversationPath: String?, reporter: HookReporter
    ) -> String {
        let conversationExpression = conversationPath.map { path in
            "event" + path.split(separator: ".").map { "?.\($0)" }.joined()
        }
        let branches = events.map { event in
            let eventName = jsString(event.name)
            let state = jsString(event.state)
            let arguments = conversationExpression.map { "\(state), \($0)" } ?? state
            if let matcher = event.matcher {
                return "      if (event.type === \(eventName) && event.properties?.status?.type === \(jsString(matcher))) return report(\(arguments));"
            }
            return "      if (event.type === \(eventName)) return report(\(arguments));"
        }.joined(separator: "\n")
        let identity = conversationExpression == nil ? "" : """

          const roots = new Set();
          const note = (info) => {
            if (!info?.id) return;
            if (info.parentID) roots.delete(info.id); else roots.add(info.id);
          };
        """
        let identityBranches = conversationExpression == nil ? "" : """
              if (event.type === "session.created" || event.type === "session.updated") return note(event.properties?.info);
              if (event.type === "session.deleted") return roots.delete(event.properties?.info?.id);

        """
        let localReportBody = conversationExpression == nil ? """
            return $`${cli} agent report ${state}`.quiet().nothrow();
        """ : """
            if (conversation && roots.has(conversation)) {
              return $`${cli} agent report ${state} --conversation ${conversation}`.quiet().nothrow();
            }
            return $`${cli} agent report ${state}`.quiet().nothrow();
        """
        let reportBody = reporter == .termioCLI
            ? localReportBody
            : daemonReportBody(shell: "$")
        let reportParameters = conversationExpression == nil ? "(state)" : "(state, conversation)"
        return """
        // termio agent status — reports OpenCode session lifecycle to termio.
        // Socket marker: \(AgentStatusHooks.marker)
        export const TermioStatus = async ({ $ }) => {
          \(cliDeclaration(for: reporter))\(sessionDeclaration(for: reporter))\(identity)
          const report = \(reportParameters) => {
        \(reportBody)
          };
          return {
            event: async ({ event }) => {
        \(identityBranches)\(branches)
            },
          };
        };
        """
    }

    /// Pi extension: `agent_start` fires when a turn begins, `agent_end` when it
    /// returns to the user. Pi has no shell-hook config, so the extension itself
    /// shells out via `pi.exec`; the session id rides in on `TERMIO_SESSION`.
    ///
    /// `conversation == "context"` (the manifest's `hooks.conversation`) means Pi's
    /// own conversation id is read from the extension context's session manager and
    /// forwarded with each report, so termio can follow an in-process `/new`
    /// rotation (Pi reloads extensions with a fresh context when it switches
    /// sessions). The id is embedded in a shell command, so it is forwarded only
    /// when it looks like a bare token — Pi's uuidv7 ids always do.
    private static func piSource(
        events: [AgentHookEvent], conversation: String?, reporter: HookReporter
    ) -> String {
        // Pi is the one template that needs no device branch of its own: it
        // already shells out through `pi.exec("sh", …)`, so the device form is
        // whatever `reportCommand` emits for the daemon — the same string the
        // JSON-manifest and script-directory dialects get.
        guard conversation != nil else {
            let listeners = events.map { event in
                let command = AgentStatusHooks.reportCommand(state: event.state, reporter: reporter)
                return "  pi.on(\(jsString(event.name)), () => pi.exec(\"sh\", [\"-c\", \(jsString(command))]));"
            }.joined(separator: "\n")
            return """
            // termio agent status — reports Pi turn lifecycle to termio.
            // Socket marker: \(AgentStatusHooks.marker)
            export default (pi) => {
            \(listeners)
            };
            """
        }
        let listeners = events.map { event in
            "  pi.on(\(jsString(event.name)), (_event, context) => report(\(jsString(event.state)), context));"
        }.joined(separator: "\n")
        return """
        // termio agent status — reports Pi turn lifecycle to termio.
        // Socket marker: \(AgentStatusHooks.marker)
        export default (pi) => {
          const cli = \(jsString(AgentStatusHooks.shellQuote(cliPath)));
          const report = (state, context) => {
            const id = context?.sessionManager?.getSessionId?.();
            const conversation = id && /^[A-Za-z0-9._-]+$/.test(id) ? ` --conversation ${id}` : "";
            pi.exec("sh", ["-c", `${cli} agent report ${state}${conversation} 2>/dev/null || true`]);
          };
        \(listeners)
        };
        """
    }

    /// Amp plugin: `agent.start` fires when the user submits a prompt, `agent.end`
    /// when the agent finishes handling it. Amp auto-loads any plugin under
    /// `~/.config/amp/plugins/` (a default-exported function receiving the plugin
    /// API), runs on Bun, and exposes Bun's `$` shell as `amp.$`; the session id
    /// rides in on `TERMIO_SESSION` from the PTY. `.quiet().nothrow()` keeps it a
    /// silent no-op when termio isn't listening.
    private static func ampSource(events: [AgentHookEvent], reporter: HookReporter) -> String {
        let listeners = events.map { event in
            "  amp.on(\(jsString(event.name)), () => report(\(jsString(event.state))));"
        }.joined(separator: "\n")
        let reportBody = reporter == .termioCLI ? """
            return amp.$`${cli} agent report ${state}`.quiet().nothrow();
        """ : daemonReportBody(shell: "amp.$")
        return """
        // termio agent status — reports Amp turn lifecycle to termio.
        // Socket marker: \(AgentStatusHooks.marker)
        export default (amp) => {
          \(cliDeclaration(for: reporter))\(sessionDeclaration(for: reporter))
          const report = (state) => {
        \(reportBody)
          };
        \(listeners)
        };
        """
    }

    /// JSON-encodes a string for safe embedding as a JavaScript string literal.
    private static func jsString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
        let array = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }
}

/// Installs hooks for agents that declare them as TOML `[[hooks]]` tables inside
/// their main config file — currently just Kimi Code (`~/.kimi/config.toml`).
///
/// There's no structured merge like the JSON agents get: TOML arrays of tables may
/// be non-contiguous, so termio appends one marker-delimited block at the end of the
/// file and strips it back out by its markers on reinstall/uninstall. Only bytes
/// between the markers are ever touched, so the user's providers, keys, and their own
/// `[[hooks]]` are never disturbed — the same conservative contract as `JSONHookFile`,
/// but without needing a TOML parser. Kimi reads a hook's exit code (0 = allow), and
/// the shared report command ends in `|| true`, so the standard command is safe on
/// Kimi's blockable events — no clean-stdout handling is required.
private struct TOMLHookBlock: AgentStatusInstaller {
    let path: String
    let store: AgentConfigStore
    let reporter: HookReporter
    let events: [AgentHookEvent]

    private static let blockBegin = "# >>> termio agent-status hooks (managed — do not edit) >>>"
    private static let blockEnd = "# <<< termio agent-status hooks <<<"

    static func manifest(
        id: String, spec: AgentHookSpec, target: AgentIntegrationTarget
    ) -> TOMLHookBlock? {
        guard spec.type == .toml, spec.dialect == .kimiTOML, let file = spec.file else {
            AgentStatusHooks.log("\(id): incomplete TOML hook manifest")
            return nil
        }
        return TOMLHookBlock(
            path: file, store: target.store, reporter: target.reporter, events: spec.events)
    }

    func install() -> Bool {
        // The bytes the merge is computed from, committed against below: this is a
        // user-owned file, and over a network the read and the write are two round
        // trips with the user's own editor in between.
        let expected = store.exists(path) ? store.read(path) : nil
        let base = Self.stripBlock(from: expected.map { String(decoding: $0, as: UTF8.self) } ?? "")
            .trimmingCharacters(in: .newlines)
        let block = Self.render(events: events, reporter: reporter)
        let updated = base.isEmpty ? block + "\n" : base + "\n\n" + block + "\n"
        let data = Data(updated.utf8)
        if data == expected { return true }
        return store.write(data, to: path, ifUnchangedFrom: expected)
    }

    func uninstall() {
        guard let expected = store.read(path) else { return }
        let base = Self.stripBlock(from: String(decoding: expected, as: UTF8.self))
            .trimmingCharacters(in: .newlines)
        let data = Data((base.isEmpty ? "" : base + "\n").utf8)
        if data == expected { return }
        store.write(data, to: path, ifUnchangedFrom: expected)
    }

    /// The termio-managed block: a comment banner around one `[[hooks]]` table per
    /// event. The command is embedded as a TOML multi-line literal string (`'''…'''`)
    /// so the shell one-liner's single and double quotes need no escaping — it never
    /// contains three consecutive single quotes.
    private static func render(events: [AgentHookEvent], reporter: HookReporter) -> String {
        var lines = [blockBegin]
        for event in events {
            let command = AgentStatusHooks.reportCommand(state: event.state, reporter: reporter)
            lines.append("[[hooks]]")
            lines.append("event = \"\(event.name)\"")
            if let matcher = event.matcher { lines.append("matcher = \"\(matcher)\"") }
            lines.append("command = '''\(command)'''")
            lines.append("timeout = 5")
            lines.append("")
        }
        if lines.last == "" { lines.removeLast() }
        lines.append(blockEnd)
        return lines.joined(separator: "\n")
    }

    /// Removes a previously written termio block (markers inclusive). If both markers
    /// aren't present the text is returned unchanged, so a hand-edited file is never
    /// mangled.
    private static func stripBlock(from text: String) -> String {
        guard let begin = text.range(of: blockBegin),
              let end = text.range(of: blockEnd, range: begin.upperBound..<text.endIndex)
        else { return text }
        var result = text
        result.removeSubrange(begin.lowerBound..<end.upperBound)
        return result
    }
}
