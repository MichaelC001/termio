import AppKit
import SwiftUI

/// The Agents tab as a drill-down, the shape System Settings ▸ Notifications has:
/// one pane holding a grouped roster of agents, each row carrying its mark, its
/// name and a status line, and each row pushing that agent's configuration onto the
/// settings window's own navigation stack. The earlier master–detail split gave the
/// window a third column no other tab had.
///
/// This tab is *what you use*, and nothing here is a fact about a machine (RFC
/// §D1). The enabled set, the order, the default agent and the integration
/// switches are preferences; where an agent's CLI lives and whether it is
/// installed belong to the machine that would run it, and are edited on that
/// machine's pane. What the roster carries of that is one **passive** readiness
/// line per agent, reported for the current workspace's device and never
/// editable here.
struct AgentSettingsTab: View {
    @ObservedObject var settings: AppSettings
    /// The store the device roster and the readiness line read from.
    @ObservedObject var store: TermioStore
    /// Which device this page is about. Shared with the other per-device pages
    /// (`SettingsView`), so switching here is still in force there.
    @Binding var deviceScope: String

    /// The machine the readiness line describes. It used to be
    /// `store.currentDevice` — ambient, invisible, and unchangeable, so the page
    /// reported one machine's readiness with nothing on screen naming it.
    private var device: KnownDevice { .onRoster(deviceScope, in: store) }

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
        VStack(spacing: 0) {
            DeviceScopeBar(store: store, selection: $deviceScope)
            Divider()
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
                    ForEach(listedAgents) { preset in
                        NavigationLink(value: AgentRoute(id: preset.id)) {
                            AgentListRow(settings: settings, preset: preset, device: device)
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
                    AddAgentRow(
                        addable: addableAgents,
                        onAdd: add,
                        onCustom: createCustomAgent
                    )
                } header: {
                    SectionHeaderLabel(title: localized("Agents"))
                } footer: {
                    // No longer names the device: the picker above does, and a
                    // footnote repeating it goes stale the moment it is changed.
                    Text(localized("Drag an agent onto another to reorder. Readiness is for the device above."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    // The switch is the preference; putting the files on a
                    // machine is a machine operation — but the machine is named
                    // by the control at the top of this page, so it happens here
                    // rather than sending you to another tab to finish the job.
                    // A bare button under a toggle reads as attached to that
                    // toggle. As a labelled row it reads as its own action, which
                    // is what it is — both switches at once, on one machine.
                    InstallButtonRow(title: localized("Install on \(device.name)")) {
                        // One message for both switches: the daemon on that
                        // machine writes the hooks and the skill in one pass.
                        .summarizing(
                            await AgentIntegrationInstaller.sync(
                                hooks: settings.agentHooksEnabled ? .install : .remove,
                                skills: settings.sessionControlEnabled ? .install : .remove,
                                target: device.integrationTarget),
                            headline: localized("Installed"), unit: localized("agents"))
                    }
                } header: {
                    SectionHeaderLabel(title: localized("Integration"))
                } footer: {
                    Text(localized("Whether you want these at all, and putting them on the selected device."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .navigationDestination(for: AgentRoute.self) { route in
            detail(for: route.id)
        }
        // Custom agents are edited in their manifest, in another app. Re-reading
        // the catalog when termio comes back to the front is what makes that land.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            AgentCatalog.reload()
            catalogVersion += 1
        }
    }

    // MARK: Pushed pane

    @ViewBuilder
    private func detail(for id: String) -> some View {
        if let preset = listedAgents.first(where: { $0.id == id }) {
            AgentDetailPane(
                settings: settings,
                preset: preset,
                device: device,
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

/// The roster's add action, as the last row of the roster.
///
/// A pull-down rather than a button: the agents worth adding are a known list,
/// and a sheet to pick one from it would be a window for a menu's worth of
/// choice. Styled as a row of the group — inside a grouped `Form` the card
/// already draws the surface, so a second rounded rect on top of it is what made
/// this read as bolted on to the window's bottom edge.
private struct AddAgentRow: View {
    let addable: [AgentPreset]
    let onAdd: (AgentPreset) -> Void
    let onCustom: () -> Void

    var body: some View {
        Menu {
            // Plain text rows: AppKit menus rasterize custom SwiftUI icon views
            // at their natural image size, not the badge frame.
            ForEach(addable) { preset in
                Button(preset.displayName) { onAdd(preset) }
            }
            if !addable.isEmpty { Divider() }
            Button(localized("Custom Agent…")) { onCustom() }
        } label: {
            HStack(spacing: 12) {
                // The rows' icon column, so the label starts where agent names do.
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: settingsRowIconWidth, height: 26)
                Text(localized("Add Agent"))
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}

/// One agent on the roster: brand mark, name, and a second line — no controls, the
/// way a Notifications row carries no switch. The second line is the command the
/// agent actually launches with, bypass flag and all, so the roster answers "what
/// will this run?" without opening every row; anything blocking that launch (the
/// agent switched off, its CLI missing) leads the same line.
private struct AgentListRow: View {
    @ObservedObject var settings: AppSettings
    let preset: AgentPreset
    /// The machine the readiness word describes — the current workspace's device,
    /// not this Mac, which is the whole point of the line.
    let device: KnownDevice

    /// `nil` while the probe is still running: show nothing rather than a
    /// premature warning.
    @State private var readiness: AgentReadiness?

    /// Nothing to say about an enabled agent whose CLI is present — the common
    /// case, where the line is the command alone.
    ///
    /// The `unknown` word is the one this row could not say before. A machine
    /// reached over a network fails to answer for reasons that are nothing to do
    /// with the agent, and a `(!)` reading "not installed" would send the user to
    /// reinstall a CLI that is already there.
    private var status: String? {
        if !settings.isAgentEnabled(preset) { return localized("Off") }
        switch readiness {
        case .missing: return localized("Not installed")
        case .unknown: return localized("Can’t check on \(device.name)")
        case .available, nil: return nil
        }
    }

    private var detail: String {
        let command = settings.command(for: preset, on: device) ?? localized("Login shell")
        guard let status else { return command }
        return localized("\(status) · \(command)")
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
            // Only `missing` earns the badge. `unknown` says so in words instead:
            // a warning glyph for "we could not ask" is the false alarm.
            if readiness == .missing {
                Image(systemName: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help(localized("\(preset.displayName) isn’t installed on \(device.name)"))
            }
        }
        // Re-probed when the machine changes, so a workspace switch re-targets
        // this line and nothing else on the tab redraws.
        .task(id: "\(device.settingsKey)#\(settings.command(for: preset, on: device) ?? "")") {
            readiness = await AgentReadiness.passive(
                agent: preset,
                command: settings.command(for: preset, on: device) ?? "",
                on: device)
        }
    }
}

/// The pushed pane for one agent: an identity header above a grouped form — the
/// enable switch, command override, install link when the CLI is missing, the
/// permission-bypass switch, and removal.
private struct AgentDetailPane: View {
    @ObservedObject var settings: AppSettings
    let preset: AgentPreset
    /// The device this pane configures, from the scope control on the roster.
    /// Where an agent's CLI lives is a fact about a machine, but *which* machine
    /// is now a control on this page rather than a different tab to go to.
    let device: KnownDevice
    let onRemove: () -> Void
    /// True for agents backed by a manifest in the user's config folder — the only
    /// ones whose file can be opened or deleted from here.
    var isUserDefined = false
    /// Set only for user-manifest agents: deletes the manifest file.
    var onDelete: (() -> Void)?

    /// Same probe semantics as the list row (see `AgentListRow.available`).
    @State private var available: Bool?
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
                        Text(settings.command(for: preset, on: device) ?? localized("Login shell"))
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
                Toggle(isOn: Binding(
                    get: { settings.isAgentEnabled(preset) },
                    set: { settings.setAgent(preset, enabled: $0) }
                )) {
                    SettingsLabel(
                        title: localized("Enable \(preset.displayName)"),
                        subtext: localized("Offers \(preset.displayName) in the new-session menus.")
                    )
                }
                .toggleStyle(.switch)
                // A missing CLI can't be launched, so it can't be switched on — only
                // off (an already-on agent stays revocable while the hint shows).
                .disabled(available == false && !settings.isAgentEnabled(preset))
            }

            Section {
                // Where an agent's CLI lives is still a fact about a machine —
                // it is the *machine* that is now named by a control on this page
                // instead of being a different tab you had to go to.
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
                    SettingsLabel(
                        title: localized("Path"),
                        subtext: localized("Where \(preset.displayName) launches from on \(device.name). Leave empty to use its default."),
                        titleFont: .headline
                    )
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
        // Re-checks whenever the effective command changes, so typing a valid path
        // clears the install link. The PATH probe runs once (cached); each check is
        // an in-memory lookup. The leading sleep debounces per-keystroke edits into
        // one probe once the user pauses.
        .task(id: effectiveCommand) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            available = await AgentAvailability.isCommandAvailable(effectiveCommand)
        }
    }

    private var effectiveCommand: String { settings.command(for: preset, on: device) ?? "" }
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
