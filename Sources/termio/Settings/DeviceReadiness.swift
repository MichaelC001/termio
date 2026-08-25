import Foundation

/// Whether an agent's CLI is on a machine — with the third answer the local probe
/// never needed (RFC §D4).
///
/// `AgentAvailability` answers *available* when its own probe fails rather than
/// crying wolf, which is right for this Mac: the only way to fail is a login shell
/// that would not print its `PATH`, and that is rare. A machine reached over a
/// network fails constantly — asleep box, dead tunnel, wrong alias, key not
/// loaded — so folding "we could not ask" into either answer is a lie in one
/// direction or the other. Reported as "not installed" it sends the user to
/// reinstall a CLI that is already there; reported as "available" it promises a
/// launch that cannot happen.
enum AgentReadiness: String, Sendable {
    case available
    case missing
    /// We could not reach the machine to ask. Never a defect in the agent.
    case unknown
}

/// One machine's whole answer, as one line (RFC §D6).
///
/// Deploy `termiod` → probe the agent CLIs → install hooks and skill is a real
/// dependency chain, and four rungs with independent states turn choosing a
/// machine into infrastructure triage. So the pane shows one outcome and the
/// ladder becomes the disclosure behind it.
enum MachineReadiness: Equatable {
    /// Nothing asked yet, and no cache to draw on.
    case unasked
    case checking
    case ready
    /// The **first** blocking step, in words. Only the first: a machine with no
    /// `termiod` also has no hooks, and listing both invites the user to fix the
    /// consequence instead of the cause.
    case blocked(String)

    var isBusy: Bool { self == .checking }
}

/// The steps behind the one line, in dependency order. Named so the pane can say
/// what it is doing while it runs, and so a failure can name the rung it stopped
/// on rather than reporting "setup failed".
enum MachineSetupStep: Equatable {
    /// This Mac: link the `termio` CLI onto `PATH`. A device: deploy `termiod`.
    /// Both are "the binary this machine needs before anything else works", which
    /// is why they are one rung rather than a local branch bolted onto a remote
    /// flow (RFC §D8: installing a CLI on a machine is a machine operation).
    case foundation
    case probeAgents
    case installIntegration

    var label: String {
        switch self {
        case .foundation: return localized("Checking the machine…")
        case .probeAgents: return localized("Looking for agent CLIs…")
        case .installIntegration: return localized("Installing hooks and skill…")
        }
    }
}

extension AgentReadiness {
    /// The answer a **passive** line may give: this Mac is probed live, and any
    /// other machine is read from its device file or left `unknown`.
    ///
    /// Passive is the constraint, not a shortcut. The Agents tab draws one of
    /// these per row, and a live remote probe there would fire an `ssh` per agent
    /// every time the tab is opened or a workspace is switched — several seconds
    /// of Settings hanging on a sleeping box, to decorate a line the user did not
    /// ask about. So the tab reports what is known and says "can't check" when
    /// nothing is; the machine's pane is where asking happens, and it writes the
    /// file this reads.
    ///
    /// Keyed by agent rather than by command, so a path edited since the last
    /// probe reads as whatever the old path resolved to until the machine's pane
    /// is opened again. That is the cache being a cache; it is never the thing
    /// that decides whether a launch happens.
    static func passive(
        agent: AgentPreset, command: String, on device: KnownDevice
    ) async -> AgentReadiness {
        guard device.alias != nil else {
            return await AgentAvailability.isCommandAvailable(command) ? .available : .missing
        }
        let key = device.settingsKey
        guard let cached = await Task.detached(priority: .utility, operation: {
            DeviceStateCache.load(key)
        }).value else { return .unknown }
        return cached.readiness(for: agent)
    }
}

// MARK: - Probing

