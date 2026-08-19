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

    /// Every switcher goes through here, which is also what makes the switch
    /// measurable in one place: the span covers the whole synchronous cost of
    /// changing scope — the selection move, the device context, the sidebar
    /// rebuild each one publishes — so a switch that feels slow has a number
    /// next to it rather than an adjective.
    static func select(_ workspace: Workspace, in store: TermioStore) {
        Trace.workspace.measure("workspace switch", "to=\(workspace.name)") {
            store.switchToWorkspace(workspace.id)
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
            set: { id in
                guard let workspace = store.workspaces.first(where: { $0.id == id }) else { return }
                WorkspaceSpaces.select(workspace, in: store)
            }
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
