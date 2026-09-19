import Foundation

/// Per-machine values, split by who wrote them.
///
/// A setting that names a machine has two halves with different lifecycles, and
/// conflating them is what made Settings mean "this Mac" in the first place:
///
/// - **Authored** — the command path the user chose for an agent on that box.
///   A choice, so it belongs beside every other choice in `settings.json` and
///   survives anything.
/// - **Discovered** — whether the box answered, whether a CLI is on its `PATH`.
///   A probe result, so it belongs in `~/.termio/devices/<host_id>.json` and is
///   safe to delete at any moment.
///
/// The rule that keeps them apart: **the discovered file is never read as
/// authority.** It exists so a machine's pane can draw something the instant it
/// opens instead of an empty pane with a spinner, and every value in it is
/// replaced by a live probe as soon as one answers. One read path that trusts it
/// recreates the bug this whole split exists to fix.

// MARK: - Which machine a value belongs to

extension KnownDevice {
    /// The key a machine's values are filed under.
    ///
    /// The `host_id` once a handshake has revealed one, the alias until then —
    /// the same bootstrap/stable split `Checkout.deviceIdentity` and
    /// `TermioStore.isAuthored(_:for:)` already use, so one box reached by a LAN
    /// name, a WAN name and a tailnet name keeps one blob of settings instead of
    /// forking into three.
    ///
    /// This Mac spells it `local` rather than the empty string `id` uses: this is
    /// a JSON object key a human reads and hand-edits, and `"": {…}` is neither.
    var settingsKey: String { deviceID ?? alias ?? "local" }
}

// MARK: - Authored

/// One machine's authored values, as stored. Absent fields mean the user never
/// chose one for that machine — never "the default is X", which is why nothing
/// here has a non-optional stored form.
struct DeviceAuthoredSettings: Codable, Equatable {
    /// Command paths by `AgentPreset.rawValue`, for agents on this machine. The
    /// per-app `agents.commandOverrides` this replaces had no machine dimension,
    /// so a full path typed for a Homebrew install on the Mac was also handed to
    /// a VPS where nothing lives at that path.
    var agentCommands: [String: String]?

    var isEmpty: Bool { (agentCommands?.isEmpty ?? true) }
}

/// The `devices` section of `settings.json`: authored values for every machine
/// the user has set one on.
///
/// Read and written through `SettingsStore` like every other preference — the
/// same file, the same "only keys the user set" rule — rather than a second
/// store with its own lifetime. A user who has never typed a command path on any
/// machine has no `devices` key at all.
struct DeviceSettingsSection: Codable, Equatable {
    var byDevice: [String: DeviceAuthoredSettings]

    init(byDevice: [String: DeviceAuthoredSettings] = [:]) {
        self.byDevice = byDevice
    }

    subscript(key: String) -> DeviceAuthoredSettings {
        get { byDevice[key] ?? DeviceAuthoredSettings() }
        // An emptied machine drops out entirely, so clearing the last value a
        // machine had leaves the file as short as it was before it was set.
        set { byDevice[key] = newValue.isEmpty ? nil : newValue }
    }

    /// The JSON object `SettingsStore` persists. Round-tripped through
    /// `JSONSerialization` because that store holds plist-shaped `Any`, and a
    /// `Codable` value is the only honest way to keep the schema in one place.
    var jsonObject: [String: Any]? {
        guard !byDevice.isEmpty,
              let data = try? JSONEncoder().encode(self.byDevice),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    init(jsonObject: [String: Any]?) {
        guard let jsonObject,
              let data = try? JSONSerialization.data(withJSONObject: jsonObject),
              let decoded = try? JSONDecoder().decode([String: DeviceAuthoredSettings].self, from: data)
        else {
            self.init()
            return
        }
        self.init(byDevice: decoded)
    }
}

// MARK: - Discovered

/// What a probe last learned about one machine — a cache, and labelled one from
/// the day it is written (RFC §D7).
///
/// Nothing here is a decision. Every field is regenerable by asking the machine
/// again, the file may be deleted between any two launches, and a missing file
/// is not an error state: it means "we have not asked yet", which is exactly
/// what `AgentReadiness.unknown` renders.
struct DeviceDiscoveredState: Codable, Equatable {
    /// When the probe that produced this ran. Shown as "Checked <time>" so a
    /// cached answer never passes for a fresh one.
    var checkedAt: Date
    /// Whether the machine answered at all. `false` is what turns every agent row
    /// on that machine into "can't check" rather than "not installed".
    var reachable: Bool
    /// The `termiod` build the machine reported, when it has one.
    var termiodVersion: String?
    /// Per-agent probe results by `AgentPreset.rawValue`, as
    /// `AgentReadiness.rawValue`.
    var agents: [String: String]
    /// The build stamp of the termio that last installed hooks and the skill here
    /// (`AppInfo.buildStamp`), or `nil` if none has. See
    /// `carriesCurrentIntegration` for why this is stamped rather than re-derived.
    var integrationVersion: String?
    /// Which agents that install actually covered, by `AgentPreset.rawValue`.
    ///
    /// Both halves write only for agents whose CLI is on the machine, so an
    /// agent installed *after* a setup has no hooks and reports nothing — a
    /// silent gap, since the version stamp alone still reads as current. This is
    /// what lets a later probe notice it.
    ///
    /// `nil` means a build that did not record it. Read as "covered everything"
    /// rather than "covered nothing": crying wolf on every machine in the roster
    /// the moment this ships is the worse error, and the next app update moves
    /// the stamp anyway, which is what fills this in.
    var integrationAgents: [String]?

