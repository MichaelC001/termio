import AppKit
import SwiftUI

/// The Agents tab as a drill-down, the shape System Settings ▸ Notifications has:
/// one pane holding a grouped roster of agents, each row carrying its mark, its
/// name and a status line, and each row pushing that agent's configuration onto the
/// settings window's own navigation stack. The earlier master–detail split gave the
/// window a third column no other tab had.
///
/// This tab is *what you use*: the enabled set, the order, the default agent and
/// the integration switches are preferences, and they have no machine dimension.
/// The values that do — where a CLI lives, whether it is there — are shown here
/// **once per machine**, never behind a machine picker.
///
/// A picker was tried and is the thing this shape exists to replace. It is a
/// mode: a control that changes what the rest of the page means, so the machine
/// has to be remembered rather than read, a mis-remembered one quietly configures
/// the wrong box, and the machines you are *not* looking at — the ones missing a
/// CLI — are exactly the ones it hides. It also does not generalise: every other
/// page touching a machine would need its own copy, and the phone would need one
/// too.
///
/// So machines are rows. Exactly one surface selects a machine, and it is the
/// Devices list. The property that makes this affordable everywhere: **a roster
/// of one renders exactly as this page did before there was more than one
/// machine** — no list, no labels, no bar. A picker with one option cannot do
/// that; it still costs a row.
struct AgentSettingsTab: View {
    @ObservedObject var settings: AppSettings
    /// The store the device roster and the readiness lines read from.
    @ObservedObject var store: TermioStore

    /// Every machine Termio has worked on. The same roster the Devices tab lists,
    /// so a machine appears here the moment it is real and never before.
    private var devices: [KnownDevice] { DeviceRoster.known(in: store) }

    /// The machines this build's hooks and skill have not reached, as one line.
    /// Read from their device files off the main actor rather than in `body`,
    /// which would put N file reads in every redraw.
    @State private var integrationGap: String?

    /// Bumped after every catalog reload. `AgentDefinition` equality is by id, so
    /// without this a rename would leave stale rows on screen; referencing the
    /// version in `body` forces a recompute from the fresh catalog.
    @State private var catalogVersion = 0

    /// The agents the user actually manages, in the user's arrangement. The plain
    /// Terminal is not here — it's the login shell, configured on the Terminal tab and
    /// always available, so it's never an enable/reorder row (see `AgentDefinition.isShell`).
    private var listedAgents: [AgentPreset] {
        settings.orderedAgents(AgentPreset.codingAgents.filter(settings.isAgentListed))
    }
    private var addableAgents: [AgentPreset] {
        settings.orderedAgents(AgentPreset.codingAgents.filter { !settings.isAgentListed($0) })
    }

