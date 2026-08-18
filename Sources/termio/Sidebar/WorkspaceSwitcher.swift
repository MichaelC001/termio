import AppKit
import SwiftUI
import TermioShared

/// One source of truth for moving between workspaces, so the header menu, the
/// footer dots, and the trackpad swipe can never disagree about the order or
/// about which scope is current.
@MainActor
enum WorkspaceSpaces {
    /// The workspaces a user can move between, in the order every surface shows
    /// them: the ones they made first, then the machine fallbacks. A fallback is
    /// where sessions land that nobody filed, so it sits after the filing.
    static func ordered(in store: TermioStore) -> [Workspace] {
        store.workspaces.filter { !$0.isDeviceFallback } + store.workspaces.filter(\.isDeviceFallback)
    }

    /// The workspace `step` places away from the current one, or `nil` at either
    /// end. Deliberately not wrapping: a swipe that runs off the end should feel
    /// like a wall, not teleport to the far side of the list.
    static func neighbor(step: Int, in store: TermioStore) -> Workspace? {
        let spaces = ordered(in: store)
        guard let current = spaces.firstIndex(where: { $0.id == store.currentWorkspaceID })
        else { return nil }
        let target = current + step
        guard spaces.indices.contains(target) else { return nil }
        return spaces[target]
    }

    static func select(_ workspace: Workspace, in store: TermioStore) {
        store.switchToWorkspace(workspace.id)
    }

    /// The mark a workspace carries where its name won't fit. A machine's
    /// fallback borrows that machine's own tint, so the dot for "ukvps" is the
    /// same hue as the mark on every ukvps row; a workspace the user made takes
    /// the theme accent, since it is not about a machine at all.
    static func tint(_ workspace: Workspace, chrome: ChromeTheme?) -> Color {
        guard let alias = workspace.deviceAlias else { return chrome?.accent ?? .accentColor }
        return DeviceTint.color(
            for: KnownDevice(alias: alias, deviceID: workspace.deviceID), chrome: chrome)
    }
}

/// The footer strip: one mark per workspace, the current one drawn as a capsule
/// that slides between them. Arc's space dots, which is the interaction this
/// borrows — a switcher small enough to live permanently at the bottom of the
/// column, so moving between scopes costs a click rather than a menu.
///
/// Absent entirely with one workspace, matching the header control: a single dot
/// is a decoration for a decision the user never took.
struct WorkspaceDots: View {
    @EnvironmentObject var store: TermioStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let chrome: ChromeTheme?
    /// Slides the current-workspace capsule between the dots — the same
    /// matched-geometry pill the inspector's pane switch uses, so the two
    /// switchers in this window move alike.
    @Namespace private var markNamespace

    var body: some View {
        let spaces = WorkspaceSpaces.ordered(in: store)
        if spaces.count > 1 {
            HStack(spacing: 10) {
                ForEach(spaces) { workspace in
                    Circle()
                        .fill(Color.secondary.opacity(0.28))
                        .frame(width: 5, height: 5)
                        .matchedGeometryEffect(id: workspace.id, in: markNamespace)
                        // A dot is a 5pt target; the row is 22pt tall, so take the
                        // whole height as the hit area rather than asking for a
                        // pixel-accurate click.
                        .frame(width: 18, height: 22)
                        .contentShape(Rectangle())
                        .onTapGesture { WorkspaceSpaces.select(workspace, in: store) }
                        .help(workspace.name)
                }
            }
            .background(alignment: .leading) { currentMark(spaces: spaces) }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .animation(reduceMotion ? nil : .snappy(duration: 0.24, extraBounce: 0.12),
                       value: store.currentWorkspaceID)
        }
    }

    /// The tinted capsule riding the current workspace's dot. Non-source, so it
    /// takes that dot's frame and animates across when the scope changes.
    @ViewBuilder
    private func currentMark(spaces: [Workspace]) -> some View {
        let current = spaces.first { $0.id == store.currentWorkspaceID } ?? store.currentWorkspace
        Capsule(style: .continuous)
            .fill(WorkspaceSpaces.tint(current, chrome: chrome))
            .frame(width: 14, height: 5)
            .matchedGeometryEffect(id: current.id, in: markNamespace, isSource: false)
    }
}

/// Turns a horizontal two-finger swipe anywhere over the sidebar into a
/// workspace change — the other half of Arc's spaces gesture, and the reason the
/// dots can stay as small as they are.
///
/// Mounted as a background so it never takes part in hit testing: the sidebar's
/// rows keep every click and drag they already had. The gesture is read from a
/// local scroll monitor instead, filtered to events over this view's own bounds.
///
/// Three guards keep it from eating the list's vertical scrolling, which is the
/// only way this could do damage:
///
/// 1. trackpad only (`hasPreciseScrollingDeltas`) — a mouse wheel never switches
///    scopes;
/// 2. the horizontal travel must dominate the vertical by a wide margin;
/// 3. an event is swallowed only once the gesture has already committed, so a
///    scroll that merely drifts sideways still scrolls the list.
struct WorkspaceSwipe: NSViewRepresentable {
    /// `-1` for the workspace above the current one in the list, `+1` for below.
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
        /// How far the fingers must travel sideways to change scope. Far enough
        /// that a diagonal scroll never reaches it, short enough that the gesture
        /// reads as a flick rather than a drag.
        private static let commitDistance: CGFloat = 34
        /// A fast flick commits before it has travelled that far: past this
        /// per-event speed the intent is already unambiguous, and waiting for the
        /// remaining distance is what makes a switcher feel heavy.
        private static let flickSpeed: CGFloat = 12
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