    init(
        checkedAt: Date, reachable: Bool, termiodVersion: String? = nil,
        agents: [String: String] = [:], integrationVersion: String? = nil,
        integrationAgents: [String]? = nil, agentProbeAnswered: Bool? = nil
    ) {
        self.checkedAt = checkedAt
        self.reachable = reachable
        self.termiodVersion = termiodVersion
        self.agents = agents
        self.integrationVersion = integrationVersion
        self.integrationAgents = integrationAgents
        self.agentProbeAnswered = agentProbeAnswered
    }

    /// Whether the daemon answered the agent probe. `false` is a machine that ssh
    /// reached but whose `termiod` could not be asked — an old daemon, or one
    /// that will not start.
    ///
    /// Separate from `reachable` because the repair is different: an unreachable
    /// box is a network or ssh problem, while this one is fixed by deploying the
    /// daemon again.
    ///
    /// Optional rather than a `Bool` with a default: Swift's synthesized decoder
    /// does not apply property defaults, so a non-optional field would throw
    /// `keyNotFound` on every device file written before it existed — and
    /// `DeviceStateCache` swallows that to `nil`, silently emptying the cache for
    /// the whole roster. `nil` reads as answered, through `daemonAnswered`.
    var agentProbeAnswered: Bool?

    /// Whether the daemon answered when asked what agents it has. An older file
    /// that never recorded it reads as yes — never a fault nobody confirmed.
    var daemonAnswered: Bool { agentProbeAnswered ?? true }

    /// The agents this machine answered *available* for, sorted so a stamp is
    /// stable across probes. What an install covers, and what a later probe
    /// compares against.
    var availableAgents: [String] {
        agents.filter { $0.value == AgentReadiness.available.rawValue }.keys.sorted()
    }

    /// Carries a previous probe's integration record onto this fresh one.
    ///
    /// A probe asks what is on the machine; it does not un-install what a setup
    /// put there. The record is **two** fields, and carrying one while forgetting
    /// the other is worse than forgetting both: an `integrationAgents` dropped to
    /// `nil` reads as "covered everything", so a refresh would quietly erase the
    /// only thing that can notice an agent installed after setup. One call, so
    /// there is no second place to forget.
    mutating func carryIntegration(from previous: DeviceDiscoveredState?) {
        integrationVersion = previous?.integrationVersion
        integrationAgents = previous?.integrationAgents
    }

    func readiness(for agent: AgentPreset) -> AgentReadiness {
        guard reachable else { return .unknown }
        return agents[agent.rawValue].flatMap(AgentReadiness.init(rawValue:)) ?? .unknown
    }
}

/// Reads and writes `~/.termio/devices/<host_id>.json`.
///
/// Deliberately not `@MainActor`: probing a machine happens off the main thread
/// and writing the result should not have to hop back. Every failure is
/// swallowed to a `nil` — a cache that cannot be read is indistinguishable from
/// one that was never written, and neither is worth interrupting the user for.
enum DeviceStateCache {
    static var directory: URL {
        AppChannel.homeConfigDirectory.appendingPathComponent("devices", isDirectory: true)
    }

    /// One machine's file. The key is sanitized because it may be a
    /// `~/.ssh/config` alias before a handshake has produced a `host_id`, and an
    /// alias is whatever the user typed — including a `/`, which would otherwise
    /// name a subdirectory.
    static func url(for key: String) -> URL {
        let safe = key.map { $0.isLetterOrDigitOrSafe ? $0 : "_" }
        return directory.appendingPathComponent(String(safe) + ".json", isDirectory: false)
    }

    static func load(_ key: String) -> DeviceDiscoveredState? {
        guard let data = try? Data(contentsOf: url(for: key)) else { return nil }
        return try? JSONDecoder.deviceCache.decode(DeviceDiscoveredState.self, from: data)
    }

    static func save(_ state: DeviceDiscoveredState, for key: String) {
        let file = url(for: key)
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder.deviceCache.encode(state)
            try data.write(to: file, options: .atomic)
        } catch {
            // A cache that could not be written costs one extra probe next launch.
            Log.app.debug(
                "could not cache device state: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Forgets what we think we know about a machine. The pane's "Check Again"
    /// path, and the reason nothing may treat this file as authority.
    static func forget(_ key: String) {
        try? FileManager.default.removeItem(at: url(for: key))
    }

    /// Records that this build's hooks and skill landed on a machine, leaving the
    /// probe results already cached beside them alone.
    ///
    /// An installer that reaches a machine has learned one thing about it for
    /// free — that it answered — which is why a machine with no file yet gets one
    /// saying so rather than nothing. It learned nothing about which agent CLIs
    /// are there, so `agents` stays empty and every row on that machine keeps
    /// reading `unknown` until something actually asks.
    /// Records an install against what the machine was last known to have. The
    /// agent list is taken from the cache rather than a fresh probe because this
    /// is the Agents-tab path, which installs across the whole roster without
    /// asking any machine anything — stamping what we knew is honest, and a
    /// machine whose agents have changed since reads as needing setup, which is
    /// exactly what it needs.
    static func stampIntegration(_ version: String?, for key: String) {
        var state = load(key) ?? DeviceDiscoveredState(checkedAt: Date(), reachable: true)
        state.integrationVersion = version
        state.integrationAgents = version == nil ? nil : state.availableAgents
        save(state, for: key)
    }
}

private extension Character {
    var isLetterOrDigitOrSafe: Bool {
        isLetter || isNumber || self == "-" || self == "_" || self == "."
    }
}

private extension JSONEncoder {
    /// Pretty-printed with ISO dates: the file is meant to be openable when
    /// someone is working out why a machine reads as unreachable.
    static var deviceCache: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var deviceCache: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
