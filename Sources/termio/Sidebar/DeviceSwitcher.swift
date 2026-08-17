import AppKit
import SwiftUI
import TermioShared

/// A machine Termio can put a session on, as the interface names it. This Mac is
/// one, and so is every box the user has already worked on — the word "remote"
/// describes the road, not the thing at the end of it, so it appears nowhere.
///
/// The identity carried here is the `~/.ssh/config` alias, not the device's
/// `host_id`, because a menu is built synchronously and the id only exists after
/// a handshake. That is the same bootstrap/stable split `Project.sshHost` and
/// `Project.deviceID` already record (device architecture §9.5): the alias is
/// what a row is born from, `deviceID` is what it turns out to be. Two aliases
/// that resolve to one machine therefore still show as two rows — merging them
/// is §9.5's job and is deliberately not done here.
struct KnownDevice: Identifiable, Hashable {
    /// The alias this device is reached by, or `nil` for this Mac.
    let alias: String?
    /// The `host_id` a handshake revealed, `nil` until one has run.
    let deviceID: String?

    var isLocal: Bool { alias == nil }
    /// The switcher and every menu row name a device this way. This Mac has no
    /// alias to show, and the host never supplies a display name (device
    /// architecture §4), so the client picks one.
    var name: String { alias ?? localized("This Mac") }
    var id: String { alias ?? "" }
}

/// Which machines the interface knows about, and which ones it could reach but
/// hasn't. The split follows the ownership rule: the *known* list is state Termio
/// produced itself (a completed handshake, a session it opened), while the
/// reachable-but-unused list is read straight out of `~/.ssh/config`, which stays
/// the only host database Termio has and is never written to.
@MainActor
enum DeviceRoster {
    /// This Mac, then every machine Termio has actually worked on, by alias.
    ///
    /// A machine qualifies two ways: a `hello_ok` recorded it in the device
    /// registry, or a session in the tree says it runs there. The second source
    /// matters on the launch after an upgrade — a state file can name a host the
    /// registry has not re-learned yet, and a device the user can see sessions on
    /// must not be missing from the switcher.
    static func known(in store: TermioStore) -> [KnownDevice] {
        var deviceIDByAlias: [String: String] = [:]
        for device in TermiodDeviceRegistry.shared.all {
            for alias in device.routes.compactMap(\.sshAlias) {
                deviceIDByAlias[alias] = device.id
            }
        }
        var aliases = Set(deviceIDByAlias.keys)
        for project in store.projects {
            for session in project.sessions {
                if let host = session.termiodRemoteHost { aliases.insert(host) }
            }
        }
        // This Mac always leads: it is the device the user is looking at.
        return [KnownDevice(alias: nil, deviceID: nil)]
            + aliases.sorted().map { KnownDevice(alias: $0, deviceID: deviceIDByAlias[$0]) }
    }

    /// The `~/.ssh/config` aliases no known device answers to — what "Connect to…"
    /// offers. Order follows the config file; duplicates (one alias named in two
    /// blocks) collapse to the first.
    static func unusedAliases(known: [KnownDevice]) -> [String] {
        var seen = Set(known.compactMap(\.alias))
        var result: [String] = []
        for alias in SSHConfigFile.hosts().map(\.alias) where !seen.contains(alias) {
            seen.insert(alias)
            result.append(alias)
        }
        return result
    }

    /// Every machine a repo could be cloned to: the known ones first, then the
    /// aliases that have never been used. Cloning is itself a first contact —
    /// `ensureRemoteReady` installs `termiod` on the way — so an unused alias is a
    /// legitimate target here even though it is not yet a device.
    static func cloneTargets(in store: TermioStore) -> [KnownDevice] {
        let known = known(in: store)
        return known.filter { !$0.isLocal }
            + unusedAliases(known: known).map { KnownDevice(alias: $0, deviceID: nil) }
    }

    /// The device new work lands on, resolved against the machines that actually
    /// exist. A stored alias that no longer matches anything (the user deleted the
    /// `Host` block, or closed the last session on it) falls back to this Mac
    /// rather than silently aiming at nothing.
    static func current(_ settings: AppSettings, known: [KnownDevice]) -> KnownDevice {
        known.first { $0.alias == settings.currentDeviceAlias } ?? known[0]
    }
}

