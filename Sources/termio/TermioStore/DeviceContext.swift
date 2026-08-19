import Foundation

/// A machine Termio can work on, as the interface names it. This Mac is one, and
/// so is every box the user has already reached — the word "remote" describes the
/// road, not the thing at the end of it, so it appears nowhere.
///
/// The identity carried here is the `~/.ssh/config` alias, not the device's
/// `host_id`, because a menu is built synchronously and the id only exists after
/// a handshake. That is the same bootstrap/stable split `Project.sshHost` and
/// `Project.deviceID` already record (device architecture §9.5): the alias is
/// what a row is born from, `deviceID` is what it turns out to be. Two aliases
/// that resolve to one machine therefore still show as two rows — merging them
/// is §9.5's job and is deliberately not done here.
///
/// Lives at the store layer, not in the sidebar, because the device is not a
/// sidebar control: it is the context every panel reads (`TermioStore.currentDevice`).
struct KnownDevice: Identifiable, Hashable {
    /// The alias this device is reached by, or `nil` for this Mac.
    let alias: String?
    /// The `host_id` a handshake revealed, `nil` until one has run.
    let deviceID: String?

    /// This Mac — a device like any other, distinguished only by having no alias
    /// to reach it by. Nothing branches on this; it is the route that differs
    /// (a Unix socket instead of `ssh <alias>`), and `TermiodRoute` already
    /// carries that difference.
    static let thisMac = KnownDevice(alias: nil, deviceID: nil)

    var isLocal: Bool { alias == nil }
    /// The switcher and every menu row name a device this way. This Mac has no
    /// alias to show, and the host never supplies a display name (device
    /// architecture §4), so the client picks one.
    var name: String { alias ?? localized("This Mac") }
    var id: String { alias ?? "" }

    var route: TermiodRoute { TermiodRoute(sshAlias: alias) }
}

/// What one device says is running on it, as of the last `list`.
///
/// The device's reply is the authority for **which sessions exist**. Nothing in
/// this app may substitute a locally-filtered array for it: filtering the Mac's
/// own session list by alias would encode "all sessions are really this Mac's,
/// tagged with where they went", which is the model the device architecture
/// exists to replace (§2.1 — the Mac may hold nothing a viewer needs).
/// `Equatable` because a device answering the same thing twice must cost
/// nothing: the reply is published, and a publish rebuilds the sidebar whether
/// or not a single row differs.
struct DeviceSessions: Sendable, Equatable {
    /// Live sessions, in the order the device reported them.
    var live: [Termiod.SessionInformation]
    /// Sessions the device buried, newest first. The only answer to "where did my
    /// session go?" — a daemon that died takes every PTY with it, and without
    /// these the roster just comes back empty, which reads as "nothing ran".
    var tombstones: [Termiod.SessionTombstone]
}

/// Whether the current device has answered yet, and what it said. A device is
/// reached over a network, so "we do not know" is a real state and is shown as
/// one rather than being flattened into an empty list.
enum DeviceSessionsState {
    /// The daemon backend is off (`TERMIO_TERMIOD` unset), so no device — this
    /// Mac included — has a session host to ask.
    case unavailable
    case loading
    case ready(DeviceSessions)
    /// The device could not be reached, or refused. Carries what to tell the user.
    case failed(String)

    var sessions: DeviceSessions? {
        if case .ready(let sessions) = self { return sessions }
        return nil
    }
}

extension TermioStore {
    /// The device the app is currently looking at. Every panel takes its data
    /// from here: switching is not a filter over one list, it is a different
    /// machine's world.
    var currentDevice: KnownDevice {
        KnownDevice(
            alias: currentDeviceAlias,
            deviceID: TermiodDeviceRegistry.shared.deviceID(
                for: TermiodRoute(sshAlias: currentDeviceAlias))
        )
    }