/// Asks a machine what it is. Every method here runs off the main actor and
/// returns a value; nothing renders, and nothing is cached as authority.
enum MachineProbe {
    /// A read-only check: what is true on this machine right now.
    ///
    /// The one probe that matters is reachability, and it is asked **first and
    /// once**: a machine that does not answer makes every agent `.unknown` in one
    /// step, instead of paying an ssh timeout per agent to reach the same
    /// conclusion eight times.
    static func inspect(
        device: KnownDevice, commands: [(id: String, command: String)]
    ) async -> DeviceDiscoveredState {
        let now = Date()
        guard let alias = device.alias else {
            // This Mac always answers. Its readiness is `AgentAvailability`'s
            // login-shell PATH — the exact PATH a session launches with.
            var agents: [String: String] = [:]
            for entry in commands {
                agents[entry.id] = await AgentAvailability.isCommandAvailable(entry.command)
                    ? AgentReadiness.available.rawValue
                    : AgentReadiness.missing.rawValue
            }
            return DeviceDiscoveredState(checkedAt: now, reachable: true, agents: agents)
        }

        let probe = await SSHConfigFile.testConnection(alias: alias)
        guard case .reachable = probe else {
            return DeviceDiscoveredState(checkedAt: now, reachable: false)
        }
        let store = SSHAgentConfigStore(host: alias)
        return await Task.detached(priority: .userInitiated) {
            var agents: [String: String] = [:]
            for entry in commands {
                agents[entry.id] = store.isCommandInstalled(entry.command)
                    ? AgentReadiness.available.rawValue
                    : AgentReadiness.missing.rawValue
            }
            return DeviceDiscoveredState(
                checkedAt: now, reachable: true,
                termiodVersion: nil, agents: agents)
        }.value
    }
}

// MARK: - The device file's integration stamp

extension DeviceDiscoveredState {
    /// Whether the hooks and skill installed on this machine were installed by
    /// *this* build.
    ///
    /// Stamped rather than re-derived: a hook is a line inside each agent's own
    /// config in four different dialects, and re-parsing all of them on every pane
    /// open would fork the installers' knowledge into a second reader that can
    /// drift from them. The stamp costs one honest failure mode — a config
    /// hand-edited after we wrote it still reads as installed — and the ladder's
    /// "Reinstall hooks" is exactly the disclosure that answers it.
    ///
    /// Compared against the build, not merely checked for presence, because a
    /// local hook embeds the CLI's path and a device hook embeds `termiod`'s: an
    /// upgrade that moves either leaves a hook that cannot exec.
    var carriesCurrentIntegration: Bool {
        integrationVersion != nil && integrationVersion == AppInfo.buildStamp
    }
}

// MARK: - What a machine's pane runs on

/// The state behind one machine's pane: what we last learned, what we are asking
/// now, and the single outcome line.
///
/// Owned by the pane rather than the app because a machine is only asked about
/// while someone is looking at it. Nothing here probes on launch: a Settings
/// window that fires ssh at every configured host on open is how a sleeping VPS
/// makes opening preferences take twenty seconds.
@MainActor
final class MachinePaneModel: ObservableObject {
    let device: KnownDevice
    private let settings: AppSettings

    /// The last probe's answer, seeded from `~/.termio/devices/<key>.json` so the
    /// pane draws something the moment it opens. Replaced by the first live probe
    /// — it is a cache, never the authority.
    @Published private(set) var discovered: DeviceDiscoveredState?
    @Published private(set) var readiness: MachineReadiness = .unasked
    /// The rung in progress, so a chain that takes ten seconds says which part is
    /// slow instead of spinning anonymously.
    @Published private(set) var step: MachineSetupStep?
    /// What the last completed setup left behind, shown once and dismissed.
    @Published var feedback: InstallFeedback?

    init(device: KnownDevice, settings: AppSettings) {
        self.device = device
        self.settings = settings
        discovered = DeviceStateCache.load(device.settingsKey)
        // Seeded from the cache, but never *blocked* by it: a box that was asleep
        // when we last looked must not greet the user with a failure we have not
        // re-confirmed. It reads as "not set up yet" until a live probe says more.
        if let discovered, discovered.carriesCurrentIntegration, discovered.reachable {
            readiness = .ready
        }
    }

    /// The agents whose presence this machine is judged on: the ones the user
    /// actually keeps on their list. Judging on the whole catalog would report a
    /// machine unready for an agent its owner has never used.
    private var listedAgents: [AgentPreset] {
        settings.orderedAgents(AgentPreset.codingAgents.filter(settings.isAgentListed))
    }

    private var commandPairs: [(id: String, command: String)] {
        listedAgents.map { ($0.rawValue, settings.command(for: $0, on: device) ?? "") }
    }

    func readiness(for agent: AgentPreset) -> AgentReadiness {
        guard let discovered else { return .unknown }
        return discovered.readiness(for: agent)
    }

