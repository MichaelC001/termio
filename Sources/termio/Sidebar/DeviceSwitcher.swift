import AppKit
import SwiftUI
import TermioShared

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
        // This Mac always leads — not because it is special, but because it is the
        // one machine that is always there.
        return [.thisMac]
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

    /// The device the app is on, resolved against the machines that actually
    /// exist. A stored alias that no longer matches anything (the user deleted the
    /// `Host` block, or closed the last session on it) falls back to this Mac
    /// rather than silently aiming at nothing.
    static func current(_ store: TermioStore, known: [KnownDevice]) -> KnownDevice {
        known.first { $0.alias == store.currentDeviceAlias } ?? .thisMac
    }
}

// A device has no "open" verb of its own. Reaching a machine is always the side
// effect of putting something on it — New Terminal on that device, Clone to it,
// or File ▸ Connect to… for a box in `~/.ssh/config` Termio has never worked on
// — and each of those already lands the user in the right scope. A menu that
// merely *travels* to a machine is the switcher the workspace replaced.

// MARK: - The device mark

extension KnownDevice {
    /// The machine a session runs on, or `nil` when it runs on this Mac.
    ///
    /// The identity has to be the **machine**, never the road to it. A plain `ssh`
    /// terminal never handshakes with a daemon, so it carries no `deviceID` of its
    /// own; asked for a mark on the session alone it would hash to a different
    /// colour than the durable termiod session sitting beside it on the same box.
    /// The registry already knows where an alias leads, and remembers across
    /// launches, so the alias is resolved before the identity is formed.
    ///
    /// `resolve` is the lookup, injectable so the invariant can be tested without
    /// standing up the shared registry.
    static func running(
        _ session: Session,
        resolvingAlias resolve: (String) -> String? = {
            TermiodDeviceRegistry.shared.deviceID(for: TermiodRoute(sshAlias: $0))
        }
    ) -> KnownDevice? {
        guard let alias = session.termiodRemoteHost ?? session.sshHost else { return nil }
        return KnownDevice(alias: alias, deviceID: session.deviceID ?? resolve(alias))
    }
}

/// The mark a device carries wherever it is drawn small enough that its name
/// won't fit — today the footer dots.
///
/// A color is not decoration here. The whole class of accident this app has to
/// prevent is "I thought I was local, I was on the VPS": the panes now refuse to
/// show the wrong machine's files, and the mark is the cue that arrives *before*
/// the mistake, without the user reading a label.
///
/// The hue comes from the terminal theme (`ChromeTheme.deviceTints`), never from
/// a palette of our own, and the index is derived from the device's identity so
/// a machine keeps the same mark across launches, themes, and windows.
enum DeviceTint {
    static func color(for device: KnownDevice, chrome: ChromeTheme?) -> Color {
        // This Mac is deliberately unhued. It is the machine you are on when you
        // are not thinking about machines, so it reads as the absence of a mark
        // and every tinted dot means "somewhere else".
        guard !device.isLocal else { return .secondary }
        guard let tints = chrome?.deviceTints, !tints.isEmpty else {
            return Self.systemTints[index(for: device, count: Self.systemTints.count)]
        }
        return tints[index(for: device, count: tints.count)]
    }

    /// Used only when no terminal theme is selected, so the chrome is on the
    /// system appearance and has no palette to borrow from.
    private static let systemTints: [Color] = [.green, .yellow, .blue, .purple, .teal]

    private static func index(for device: KnownDevice, count: Int) -> Int {
        // The `host_id` once a handshake has revealed one, the alias until then —
        // the same bootstrap/stable split `KnownDevice` carries. A device whose id
        // arrives later therefore *can* change mark once, which is the honest
        // outcome: before the handshake we did not know which machine it was.
        let identity = device.deviceID ?? device.alias ?? ""
        // FNV-1a rather than `hashValue`: Swift seeds its hasher per process, so a
        // hashed index would repaint every device on every launch.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in identity.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100_0000_01b3
        }
        return Int(hash % UInt64(max(count, 1)))
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

/// "Move to Workspace ▸": files a project under a different scope. `nil` with one
/// workspace — there is nowhere to move to, and a submenu naming only the
/// workspace the project is already in is a dead click.
@MainActor
func moveToWorkspaceMenuItem(store: TermioStore, project: Project) -> SidebarMenuItem? {
    let targets = WorkspaceSpaces.ordered(in: store).filter { $0.id != project.workspaceID }
    guard !targets.isEmpty else { return nil }
    return .submenu(localized("Move to Workspace"), targets.map { workspace in
        .action(workspace.name) { store.moveProject(project.id, toWorkspace: workspace.id) }
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