    /// Enters a device: the app stops showing the machine it was on and starts
    /// showing this one.
    ///
    /// Three things move together, and they have to, or the window says one thing
    /// while the panes show another:
    ///
    /// 1. the context (`currentDeviceAlias`), which the sidebar and the window
    ///    chrome read;
    /// 2. the selection — a session on the machine you just left is not part of
    ///    this world, and leaving it on screen is precisely the "thought I was
    ///    local, was actually remote" accident;
    /// 3. the roster, re-asked of the device now in front of you.
    func switchToDevice(_ device: KnownDevice) {
        guard currentDeviceAlias != device.alias else {
            // Same device, but the user asked — treat it as "refresh this one".
            refreshDeviceSessions()
            return
        }
        currentDeviceAlias = device.alias
        // Persistence only. The live truth is the published property above; the
        // defaults entry exists so the next launch starts where this one ended.
        settings.currentDeviceAlias = device.alias
        refreshDeviceSessions()
    }

    /// Follows a session onto its machine. Called from the selection's `didSet`,
    /// so it must not move the selection back — it changes the context only.
    func enterDevice(of id: Session.ID) {
        guard let session = session(id) else { return }
        let alias = session.termiodRemoteHost ?? session.sshHost
        guard alias != currentDeviceAlias else { return }
        currentDeviceAlias = alias
        settings.currentDeviceAlias = alias
        refreshDeviceSessions()
    }

    /// What the current device says is running that this app has no row for —
    /// a session started from the `termiod` CLI on that machine, or by another
    /// client. Every session this app authored already draws in its own
    /// workspace, so anything with a record here would be a duplicate.
    ///
    /// The device's own ordering is kept: it is the authority for this list, so
    /// its order is the list's order. Its existence is also the proof the list is
    /// the device's and not this Mac's — no amount of filtering a local array can
    /// produce a row for a session this app never created.
    func deviceOnlySessions() -> [Termiod.SessionInformation] {
        let mine = sessions(authoredFor: currentDevice)
        return (deviceSessions.sessions?.live ?? []).filter { information in
            information.alive
                && !mine.contains { daemonSessionName(for: $0) == information.name }
        }
    }

    /// The sessions this viewer authored **for** a device: its own records, which
    /// decorate the device's roster but never stand in for it. Reading this in
    /// place of `deviceSessions` is the mistake this comment exists to prevent —
    /// it cannot see a session another client started, and it believes in
    /// sessions whose process died while the app was closed.
    func sessions(authoredFor device: KnownDevice) -> [Session] {
        allSessions.filter { isAuthored($0, for: device) }
    }

    /// Whether a session belongs to the device the app is on. Panels use this to
    /// scope their own containers; nothing may use it to build a session list.
    func isOnCurrentDevice(_ session: Session) -> Bool {
        isAuthored(session, for: currentDevice)
    }

    private func isAuthored(_ session: Session, for device: KnownDevice) -> Bool {
        // Which machine the session is *about*. A durable termiod session names
        // it directly; a plain `ssh` terminal runs its PTY here but exists to put
        // the user on that box, so it belongs to the same place. `nil` is this Mac.
        let alias = session.termiodRemoteHost ?? session.sshHost
        // Matched by device identity once both ends know it, so a box reached by
        // a second alias is still the same machine — and by alias until the first
        // handshake resolves one, the bootstrap/stable split `KnownDevice` carries.
        if alias != nil, let deviceID = device.deviceID, let sessionDevice = session.deviceID {
            return deviceID == sessionDevice
        }
        return alias == device.alias
    }

    /// The name this session carries inside a daemon. Sessions the app created are
    /// named with their own uuid, which is what makes reattach-after-relaunch
    /// work; an adopted session keeps the name it already had on the device.
    func daemonSessionName(for session: Session) -> String {
        session.termiodSessionName ?? session.id.uuidString
    }

    /// How a session's termiod counterpart died, if it did. `nil` for a session
    /// that is running, that never ran, or whose tombstone has aged out of the
    /// daemon's capped graveyard.
    ///
    /// The reason is the host's word (`exited` · `killed` · `daemon_lost`);
    /// turning it into something a person reads is the caller's job, because the
    /// host describes state and never decides presentation.
    func termiodEndReason(for session: Session) -> Termiod.SessionTombstone? {
        termiodTombstones[daemonSessionName(for: session)]
    }
}