    var body: some View {
        let _ = catalogVersion
        // A grouped `Form`, like every other pane. It was a `List` because
        // `onMove` is only honoured by an editable list — in a `Form` the same
        // rows render and silently stop reordering, and agent order is what
        // the New Chat menu reads. That is a real constraint, so reordering
        // was rebuilt rather than dropped: rows are draggable onto each other,
        // and the context menu carries Move Up / Move Down, which works
        // whatever a drag does.
        Form {
            Section {
                DefaultChatAgentRow(settings: settings)
            } header: {
                SectionHeaderLabel(title: localized("New chat"))
            }

            Section {
                Toggle(isOn: $settings.agentHooksEnabled) {
                    SettingsLabel(
                        title: localized("Live agent status"),
                        subtext: localized("Shows when an agent is working or waiting on you — the sidebar spinner and menu-bar pulse."),
                        titleFont: .headline
                    )
                }
                .toggleStyle(.switch)
                Toggle(isOn: $settings.sessionControlEnabled) {
                    SettingsLabel(
                        title: localized("Session control"),
                        subtext: localized("Lets an agent see and drive its sibling sessions in this project via the `termio sessions` command."),
                        titleFont: .headline
                    )
                }
                .toggleStyle(.switch)
                // The switches are the preference; putting the files on a machine
                // is a machine operation. It runs on **every** machine rather than
                // on a chosen one: wanting live status is one decision, and asking
                // it once per box was the picker's tax. A bare button under a
                // toggle reads as attached to that toggle, so it stays a labelled
                // row — it is its own action, both switches at once, everywhere.
                InstallButtonRow(title: installTitle) { await installIntegration() }
                if let integrationGap {
                    Text(integrationGap)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                SectionHeaderLabel(title: localized("Integration"))
            } footer: {
                Text(devices.count > 1
                    ? localized("Whether you want these at all, and putting them on every device.")
                    : localized("Whether you want these at all, and putting them on this Mac."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(listedAgents) { preset in
                    NavigationLink(value: AgentRoute(id: preset.id)) {
                        AgentListRow(settings: settings, preset: preset, devices: devices)
                    }
                    .draggable(preset.id)
                    .dropDestination(for: String.self) { ids, _ in
                        guard let dragged = ids.first else { return false }
                        return move(dragged, onto: preset)
                    }
                    .contextMenu {
                        Button(localized("Move Up")) { move(preset, by: -1) }
                            .disabled(listedAgents.first?.id == preset.id)
                        Button(localized("Move Down")) { move(preset, by: 1) }
                            .disabled(listedAgents.last?.id == preset.id)
                        Divider()
                        Button(localized("Remove from List")) { remove(preset) }
                    }
                }
                AddAgentGutter(
                    addable: addableAgents,
                    onAdd: add,
                    onCustom: createCustomAgent
                )
            } header: {
                SectionHeaderLabel(title: localized("Agents"))
            } footer: {
                // Only worth saying once there is more than one machine to cover.
                // On a roster of one the sentence would be true and pointless, and
                // this page's whole claim is that a single machine costs nothing.
                Text(devices.count > 1
                    ? localized("Drag an agent onto another to reorder. Readiness covers every device you work on.")
                    : localized("Drag an agent onto another to reorder."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationDestination(for: AgentRoute.self) { route in
            detail(for: route.id)
        }
        .task(id: integrationKey) { await refreshIntegrationGap() }
        // Custom agents are edited in their manifest, in another app. Re-reading
        // the catalog when termio comes back to the front is what makes that land.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            AgentCatalog.reload()
            catalogVersion += 1
        }
    }

    // MARK: Integration

    /// A roster of one has no machine worth choosing between, so the button says
    /// what it always said. Beyond one, "All Devices" is the honest name for what
    /// it does — and the reason no machine has to be picked first.
    private var installTitle: String {
        devices.count > 1
            ? localized("Install on All Devices")
            : localized("Install on \(devices.first?.name ?? KnownDevice.thisMac.name)")
    }

    /// Re-read whenever the roster or either switch changes: turning a switch on
    /// is exactly when "and it is not on `devbox` yet" becomes worth saying.
    private var integrationKey: String {
        "\(devices.map(\.settingsKey).joined(separator: "|"))"
            + "#\(settings.agentHooksEnabled)#\(settings.sessionControlEnabled)"
    }

    /// Installs on every machine at once, and reports by machine.
    ///
    /// Per-machine `Reinstall` is not duplicated here — it already lives on each
    /// machine's own pane, which is where a config hand-edited after Termio wrote
    /// it gets fixed. This button exists for the other case, the common one: a new
    /// box that should carry what all the others do.
    private func installIntegration() async -> InstallFeedback {
        // Read the preferences here, on the main actor — see `InstallButtonRow`.
        // The writing is the installer's own business: it keeps its file work and
        // its daemon calls off this thread rather than being wrapped in a
        // `Task.detached` that could only wait for them.
        let hooksWanted = settings.agentHooksEnabled
        let controlWanted = settings.sessionControlEnabled
        let stamp = AppInfo.buildStamp
        let roster = devices.map {
            (key: $0.settingsKey, name: $0.name, target: $0.integrationTarget)
        }
        var perDevice: [(name: String, outcome: InstallOutcome)] = []
        for machine in roster {
            // One message for both switches: the daemon on that machine writes
            // the hooks and the skill in one pass.
            let outcome = await AgentIntegrationInstaller.sync(
                hooks: hooksWanted ? .install : .remove,
                skills: controlWanted ? .install : .remove,
                target: machine.target)
            if outcome.failed.isEmpty && !outcome.isEmpty {
                DeviceStateCache.stampIntegration(stamp, for: machine.key)
            }
            perDevice.append((machine.name, outcome))
        }
        let feedback: InstallFeedback
        // One machine: report which agents took it, exactly as before. Naming
        // the only machine there is says nothing; the agents are the news.
        if perDevice.count == 1, let only = perDevice.first {
            feedback = .summarizing(
                only.outcome, headline: localized("Installed"), unit: localized("agents"))
        } else if perDevice.allSatisfy({ $0.outcome.isEmpty }) {
            // Nothing was asked for anywhere: both switches off leaves every
            // machine with an empty outcome.
            feedback = .failure(localized("Nothing to install."))
        } else {
            // Several: the machine is the news, and a per-agent list across four
            // boxes is a paragraph.
            var fleet = InstallOutcome()
            for machine in perDevice {
                fleet.record(machine.name, installed: machine.outcome.failed.isEmpty)
            }
            feedback = .summarizing(
                fleet, headline: localized("Installed"), unit: localized("devices"))
        }
        await refreshIntegrationGap()
        return feedback
    }

    /// Which machines are behind, in one line — the fleet answer a picker could
    /// not give, since it shows one machine at a time.
    ///
    /// Silent on a roster of one: there the button beside it is the whole story,
    /// and a standing "not installed on This Mac" under two switches the user has
    /// just turned on reads as a fault rather than as a next step.
    private func refreshIntegrationGap() async {
        guard devices.count > 1,
              settings.agentHooksEnabled || settings.sessionControlEnabled
        else {
            integrationGap = nil
            return
        }
        let roster = devices.map { (key: $0.settingsKey, name: $0.name) }
        let behind = await Task.detached(priority: .utility) {
            roster
                .filter { DeviceStateCache.load($0.key)?.carriesCurrentIntegration != true }
                .map(\.name)
        }.value
        integrationGap = behind.isEmpty ? nil : localized(
            "Not installed on \(InstallOutcome.list(behind, unit: localized("devices"))).")
    }

    // MARK: Pushed pane

    @ViewBuilder
    private func detail(for id: String) -> some View {
        if let preset = listedAgents.first(where: { $0.id == id }) {
            AgentDetailPane(
                settings: settings,
                preset: preset,
                devices: devices,
                onRemove: { remove(preset) },
                // Editing and deletion exist only for agents backed by a user
                // manifest; bundled agents just leave the list.
                isUserDefined: AgentCatalog.shared.isUserDefined(preset.id),
                onDelete: AgentCatalog.shared.isUserDefined(preset.id)
                    ? { deleteCustom(preset) } : nil
            )
            // Distinct identity per agent — and per catalog generation, so a
            // rename rebuilds the pane (definitions compare equal by id).
            .id("\(preset.id)#\(catalogVersion)")
        } else {
            // The agent went away under us (a manifest deleted outside the app).
            MissingAgentPane()
        }
    }

    /// Adds the agent's row, then lets the availability probe decide the switch: an
    /// installed CLI turns it on; a missing one leaves it off, with the row saying
    /// so and its pane carrying the install link.
    private func add(_ preset: AgentPreset) {
        settings.addAgent(preset)
        Task { @MainActor in
            if await AgentAvailability.isCommandAvailable(settings.command(for: preset) ?? "") {
                settings.setAgent(preset, enabled: true)
            }
        }
    }

    private func remove(_ preset: AgentPreset) {
        settings.removeAgent(preset)
    }

    /// Seeds a starter manifest, puts it on the list, and opens the file — the
    /// manifest is the editor for a custom agent, so Settings' job ends at handing
    /// over a valid one. The row lands switched off (the placeholder command
    /// resolves to nothing) and turns on once the file names a real CLI.
    private func createCustomAgent() {
        let created: (id: String, file: URL)
        do {
            created = try UserAgentStore.createTemplate()
        } catch {
            AgentCatalog.log("could not create a custom agent manifest: \(error)")
            NSSound.beep()
            return
        }
        AgentCatalog.reload()
        catalogVersion += 1
        settings.addAgent(AgentCatalog.shared.definition(for: created.id))
        NSWorkspace.shared.open(created.file)
    }

    /// Deletes a user agent's manifest file (its sessions survive via the id-only
    /// fallback definition). Confirmation lives on the button in the pushed pane.
    private func deleteCustom(_ preset: AgentPreset) {
        do {
            try UserAgentStore.delete(id: preset.id)
        } catch {
            AgentCatalog.log("could not delete \(preset.id): \(error)")
            return
        }
        remove(preset)
        AgentCatalog.reload()
        catalogVersion += 1
    }

    /// Persists a drag as the new arrangement; `setEnabledOrder` keeps every
    /// other id ranked behind it so the ordering stays total.
    /// Drops `draggedID` at `target`'s position. Returns false for a drag that
    /// changes nothing, so a row dropped on itself is not recorded as an edit.
    private func move(_ draggedID: String, onto target: AgentPreset) -> Bool {
        var ids = listedAgents.map(\.id)
        guard draggedID != target.id,
              let from = ids.firstIndex(of: draggedID),
              let to = ids.firstIndex(of: target.id)
        else { return false }
        ids.remove(at: from)
        ids.insert(draggedID, at: to)
        settings.setEnabledOrder(ids)
        return true
    }

    /// The keyboard- and menu-reachable half of reordering. Drag is the nice way;
    /// this is the way that cannot quietly stop working, which matters because
    /// the last container change is exactly what broke `onMove`.
    private func move(_ preset: AgentPreset, by offset: Int) {
        var ids = listedAgents.map(\.id)
        guard let from = ids.firstIndex(of: preset.id) else { return }
        let to = from + offset
        guard ids.indices.contains(to) else { return }
        ids.swapAt(from, to)
        settings.setEnabledOrder(ids)
    }
}

/// What a row pushes. A named type rather than the bare id string so the settings
/// window's shared navigation stack can't confuse an agent with some other pane's
/// string destination.
private struct AgentRoute: Hashable {
    let id: String
}

/// The roster's add and remove actions, in the list's own gutter (see
/// `SettingsListGutter`).
///
/// The roster's add action, in the list's own gutter (see `SettingsListGutter`).
///
/// A pull-down rather than a plain button: the agents worth adding are a known
/// list, and a sheet to pick one from it would be a window for a menu's worth of
/// choice.
private struct AddAgentGutter: View {
    let addable: [AgentPreset]
    let onAdd: (AgentPreset) -> Void
    let onCustom: () -> Void

    var body: some View {
        SettingsListGutter {
            Menu {
                // Plain text rows: AppKit menus rasterize custom SwiftUI icon
                // views at their natural image size, not the badge frame.
                ForEach(addable) { preset in
                    Button(preset.displayName) { onAdd(preset) }
                }
                if !addable.isEmpty { Divider() }
                Button(localized("Custom Agent…")) { onCustom() }
            } label: {
                SettingsGutterGlyph(symbol: "plus")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help(localized("Add Agent"))
            .accessibilityLabel(localized("Add Agent"))
        }
    }
}

/// One agent on the roster: brand mark, name, a second line, and the switch that
/// decides whether the agent is offered at all — the shape a Sharing row has, where
/// the on/off state is the thing you came to read and the row still opens onto the
/// details behind it.
///
/// The switch lived in the pushed pane, which made the roster's whole point — which
/// agents are on — a click deep per row, and cost the line a leading "Off ·" to say
/// what a switch says by being off. The second line is now only ever the command
/// the agent launches with, bypass flag and all, led by anything that blocks that
/// launch.
private struct AgentListRow: View {
    @ObservedObject var settings: AppSettings
    let preset: AgentPreset
    /// Every machine on the roster. The line answers for all of them at once:
    /// this row's subject is the agent, and *which machines it is missing on* is
    /// the part a line pinned to one machine could never say.
    let devices: [KnownDevice]

    /// `nil` while the probe is still running: show nothing rather than a
    /// premature warning.
    @State private var fleet: AgentFleetReadiness?

    /// Whether *this Mac* can launch it, which is what the switch is allowed to
    /// gate. The fleet answer is the wrong one for that: an agent installed here
    /// and missing on a sleeping VPS is still perfectly launchable, and a switch
    /// dimmed by a box you are not sitting at cannot be argued with.
    @State private var availableHere: Bool?

    /// Nothing to say about an agent present everywhere — the common case, where
    /// the line is the command alone.
    private var status: String? { fleet?.summary }

    /// This Mac's command. A machine with its own path shows it on its own row in
    /// the pushed pane; repeating four of them here would make the roster a table.
    private var detail: String {
        let command = settings.command(for: preset) ?? localized("Login shell")
        guard let status else { return command }
        return localized("\(status) · \(command)")
    }

    private var probeTargets: [(device: KnownDevice, command: String)] {
        devices.map { ($0, settings.command(for: preset, on: $0) ?? "") }
    }

    var body: some View {
        HStack(spacing: 10) {
            IconBadge(preset.icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.displayName)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            // Only a machine that answered earns the badge. `unknown` says so in
            // words instead: a warning glyph for "we could not ask" is the false
            // alarm.
            if fleet?.hasMissing == true {
                Image(systemName: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help(missingHelp)
            }
            Toggle(isOn: Binding(
                get: { settings.isAgentEnabled(preset) },
                set: { settings.setAgent(preset, enabled: $0) }
            )) {
                EmptyView()
            }
            .toggleStyle(.switch)
            .labelsHidden()
            // A missing CLI can't be launched, so it can't be switched on — only
            // off (an already-on agent stays revocable while the badge shows).
            .disabled(availableHere == false && !settings.isAgentEnabled(preset))
            .help(localized("Offers \(preset.displayName) in the new-session menus."))
            .accessibilityLabel(localized("Enable \(preset.displayName)"))
        }
        // Re-probed when any machine's command changes, or when the roster does.
        .task(id: probeTargets.map { "\($0.device.settingsKey)=\($0.command)" }
            .joined(separator: "|")) {
            fleet = await AgentReadiness.acrossFleet(agent: preset, on: probeTargets)
        }
        .task(id: settings.command(for: preset) ?? "") {
            availableHere = await AgentAvailability.isCommandAvailable(
                settings.command(for: preset) ?? "")
        }
    }

    /// The tooltip names the machines even when the caption had to count them —
    /// a hover is where "which two?" gets answered without leaving the roster.
    private var missingHelp: String {
        let names = InstallOutcome.list(fleet?.missing ?? [], unit: localized("devices"))
        return localized("\(preset.displayName) isn’t installed on \(names)")
    }
}

/// The pushed pane for one agent: an identity header above a grouped form — the
/// enable switch, command override, install link when the CLI is missing, the
/// permission-bypass switch, and removal.
private struct AgentDetailPane: View {
    @ObservedObject var settings: AppSettings
    let preset: AgentPreset
    /// Every machine on the roster, one row apiece in the Launch section. Where a
    /// CLI lives is a fact about a machine — so the pane names all of them rather
    /// than making you choose one and then remember which you chose.
    let devices: [KnownDevice]
    let onRemove: () -> Void
    /// True for agents backed by a manifest in the user's config folder — the only
    /// ones whose file can be opened or deleted from here.
    var isUserDefined = false
    /// Set only for user-manifest agents: deletes the manifest file.
    var onDelete: (() -> Void)?

    @State private var confirmingDelete = false
    /// Removing or deleting takes the row away, so the pane it opened has to go
    /// back with it.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    IconBadge(preset.icon)
                        .scaleEffect(1.4)
                        .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preset.displayName)
                            .font(.title3.weight(.semibold))
                        Text(settings.command(for: preset) ?? localized("Login shell"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if isUserDefined {
                        Spacer(minLength: 8)
                        Button(localized("Reveal in Finder")) {
                            UserAgentStore.reveal(id: preset.id)
                        }
                        Button(localized("Edit Manifest")) {
                            UserAgentStore.open(id: preset.id)
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            Section {
                ForEach(devices) { device in
                    CommandPathRow(
                        settings: settings, preset: preset, device: device,
                        namesItsMachine: devices.count > 1)
                }
                LabeledContent {
                    if let url = preset.installURL {
                        Link(localized("Install Page"), destination: url)
                    } else {
                        Text(localized("None")).foregroundStyle(.secondary)
                    }
                } label: {
                    SettingsLabel(
                        title: localized("Get \(preset.displayName)"),
                        subtext: localized("The install page — the same one whichever machine you are installing on."),
                        titleFont: .headline
                    )
                }
            } header: {
                SectionHeaderLabel(title: localized("Launch"))
            } footer: {
                // Said once under the rows rather than repeated in every row's
                // subtext, which is where the readiness word goes once there is
                // more than one machine to report on.
                if devices.count > 1 {
                    Text(localized("Where each device launches \(preset.displayName) from. Leave empty to use its default."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let flag = preset.permissionBypassFlag {
                Section {
                    Toggle(isOn: Binding(
                        get: { settings.bypassesPermissions(preset) },
                        set: { settings.setBypassPermissions(preset, enabled: $0) }
                    )) {
                        SettingsLabel(
                            title: localized("Skip permission prompts"),
                            subtext: localized("Runs with `\(flag)`. The agent won’t ask before editing files or running commands.")
                        )
                    }
                    .toggleStyle(.switch)
                } header: {
                    SectionHeaderLabel(title: localized("Permissions"))
                }
            }

            Section {
                // Deliberately not red: nothing is destroyed — the agent folds back
                // into the "Add Agent" menu with its overrides intact, so no
                // confirmation either.
                LabeledContent {
                    Button(localized("Remove")) {
                        onRemove()
                        dismiss()
                    }
                } label: {
                    SettingsLabel(
                        title: localized("Remove from List"),
                        subtext: localized("Takes \(preset.displayName) out of the new-session menu. Its settings are kept.")
                    )
                }
                if let onDelete {
                    // Red and confirmed, unlike Remove: this one erases the
                    // manifest file the agent is made of.
                    LabeledContent {
                        Button(localized("Delete…"), role: .destructive) { confirmingDelete = true }
                            .confirmationDialog(
                                localized("Delete \(preset.displayName)?"),
                                isPresented: $confirmingDelete
                            ) {
                                Button(localized("Delete"), role: .destructive) {
                                    onDelete()
                                    dismiss()
                                }
                            } message: {
                                Text(localized("Removes this custom agent and its configuration file. Existing sessions keep running."))
                            }
                    } label: {
                        SettingsLabel(
                            title: localized("Delete Agent"),
                            subtext: localized("Deletes the custom agent’s manifest from this Mac.")
                        )
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(preset.displayName)
    }
}

/// One machine's command path for this agent.
///
/// A row per machine rather than one field behind a machine picker. The picker
/// changed what the field below it meant, so the machine had to be remembered
/// rather than read — and the machines you were not looking at, the ones missing
/// the CLI, were exactly the ones worth seeing. Rows have neither problem, and
/// they cost a single-machine user nothing, which is what lets them be the
/// default rather than a mode you switch into.
private struct CommandPathRow: View {
    @ObservedObject var settings: AppSettings
    let preset: AgentPreset
    let device: KnownDevice
    /// False on a roster of one, where naming the only machine there is carries
    /// no information: the row reverts to the plain `Path` field this pane has
    /// always had, with its original subtext.
    let namesItsMachine: Bool

    /// `nil` until the passive answer lands — a file read for a device, a cached
    /// `PATH` lookup for this Mac, so it is a frame, not a wait.
    @State private var readiness: AgentReadiness?

    var body: some View {
        LabeledContent {
            TextField(
                "",
                text: Binding(
                    get: { settings.commandPath(for: preset, on: device) ?? "" },
                    set: { settings.setCommandPath($0, for: preset, on: device) }
                ),
                prompt: Text(preset.command ?? localized("Login shell"))
            )
            .multilineTextAlignment(.trailing)
            .labelsHidden()
            .frame(minWidth: 180)
        } label: {
            SettingsLabel(title: title, subtext: subtext, titleFont: .headline)
        }
        // Keyed on the path so a corrected one re-reads without leaving the pane.
        // Passive by construction: probing live here would fire an `ssh` per
        // keystroke at every machine on the roster.
        .task(id: "\(device.settingsKey)#\(settings.command(for: preset, on: device) ?? "")") {
            readiness = await AgentReadiness.passive(
                agent: preset,
                command: settings.command(for: preset, on: device) ?? "",
                on: device)
        }
    }

    private var title: String {
        namesItsMachine ? device.name : localized("Path")
    }

    /// The machine's answer, always present rather than shown only when something
    /// is wrong: a caption that appears and disappears makes every row jump as the
    /// probes land.
    private var subtext: String {
        guard namesItsMachine else {
            return localized("Where \(preset.displayName) launches from on \(device.name). Leave empty to use its default.")
        }
        switch readiness {
        case .available: return localized("Installed")
        case .missing: return localized("Not installed")
        case .unknown: return localized("Can’t check")
        case nil: return localized("Checking…")
        }
    }
}

/// Shown when the pushed agent stops existing while its pane is open — a custom
/// agent's manifest deleted in Finder, say. Says so and leaves the back chevron to
/// carry the user out; popping from here would fight the pop the deleting button
/// already asked for.
private struct MissingAgentPane: View {
    var body: some View {
        ContentUnavailableView {
            Text(localized("Agent Unavailable"))
        } description: {
            Text(localized("This agent is no longer on your list."))
        }
    }
}

/// The "New chat" default-agent picker: which agent the single New Chat action
/// (⌘N, the `+` menu, the Chats header) launches. "Last used" keeps it adaptive
/// (the last agent you started a chat with); picking a specific agent pins it.
/// Only enabled agents are offered — a disabled one can't run a chat — and a
/// previously-pinned agent that is now disabled reads back as "Last used".
private struct DefaultChatAgentRow: View {
    @ObservedObject var settings: AppSettings

    /// Empty-string tag stands for "Last used" (agent ids are always non-empty),
    /// so the picker can carry the `nil` choice as a plain `String` selection.
    private let lastUsedTag = ""

    private var chatAgents: [AgentPreset] {
        enabledAgentPresets(settings).filter { !$0.isShell }
    }

    var body: some View {
        Picker(selection: selection) {
            Text(localized("Last used")).tag(lastUsedTag)
            ForEach(chatAgents) { Text($0.displayName).tag($0.id) }
        } label: {
            SettingsLabel(
                title: localized("Default agent"),
                subtext: localized("The agent New Chat (⌘N) starts. “Last used” follows whichever agent you most recently chatted with."),
                titleFont: .headline
            )
        }
    }

    /// Reads back the pinned id only while that agent is still enabled; otherwise
    /// falls to "Last used" so the control never shows a stale, unlaunchable choice.
    private var selection: Binding<String> {
        Binding(
            get: {
                if let id = settings.defaultChatAgentID,
                   chatAgents.contains(where: { $0.id == id }) { return id }
                return lastUsedTag
            },
            set: { settings.defaultChatAgentID = $0 == lastUsedTag ? nil : $0 }
        )
    }
}