        /// Whether this event belongs to a workspace swipe and must not also reach
        /// the list underneath.
        private func swallows(_ event: NSEvent) -> Bool {
            guard event.hasPreciseScrollingDeltas, let view, let window = view.window,
                  event.window === window
            else { return false }
            // Momentum is the tail the system throws after the fingers leave. It
            // used to keep feeding `travel`, so one flick could cross the commit
            // distance a second time and skip two scopes — the overshoot that
            // read as the gesture being unreliable.
            guard event.momentumPhase == [] else { return committed }
            let point = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(point) else { return false }

            switch event.phase {
            case .began, .mayBegin:
                travel = .zero
                committed = false
            case .ended, .cancelled:
                // The tail of a committed gesture is swallowed too: letting it
                // through is what would fling the list sideways-then-down after
                // the scope had already changed.
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
            // Horizontal dominance is judged on the whole gesture; the distance
            // is met either by travelling far or by moving fast.
            guard abs(travel.width) > abs(travel.height) * Self.dominance,
                  abs(travel.width) > Self.commitDistance
                      || abs(event.scrollingDeltaX) > Self.flickSpeed
            else { return false }

            committed = true
            // Fingers left means "bring the next scope in from the right", the
            // direction macOS uses for page-back/forward everywhere else.
            onSwipe(travel.width < 0 ? 1 : -1)
            return true
        }
    }
}

/// The rows every workspace switcher shows, wherever it is mounted. The sidebar's
/// toolbar control is the only opening today; the rows live here rather than in
/// it because there is one current workspace, and it would be a bug for two
/// controls to disagree about which one it is.
struct WorkspaceSwitcherMenuContent: View {
    @EnvironmentObject var store: TermioStore

    var body: some View {
        let spaces = WorkspaceSpaces.ordered(in: store)
        // An inline Picker is what draws the checkmark on the current workspace; a
        // row of Buttons would leave the switcher unable to say which one is showing.
        Picker("", selection: selection) {
            ForEach(spaces) { workspace in
                Text(workspace.name).tag(workspace.id)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
        Divider()
        Button(localized("New Workspace…")) { store.presentNewWorkspacePanel() }
        Button(localized("Rename Workspace…")) {
            store.presentRenameWorkspacePanel(store.currentWorkspaceID)
        }
        // The last workspace has nowhere to send its sessions, and the sidebar has
        // to have a scope to show, so the verb is absent rather than disabled.
        if store.hasMultipleWorkspaces {
            Button(localized("Remove Workspace")) {
                store.confirmRemoveWorkspace(store.currentWorkspaceID)
            }
        }
        // No device verb here, deliberately. A machine you can *go to* is the
        // mode this scope replaced: it made the sidebar answer "which computer"
        // when the question is "which work". A device is a place a new thing is
        // put — New Terminal on it, Clone to it, File ▸ Connect to… for a box
        // never reached — never a place the window travels to.
    }

    private var selection: Binding<Workspace.ID> {
        Binding(
            get: { store.currentWorkspaceID },
            set: { store.switchToWorkspace($0) }
        )
    }
}

/// The workspace switcher, in the sidebar's own toolbar region: which scope you
/// are in, and the control that changes it. It sits in the strip above the list
/// rather than in a row of its own, next to the navigator toggle and the
/// sidebar's other actions — the band belongs to the column below it, and a first
/// row that is not a session is a row the tree has to explain.
///
/// Quiet by design — it names the workspace and nothing else — and absent
/// entirely while there is only one, so a user who never makes a second never
/// sees it.
struct WorkspaceSwitcherToolbarView: View {
    @EnvironmentObject var store: TermioStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.controlActiveState) private var controlActive
    @Environment(\.colorScheme) private var colorScheme

    /// Long names truncate rather than push the sort and `+` buttons toward
    /// NSToolbar's `»` overflow: the sidebar region has only the room the
    /// navigator's minimum thickness gives it.
    private static let nameWidthCeiling: CGFloat = 130

    var body: some View {
        // The single-workspace collapse. Not "hidden but present": with one scope
        // there is no switch to make, and a control that always reads the same
        // word is a label for a decision the user never took.
        if store.hasMultipleWorkspaces {
            let current = store.currentWorkspace
            Menu {
                WorkspaceSwitcherMenuContent()
            } label: {
                HStack(spacing: 5) {
                    // Sized against the toolbar's own glyphs (the navigator toggle, the
                    // sort pull-down) rather than shrunk to fit beside them, and set in
                    // the sidebar's interface font — this control belongs to that column.
                    // A machine's fallback is a machine, and says so with the same
                    // server mark its rows carry; a workspace the user made is a
                    // place they put things, so it takes the folder mark.
                    HugeIconView(icon: current.isDeviceFallback ? .serverStack : .folderOpen,
                                 size: 15, color: color)
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
            .help(localized("The sidebar shows this workspace"))
        }
    }

    // Matched to the sidebar toolbar's native glyphs (the `+` new-terminal item, the
    // sort pull-down): those are bordered `NSToolbarItem`s, which tint their template
    // symbol at full-strength `labelColor`, so the name sits at `.primary` to read as
    // one control band with them rather than a dimmer `.secondary` label.
    private var color: Color {
        controlActive == .inactive ? Color(nsColor: .disabledControlTextColor) : .primary
    }
}
