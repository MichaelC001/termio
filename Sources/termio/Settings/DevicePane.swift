import AppKit
import SwiftUI

/// One machine's pane: the outcome line, how it is reached, and what it runs.
///
/// The section order is the D2 decision made visible. *Reached by* is the route —
/// the `~/.ssh/config` half the old Devices tab was entirely made of. *Runs* is
/// the identity — what is installed on that box, which had nowhere to live
/// before. A machine is both, and reading them in that order is how someone
/// works out why a box is not ready: you cannot install anything on a machine you
/// cannot reach.
///
/// Above both sits D6's single line. Deploy `termiod` → probe agent CLIs →
/// install hooks and skill is a real dependency chain, and a wrong primary UI:
/// four rungs with independent states turn choosing a machine into infrastructure
/// triage. So the pane promises one outcome — "Ready", or "Set up this device" —
/// and the rungs are the disclosure underneath it.
struct DevicePane: View {
    let machine: KnownDevice
    let host: SSHConfigHost?
    @ObservedObject var settings: AppSettings
    /// The key an install would put on this host, or `nil` when there is none to
    /// send — which decides whether the password advice can offer a fix.
    let keyToInstall: SSHPublicKey?
    let onConnect: (String) -> Void
    let onSetUpKey: (String, String) -> Void
    let onEditConfig: () -> Void

    @StateObject private var model: DevicePaneModel
    private enum ProbeState { case idle, running, result(SSHProbeResult) }
    @State private var probe: ProbeState = .idle

    init(
        machine: KnownDevice,
        host: SSHConfigHost?,
        settings: AppSettings,
        keyToInstall: SSHPublicKey?,
        onConnect: @escaping (String) -> Void,
        onSetUpKey: @escaping (String, String) -> Void,
        onEditConfig: @escaping () -> Void
    ) {
        self.machine = machine
        self.host = host
        self.settings = settings
        self.keyToInstall = keyToInstall
        self.onConnect = onConnect
        self.onSetUpKey = onSetUpKey
        self.onEditConfig = onEditConfig
        _model = StateObject(wrappedValue: DevicePaneModel(device: machine, settings: settings))
    }

