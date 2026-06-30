import SwiftUI

// MARK: - Tab switch

/// The inspector's pane switch: a native segmented `Picker` (which adopts the system
/// Liquid Glass material on macOS 26) flipping between Files and Changes. It sits at
/// the *left* edge of the inspector in the toolbar — pinned there by an inspector
/// tracking separator (see `MainToolbarDelegate`) — while the collapse button sits at
/// the far right. Picking a pane also opens the inspector if it is closed.
struct InspectorTabsToolbar: View {
    @EnvironmentObject var store: TermioStore

    var body: some View {
        Picker("", selection: Binding(
            get: { store.inspectorTab },
            set: { store.inspectorTab = $0 }
        )) {
            Image(systemName: "list.bullet.indent")
                .help("Project Files")
                .tag(InspectorTab.files)
            Image(systemName: "arrow.triangle.branch")
                .help("Changes")
                .tag(InspectorTab.changes)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        // Bound the hosting view to a fixed, standard toolbar height — an unconstrained segmented
        // Picker can report a tall intrinsic height that grows the unified toolbar (and, with
        // `.fullSizeContentView`, nudges the window frame) the moment the item is inserted.
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: 24)
    }
}