/// The sidebar's device indicator: which machine new work lands on, and the
/// switcher that changes it. Quiet by design — it names the device and nothing
/// else — and absent entirely while this Mac is the only one, so a user who never
/// leaves their laptop never sees it.
struct DeviceIndicator: View {
    @EnvironmentObject var store: TermioStore
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        let known = DeviceRoster.known(in: store)
        // The single-device collapse. Not "hidden but present": with one machine
        // there is no switch to make, and a row that always reads "This Mac" is a
        // label for a decision the user never took.
        if known.count > 1 {
            let current = DeviceRoster.current(settings, known: known)
            let unused = DeviceRoster.unusedAliases(known: known)
            Divider()
            Menu {
                // An inline Picker is what draws the checkmark on the current
                // device; a row of Buttons would leave the switcher unable to say
                // which machine is selected.
                Picker("", selection: selection) {
                    ForEach(known) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                if !unused.isEmpty {
                    Divider()
                    Menu(localized("Connect to…")) {
                        ForEach(unused, id: \.self) { alias in
                            Button(alias) { connect(to: alias) }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    HugeIconView(icon: .serverStack, size: 13, color: .secondary)
                    Text(current.name)
                        .font(settings.interfaceFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    HugeIconView(icon: .chevronRight, size: 7.5, color: .secondary,
                                 lineWidthOverride: 1.75)
                        .rotationEffect(.degrees(90))
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .help(localized("New terminals open on this device"))
        }
    }

    private var selection: Binding<String> {
        Binding(
            get: { settings.currentDeviceAlias ?? "" },
            set: { settings.currentDeviceAlias = $0.isEmpty ? nil : $0 }
        )
    }

    /// First contact with a machine from `~/.ssh/config`: open a terminal on it
    /// (which installs `termiod` there if it is missing) and make it the current
    /// device, so the connection the user just asked for is also where their next
    /// terminal goes.
    private func connect(to alias: String) {
        settings.currentDeviceAlias = alias
        store.addRemoteTerminal(host: alias)
    }
}

// MARK: - Menu construction

/// The "New Terminal" verb, device-aware: a plain action while this Mac is the
/// only machine, a device submenu once there is more than one. `local` is what
/// the row for this Mac does, which differs per call site (a project's directory,
/// the Terminals section, `$HOME`).
///
/// `project` scopes the remote rows the way the row it hangs off is scoped: from a
/// project it means "this repo, over there" and opens in the checkout that project
/// recorded for the device, so a machine the repo isn't on yet says so instead of
/// dropping a `$HOME` shell somewhere unexpected.
@MainActor
func newTerminalMenuItem(
    store: TermioStore,
    project: Project? = nil,
    local: @escaping () -> Void
) -> SidebarMenuItem {
    let known = DeviceRoster.known(in: store)
    guard known.count > 1 else { return .action(localized("New Terminal"), local) }
    let projectID = project?.id
    return .submenu(localized("New Terminal"), known.map { device in
        guard let alias = device.alias else { return .action(device.name, local) }
        // A project row says which machines already hold this repo, so the menu
        // answers "where does this exist?" before you click. The checkout is keyed
        // by device, so ask the registry for the identity learned earlier and let
        // the lookup fall back to the alias when this box has never been reached.
        let cloned = project?.remoteCheckout(device: device.deviceID, alias: alias) != nil
        let label = project == nil || cloned ? device.name : "\(device.name) — not cloned yet"
        return .action(label) { store.addRemoteTerminal(host: alias, project: projectID) }
    })
}

/// "Clone to <device>…": the project's `origin` is `git clone`d **on** that
/// machine, then a terminal opens inside the clone. `nil` when there is nowhere to
/// clone to — an empty `~/.ssh/config` and no device ever reached — because a
/// disabled row explaining an empty config is the dead end this replaces.
///
/// Only meaningful for a git checkout with a remote. Origin presence is resolved
/// at click time (async): the menu is built synchronously and a git call per
/// right-click would stall the sidebar, so a folder with no origin alerts rather
/// than silently doing nothing.
@MainActor
func cloneToDeviceMenuItem(
    store: TermioStore,
    folder: String,
    project projectID: UUID? = nil
) -> SidebarMenuItem? {
    let targets = DeviceRoster.cloneTargets(in: store)
    guard !targets.isEmpty else { return nil }
    let clone = { (device: KnownDevice) in
        { @MainActor in
            guard let alias = device.alias else { return }
            Task { @MainActor in
                guard let info = await GitService.cloneInfo(in: folder) else {
                    store.presentRemoteSetupFailure(
                        host: alias,
                        message: localized("This folder has no git “origin” remote to clone."))
                    return
                }
                store.cloneOnRemote(host: alias, info: info, project: projectID)
            }
        }
    }
    // One machine needs no submenu — the verb names it outright, which is also the
    // only form that reads as a sentence.
    if targets.count == 1, let only = targets.first {
        return .action(localized("Clone to \(only.name)…"), clone(only))
    }
    return .submenu(localized("Clone to"), targets.map { .action($0.name, clone($0)) })
}