    var body: some View {
        Form {
            Section { header }
            Section { outcome } header: {
                SectionHeaderLabel(title: localized("Status"))
            }
            reachedBySection
            runsSection
            integrationSection
        }
        .formStyle(.grouped)
        .navigationTitle(machine.name)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            IconBadge(.symbol(machine.isLocal ? "laptopcomputer" : "server.rack"))
                .scaleEffect(1.4)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(machine.name)
                    .font(.title3.weight(.semibold))
                Text(machine.isLocal
                     ? localized("The machine Termio is running on")
                     : host?.destinationLabel ?? localized("Reached over SSH"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let alias = machine.alias {
                Spacer(minLength: 8)
                Button(localized("Connect")) { onConnect(alias) }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: D6 — one outcome

    @ViewBuilder
    private var outcome: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                SettingsLabel(title: outcomeTitle, subtext: outcomeSubtext, titleFont: .headline)
                Spacer(minLength: 8)
                if model.readiness.isBusy {
                    ProgressView().controlSize(.small)
                } else if case .ready = model.readiness {
                    Button(localized("Check Again")) { Task { await model.check() } }
                } else {
                    Button(localized("Set Up \(machine.name)")) { Task { await model.setUp() } }
                }
            }
            if let feedback = model.feedback {
                InstallFeedbackLabel(feedback: feedback)
            }
        }
        .task {
            // Asked when the pane opens, not when the roster draws: one machine,
            // because someone is looking at it.
            guard case .unasked = model.readiness, model.discovered == nil else { return }
            await model.check()
        }
    }

    private var outcomeTitle: String {
        switch model.readiness {
        case .ready: return localized("Ready")
        case .checking: return model.step?.label ?? localized("Checking…")
        case .blocked, .unasked: return localized("Set up this device")
        }
    }

    private var outcomeSubtext: String {
        switch model.readiness {
        case .ready:
            // Only promise the reporting when it was actually asked for: with both
            // integration switches off, setup deliberately installs nothing, and
            // "reports their status back here" would be a claim about hooks that
            // are not there.
            return reportsStatus
                ? localized("Agents on \(machine.name) can run, and report their status back here.")
                : localized("Agents on \(machine.name) can run.")
        case .checking:
            return localized("Asking \(machine.name) what it has.")
        case .blocked(let reason):
            // Only the first blocking rung, by design: a machine with no `termiod`
            // also has no hooks, and naming both invites fixing the consequence.
            return reason
        case .unasked:
            return machine.isLocal
                ? localized("Installs the `\(CommandLineTool.toolName)` command-line tool, then Termio’s hooks and skill for each agent.")
                : localized("Deploys `termiod`, looks for your agent CLIs, then installs Termio’s hooks and skill.")
        }
    }

    /// Whether anything on this machine is meant to report status — the two
    /// switches live on the Agents tab, because wanting the feature is a
    /// preference and installing it is a machine operation (RFC §D1).
    private var reportsStatus: Bool {
        settings.agentHooksEnabled || settings.sessionControlEnabled
    }

    // MARK: Reached by — the route half

    @ViewBuilder
    private var reachedBySection: some View {
        Section {
            if machine.isLocal {
                Text(localized("Nothing to reach — this is the machine you’re on."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent {
                    probeControl
                } label: {
                    SettingsLabel(
                        title: host?.destinationLabel ?? machine.name,
                        subtext: host?.identityFile.map { localized("Signs in with \($0)") }
                            ?? localized("Signs in with the keys ssh offers by default."),
                        titleFont: .headline
                    )
                }
                if case .result(.wantsPassword) = probe { passwordAdvice }
                LabeledContent {
                    Button(localized("Edit"), action: onEditConfig)
                } label: {
                    SettingsLabel(
                        title: localized("Host block"),
                        subtext: localized("Opens the ~/.ssh/config entry this machine is defined in."),
                        titleFont: .headline
                    )
                }
            }
        } header: {
            SectionHeaderLabel(title: localized("Reached by"))
        }
    }

    /// The one probe outcome with a fix worth offering in place. A password is a
    /// dead end for everything but the plain shell — the daemon connections that
    /// carry sessions and the file tree set `BatchMode=yes` and can never answer a
    /// prompt — so the row says that plainly and offers the install that ends it.
    @ViewBuilder
    private var passwordAdvice: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(keyToInstall == nil
                 ? localized("This host takes a password. Termio signs in with keys, and ~/.ssh has none that ssh offers on its own — run ssh-keygen to make one, then set it up here.")
                 : localized("This host takes a password. Termio signs in with keys, so set yours up once and every session, file tree and remote terminal can reach it."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let keyToInstall, let alias = machine.alias {
                Button(localized("Set Up Key…")) { onSetUpKey(alias, keyToInstall.url.path) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(localized("Runs ssh-copy-id with \(keyToInstall.name) in a terminal — the host asks for your password once, there."))
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var probeControl: some View {
        switch probe {
        case .idle:
            Button(localized("Test"), action: runProbe)
        case .running:
            ProgressView()
                .controlSize(.small)
                .frame(minWidth: 44)
        case .result(let outcome):
            Button(action: runProbe) {
                Text(outcome.label)
                    .foregroundStyle(outcome.tint)
                    .lineLimit(1)
            }
            .buttonStyle(.borderless)
            .help(localized("\(outcome.detail) — click to re-test"))
        }
    }

    private func runProbe() {
        guard let alias = machine.alias else { return }
        probe = .running
        Task { @MainActor in
            probe = .result(await SSHConfigFile.testConnection(alias: alias))
        }
    }

    // MARK: Runs — the identity half

    private var runsSection: some View {
        Section {
            ForEach(listedAgents) { preset in
                MachineAgentRow(
                    preset: preset,
                    machine: machine,
                    settings: settings,
                    readiness: model.readiness.isBusy ? nil : model.readiness(for: preset)
                )
            }
            if listedAgents.isEmpty {
                Text(localized("No agents on your list yet — add one in Settings ▸ Agents."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            SectionHeaderLabel(title: localized("Runs"))
        } footer: {
            Text(localized("Where each agent’s CLI lives on \(machine.name). Leave a path empty to use the agent’s default."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var listedAgents: [AgentPreset] {
        settings.orderedAgents(AgentPreset.codingAgents.filter(settings.isAgentListed))
    }

    // MARK: The ladder, as disclosure

    /// The rungs behind the one line. Each is still individually runnable — a
    /// config hand-edited after Termio wrote it is exactly what "Reinstall" is
    /// for — but none of them is the primary action.
    private var integrationSection: some View {
        Section {
            if machine.isLocal {
                CommandLineToolRow()
            } else {
                LabeledContent {
                    Button(localized("Deploy")) { Task { await model.setUp() } }
                        .disabled(model.readiness.isBusy)
                } label: {
                    SettingsLabel(
                        title: "termiod",
                        subtext: localized("The session host on \(machine.name). Sessions keep running there after you disconnect."),
                        titleFont: .headline
                    )
                }
            }
            InstallButtonRow(title: localized("Reinstall hooks")) {
                .summarizing(
                    AgentStatusHooks.sync(
                        enabled: settings.agentHooksEnabled, target: machine.integrationTarget),
                    headline: localized("Hooks reinstalled"), unit: localized("agents"))
            }
            InstallButtonRow(title: localized("Reinstall skill")) {
                .summarizing(
                    SessionSkillInstaller.sync(
                        enabled: settings.sessionControlEnabled, target: machine.integrationTarget),
                    headline: localized("Skill reinstalled"), unit: localized("agents"))
            }
        } header: {
            SectionHeaderLabel(title: localized("Installed by Termio"))
        } footer: {
            Text(localized("Live agent status and session control are switched on in Settings ▸ Agents; this installs them on \(machine.name)."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// One agent's presence on one machine, and the path it launches from there.
///
/// The readiness word is D4's three-state rule. `nil` means the probe has not
/// answered yet and the row says nothing rather than guessing — the same
/// don't-cry-wolf discipline `AgentAvailability` follows, extended to the case
/// that only exists once a machine is reached over a network.
private struct MachineAgentRow: View {
    let preset: AgentPreset
    let machine: KnownDevice
    @ObservedObject var settings: AppSettings
    let readiness: AgentReadiness?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                IconBadge(preset.icon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.displayName)
                    if let status {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                TextField(
                    "",
                    text: Binding(
                        get: { settings.commandPath(for: preset, on: machine) ?? "" },
                        set: { settings.setCommandPath($0, for: preset, on: machine) }
                    ),
                    prompt: Text(preset.command ?? localized("Login shell"))
                )
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .labelsHidden()
                .frame(minWidth: 140)
                if readiness == .missing {
                    Image(systemName: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help(localized("\(preset.displayName) isn’t installed on \(machine.name)"))
                }
            }
        }
    }

    /// A present CLI says nothing — the path field beside it is already the whole
    /// answer. The other two states are the ones worth a word.
    private var status: String? {
        switch readiness {
        case .missing: return localized("Not installed on \(machine.name)")
        case .unknown: return localized("Can’t check on \(machine.name)")
        case .available, nil: return nil
        }
    }
}

/// Installs and reports the `termio` command-line tool on **this Mac**.
///
/// It moved off the General tab because installing a CLI on a machine is a
/// machine operation (RFC §D8) — here it sits beside "deploy `termiod`", which is
/// the same rung on every other machine's pane.
///
/// Installs and reports the `termio` command-line tool, as a switch like the other
/// feature rows: on means the PATH symlink exists, off removes it. The switch is
/// bound to the audit, not a stored preference, so it always reflects reality (a
/// declined admin prompt snaps it back). It audits on appear (a moved app shows
/// "Update") and re-audits after every action so the caption updates in place.
struct CommandLineToolRow: View {
    @State private var status: CommandLineTool.Status = .notInstalled
    @State private var state = InstallFeedbackState()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { isOn }, set: { setEnabled($0) })) {
                SettingsLabel(
                    title: localized("Command-line tool"), subtext: description, titleFont: .headline)
            }
            .toggleStyle(.switch)
            .disabled(!isSwitchable)
            if let feedback = state.feedback {
                InstallFeedbackLabel(feedback: feedback)
            }
        }
        .onAppear { status = CommandLineTool.audit() }
        .autoDismissing($state)
        if isOn {
            // For re-linking after something else has touched /usr/local/bin;
            // install is idempotent. Reports through its own feedback line.
            InstallButtonRow(title: buttonTitle) { withAnimation { runInstall() } }
        }
    }

    private var isOn: Bool {
        switch status {
        case .installed, .stale: return true
        case .notInstalled, .conflict, .unavailable: return false
        }
    }

    /// A conflicting file isn't ours to remove and a bare binary has nothing to
    /// link, so in both states the switch is disabled and the caption explains.
    private var isSwitchable: Bool {
        switch status {
        case .installed, .stale, .notInstalled: return true
        case .conflict, .unavailable: return false
        }
    }

    private func setEnabled(_ enabled: Bool) {
        withAnimation {
            if enabled {
                state.show(runInstall())
            } else {
                status = CommandLineTool.uninstall()
                state.show(isOn
                    ? .failure(localized("Couldn’t remove \(CommandLineTool.installURL.path)."))
                    : .success(localized("Removed from PATH.")))
            }
        }
    }

    /// Installs, then reports the fresh audit. The caption alone can't carry this:
    /// a declined admin prompt leaves the row reading exactly as it did before the
    /// click, so success and cancellation would be indistinguishable. The
    /// confirmation stays short — the caption above it already names the path — and
    /// echoes the verb that was offered: an "Update" that lands says "Updated."
    private func runInstall() -> InstallFeedback {
        let wasStale: Bool
        if case .stale = status { wasStale = true } else { wasStale = false }
        let result = CommandLineTool.install()
        status = result
        switch result {
        case .installed:
            return .success(wasStale ? localized("Updated.") : localized("Installed."))
        case .conflict:
            return .failure(localized("Something else already owns \(CommandLineTool.installURL.path)."))
        case .unavailable:
            return .failure(localized("No bundled tool to install from."))
        case .notInstalled, .stale:
            let directory = CommandLineTool.installURL.deletingLastPathComponent().path
            return .failure(localized("Couldn’t link `\(CommandLineTool.toolName)` into \(directory)."))
        }
    }

    private var description: String {
        let tool = CommandLineTool.toolName
        switch status {
        case .installed:
            return localized("`\(tool)` is on your PATH. Run `\(tool) sessions …` to drive sibling sessions, or `\(tool) .` to open a folder.")
        case .stale(let path):
            return localized("An older install points at \(path). Update it to this version of Termio.")
        case .notInstalled:
            return localized("Links `\(tool)` into /usr/local/bin so you (and agents) can run `\(tool) sessions …` from any shell.")
        case .conflict:
            return localized("A different `\(tool)` already exists at \(CommandLineTool.installURL.path). Remove it first — Termio won’t overwrite a file it didn’t create.")
        case .unavailable:
            return localized("Available when Termio runs from the built app bundle.")
        }
    }

    private var buttonTitle: String {
        if case .stale = status { return localized("Update") }
        return localized("Reinstall")
    }
}