    /// Asks the machine, without changing anything on it. The pane's own refresh,
    /// and what the roster row calls when it first appears.
    func check() async {
        guard !readiness.isBusy else { return }
        readiness = .checking
        step = .foundation
        let state = await MachineProbe.inspect(device: device, commands: commandPairs)
        // Carry the integration stamp forward: a probe asks what is on the
        // machine, and does not un-install what a previous setup put there.
        var merged = state
        merged.integrationVersion = discovered?.integrationVersion
        apply(merged)
        step = nil
    }

    /// The whole safe chain, in one click (RFC §D6). Stops at the first rung that
    /// blocks and says what it was — the later rungs cannot succeed anyway, and
    /// reporting all three invites fixing a consequence instead of a cause.
    func setUp() async {
        guard !readiness.isBusy else { return }
        readiness = .checking
        feedback = nil
        defer { step = nil }

        step = .foundation
        if let failure = await installFoundation() {
            readiness = .blocked(failure)
            return
        }

        step = .probeAgents
        var state = await MachineProbe.inspect(device: device, commands: commandPairs)
        state.integrationVersion = discovered?.integrationVersion
        apply(state)
        // `resolve` already names the first thing in the way — unreachable, or
        // nothing to run — and those are exactly the two that stop the chain.
        if case .blocked = readiness { return }

        step = .installIntegration
        let target = device.integrationTarget
        let hooks = AgentStatusHooks.sync(enabled: settings.agentHooksEnabled, target: target)
        let skill = SessionSkillInstaller.sync(
            enabled: settings.sessionControlEnabled, target: target)
        // A rung that reached the machine but could not write every agent's config
        // is still a failure of *this* rung, and the one worth naming.
        let refused = hooks.failed + skill.failed
        guard refused.isEmpty else {
            apply(state)
            readiness = .blocked(localized(
                "Couldn’t write the config for \(InstallOutcome.list(refused, unit: localized("agents"))) on \(device.name)."))
            return
        }
        state.integrationVersion = AppInfo.buildStamp
        apply(state)
        feedback = .success(localized("\(device.name) is ready."))
    }

    /// The first rung. This Mac needs the `termio` CLI on `PATH` — a hook it
    /// installs invokes it by name. A device needs `termiod`, which is also the
    /// reachability check, since deploying requires reaching it.
    private func installFoundation() async -> String? {
        guard let alias = device.alias else {
            switch CommandLineTool.install() {
            case .installed:
                return nil
            case .conflict:
                return localized("Something else already owns \(CommandLineTool.installURL.path).")
            case .unavailable:
                return localized("Run Termio from the built app to install its command-line tool.")
            case .notInstalled, .stale:
                let directory = CommandLineTool.installURL.deletingLastPathComponent().path
                return localized("Couldn’t link `\(CommandLineTool.toolName)` into \(directory).")
            }
        }
        switch await TermioStore.remoteReadyCheck(host: alias) {
        case .success: return nil
        case .failure(let error): return error.message
        }
    }

    private func apply(_ state: DeviceDiscoveredState) {
        discovered = state
        readiness = resolve(state)
        let key = device.settingsKey
        Task.detached(priority: .utility) { DeviceStateCache.save(state, for: key) }
    }

    /// What a completed probe means, in one line: ready when the machine
    /// answered, something on it can run, and this build put its hooks there —
    /// and otherwise the **first** thing standing in the way, in that order.
    ///
    /// Order matters more than completeness. A box that does not answer also has
    /// no agent CLIs and no hooks, and saying all three would invite the user to
    /// go install an agent on a machine that is switched off.
    private func resolve(_ state: DeviceDiscoveredState) -> MachineReadiness {
        guard state.reachable else { return .blocked(localized("Can’t reach \(device.name).")) }
        guard state.agents.values.contains(AgentReadiness.available.rawValue) else {
            return .blocked(localized("No agent CLIs found on \(device.name)."))
        }
        // Not blocked, just not done — the setup button is the whole next step, so
        // it reads as "set up this device" rather than as a fault.
        return state.carriesCurrentIntegration ? .ready : .unasked
    }
}

extension KnownDevice {
    /// Where this machine's agent integration is written, and what a hook there
    /// runs to report status. The seam `AgentConfigStore` exists for; a machine's
    /// pane is its first caller.
    var integrationTarget: AgentIntegrationTarget {
        alias.map { .device(host: $0) } ?? .thisMac
    }
}

/// The build a device file's integration stamp is compared against.
enum AppInfo {
    /// Version plus build number: a version alone would not notice a dev rebuild
    /// that moved the CLI copy the hooks point at.
    static let buildStamp: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version)+\(build)"
    }()
}
