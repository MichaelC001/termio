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

/// The rows every device switcher shows, wherever it is mounted. The sidebar's
/// toolbar control is the only opening today; the rows live here rather than in it
/// because there is one current device, and it would be a bug for two controls to
/// disagree about which one it is.
struct DeviceSwitcherMenuContent: View {
    @EnvironmentObject var store: TermioStore

    var body: some View {
        let known = DeviceRoster.known(in: store)
        let unused = DeviceRoster.unusedAliases(known: known)
        // An inline Picker is what draws the checkmark on the current device; a
        // row of Buttons would leave the switcher unable to say which machine is
        // selected.
        Picker("", selection: selection) {
            ForEach(known) { device in
                Text(device.name).tag(device.id)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
        Divider()
        Button(localized("Refresh")) { store.refreshDeviceSessions() }
        if !unused.isEmpty {
            Divider()
            Menu(localized("Connect to…")) {
                ForEach(unused, id: \.self) { alias in
                    Button(alias) { connect(to: alias) }
                }
            }
        }
    }

    private var selection: Binding<String> {
        Binding(
            get: { store.currentDeviceAlias ?? "" },
            set: { alias in
                store.switchToDevice(
                    KnownDevice(alias: alias.isEmpty ? nil : alias, deviceID: nil))
            }
        )
    }

    /// First contact with a machine from `~/.ssh/config`: enter it, then open a
    /// terminal on it — which is what installs `termiod` there if it is missing.
    /// Reaching for a box is also saying that is where you are about to work.
    private func connect(to alias: String) {
        store.switchToDevice(KnownDevice(alias: alias, deviceID: nil))
        store.addRemoteTerminal(host: alias)
    }
}

// MARK: - Devices as spaces

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

/// One source of truth for moving between devices, so the header menu, the
/// footer dots, and the trackpad swipe can never disagree about the order or
/// about which machine is current.
@MainActor
enum DeviceSpaces {
    /// The devices a user can move between, in the order every surface shows
    /// them: this Mac first, then the machines it has worked on.
    static func ordered(in store: TermioStore) -> [KnownDevice] {
        DeviceRoster.known(in: store)
    }

    /// The device `step` places away from the current one, or `nil` at either
    /// end. Deliberately not wrapping: a swipe that runs off the end should feel
    /// like a wall, not teleport to the far side of the list.
    static func neighbor(step: Int, in store: TermioStore) -> KnownDevice? {
        let devices = ordered(in: store)
        guard let current = devices.firstIndex(where: { $0.alias == store.currentDeviceAlias })
        else { return nil }
        let target = current + step
        guard devices.indices.contains(target) else { return nil }
        return devices[target]
    }

    static func select(_ device: KnownDevice, in store: TermioStore) {
        store.switchToDevice(device)
    }
}

/// The footer strip: one mark per device, the current one drawn as a capsule
/// that slides between them. Arc's space dots, which is the interaction this
/// borrows — a switcher small enough to live permanently at the bottom of the
/// column, so moving between machines costs a click rather than a menu.
///
/// Absent entirely with one device, matching the header control: a single dot is
/// a decoration for a decision the user never took.
struct DeviceSpaceDots: View {
    @EnvironmentObject var store: TermioStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let chrome: ChromeTheme?
    /// Slides the current-device capsule between the dots — the same
    /// matched-geometry pill the inspector's pane switch uses, so the two
    /// switchers in this window move alike.
    @Namespace private var markNamespace

    var body: some View {
        let devices = DeviceSpaces.ordered(in: store)
        if devices.count > 1 {
            HStack(spacing: 10) {
                ForEach(devices) { device in
                    Circle()
                        .fill(Color.secondary.opacity(0.28))
                        .frame(width: 5, height: 5)
                        .matchedGeometryEffect(id: device.id, in: markNamespace)
                        // A dot is a 5pt target; the row is 22pt tall, so take the
                        // whole height as the hit area rather than asking for a
                        // pixel-accurate click.
                        .frame(width: 18, height: 22)
                        .contentShape(Rectangle())
                        .onTapGesture { DeviceSpaces.select(device, in: store) }
                        .help(device.name)
                }
            }
            .background(alignment: .leading) { currentMark(devices: devices) }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .animation(reduceMotion ? nil : .snappy(duration: 0.24, extraBounce: 0.12),
                       value: store.currentDeviceAlias)
        }
    }

    /// The tinted capsule riding the current device's dot. Non-source, so it
    /// takes that dot's frame and animates across when the device changes.
    @ViewBuilder
    private func currentMark(devices: [KnownDevice]) -> some View {
        let current = DeviceRoster.current(store, known: devices)
        Capsule(style: .continuous)
            .fill(DeviceTint.color(for: current, chrome: chrome))
            .frame(width: 14, height: 5)
            .matchedGeometryEffect(id: current.id, in: markNamespace, isSource: false)
    }
}

/// Turns a horizontal two-finger swipe anywhere over the sidebar into a device
/// change — the other half of Arc's spaces gesture, and the reason the dots can
/// stay as small as they are.
///
/// Mounted as a background so it never takes part in hit testing: the sidebar's
/// rows keep every click and drag they already had. The gesture is read from a
/// local scroll monitor instead, filtered to events over this view's own bounds.
///
/// Three guards keep it from eating the list's vertical scrolling, which is the
/// only way this could do damage:
///
/// 1. trackpad only (`hasPreciseScrollingDeltas`) — a mouse wheel never switches
///    machines;
/// 2. the horizontal travel must dominate the vertical by a wide margin;
/// 3. an event is swallowed only once the gesture has already committed, so a
///    scroll that merely drifts sideways still scrolls the list.
struct DeviceSpaceSwipe: NSViewRepresentable {
    /// `-1` for the device above the current one in the list, `+1` for below.
    let onSwipe: (Int) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.observe(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onSwipe = onSwipe
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSwipe: onSwipe) }

    @MainActor
    final class Coordinator {
        /// How far the fingers must travel sideways to change machine. Roughly a
        /// third of a comfortable swipe: far enough that a diagonal scroll never
        /// reaches it, short enough that the gesture doesn't feel like dragging.
        private static let commitDistance: CGFloat = 55
        /// How much the horizontal travel must beat the vertical by. The sidebar
        /// is a tall scrolling list, so this is the guard that matters.
        private static let dominance: CGFloat = 2.5

        var onSwipe: (Int) -> Void
        private weak var view: NSView?
        private var monitor: Any?
        private var travel = CGSize.zero
        private var committed = false

        init(onSwipe: @escaping (Int) -> Void) {
            self.onSwipe = onSwipe
        }

        func observe(_ view: NSView) {
            self.view = view
            // The verdict crosses the isolation boundary, not the event: `NSEvent`
            // is not `Sendable`, so it stays on this side and only a `Bool` comes
            // back out.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                let swallow = MainActor.assumeIsolated { self.swallows(event) }
                return swallow ? nil : event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// Whether this event belongs to a device swipe and must not also reach
        /// the list underneath.
        private func swallows(_ event: NSEvent) -> Bool {
            guard event.hasPreciseScrollingDeltas, let view, let window = view.window,
                  event.window === window
            else { return false }
            let point = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(point) else { return false }

            switch event.phase {
            case .began, .mayBegin:
                travel = .zero
                committed = false
            case .ended, .cancelled:
                // The tail of a committed gesture is swallowed too: letting it
                // through is what would fling the list sideways-then-down after
                // the machine had already changed.
                let wasCommitted = committed
                travel = .zero
                committed = false
                return wasCommitted
            default:
                break
            }

            guard !committed else { return true }
            travel.width += event.scrollingDeltaX
            travel.height += event.scrollingDeltaY
            guard abs(travel.width) > Self.commitDistance,
                  abs(travel.width) > abs(travel.height) * Self.dominance
            else { return false }

            committed = true
            // Fingers left means "bring the next machine in from the right", the
            // direction macOS uses for page-back/forward everywhere else.
            onSwipe(travel.width < 0 ? 1 : -1)
            return true
        }
    }
}

/// The device switcher, in the sidebar's own toolbar region: which machine you
/// are on, and the control that changes it. It sits in the strip above the list
/// rather than in a row of its own, next to the navigator toggle and the sidebar's
/// other actions — the band belongs to the column below it, and a first row that
/// is not a session is a row the tree has to explain.
///
/// Quiet by design — it names the device and nothing else — and absent entirely
/// while this Mac is the only one, so a user who never leaves their laptop never
/// sees it.
struct DeviceSwitcherToolbarView: View {
    @EnvironmentObject var store: TermioStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.controlActiveState) private var controlActive

    /// Long aliases truncate rather than push the sort and `+` buttons toward
    /// NSToolbar's `»` overflow: the sidebar region has only the room the
    /// navigator's minimum thickness gives it.
    private static let nameWidthCeiling: CGFloat = 130

    var body: some View {
        let known = DeviceRoster.known(in: store)
        // The single-device collapse. Not "hidden but present": with one machine
        // there is no switch to make, and a control that always reads "This Mac"
        // is a label for a decision the user never took.
        if known.count > 1 {
            let current = DeviceRoster.current(store, known: known)
            Menu {
                DeviceSwitcherMenuContent()
            } label: {
                HStack(spacing: 5) {
                    // Sized against the toolbar's own glyphs (the navigator toggle, the
                    // sort pull-down) rather than shrunk to fit beside them, and set in
                    // the sidebar's interface font — this control belongs to that column.
                    HugeIconView(icon: .serverStack, size: 15, color: color)
                    Text(current.name)
                        .font(settings.interfaceFont)
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HugeIconView(icon: .chevronRight, size: 8, color: color,
                                 lineWidthOverride: 1.75)
                        .rotationEffect(.degrees(90))
                }
                .frame(maxWidth: Self.nameWidthCeiling)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(localized("The sidebar shows this device’s sessions"))
        }
    }

    // Matched to the sidebar toolbar's native glyphs (the `+` new-terminal item, the
    // sort pull-down): those are bordered `NSToolbarItem`s, which tint their template
    // symbol at full-strength `labelColor`, so the device name sits at `.primary` to
    // read as one control band with them rather than a dimmer `.secondary` label.
    private var color: Color {
        controlActive == .inactive ? Color(nsColor: .disabledControlTextColor) : .primary
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
