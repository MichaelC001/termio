import AppKit
import SwiftUI
import TermioShared

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
                menuRows
            } label: {
                HStack(spacing: 5) {
                    // Sized against the toolbar's own glyphs (the navigator toggle, the
                    // sort pull-down) rather than shrunk to fit beside them, and set in
                    // the sidebar's interface font — this control belongs to that column.
                    // A workspace on another machine says so with the same server
                    // mark its rows carry; one on this Mac is a place you put
                    // things, so it takes the folder mark.
                    HugeIconView(icon: current.device.isThisMac ? .folderOpen : .serverStack,
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

    @ViewBuilder
    private var menuRows: some View {
        // An inline Picker is what draws the checkmark on the current workspace; a
        // row of Buttons would leave the switcher unable to say which one is showing.
        Picker("", selection: selection) {
            ForEach(store.orderedWorkspaces) { workspace in
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
        // Removing the last workspace is refused in the store — the sidebar has to
        // have a scope to show — and this menu only opens while there is more than
        // one, so the row is always live where it is drawn.
        Button(localized("Remove Workspace")) {
            store.confirmRemoveWorkspace(store.currentWorkspaceID)
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

    // Matched to the sidebar toolbar's native glyphs (the `+` new-terminal item, the
    // sort pull-down): those are bordered `NSToolbarItem`s, which tint their template
    // symbol at full-strength `labelColor`, so the name sits at `.primary` to read as
    // one control band with them rather than a dimmer `.secondary` label.
    private var color: Color {
        controlActive == .inactive ? Color(nsColor: .disabledControlTextColor) : .primary
    }
}
