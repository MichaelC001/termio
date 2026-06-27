import SwiftUI

/// Two-column layout: projects/sessions sidebar on the left, the selected
/// session's terminal on the right.
struct RootView: View {
    @EnvironmentObject var store: TermioStore
    // Bound to local state purely to keep the split view's titlebar/toolbar wiring
    // stable across sidebar collapse cycles; the native sidebar toggle drives it.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 170, ideal: 300, max: 400)
        } detail: {
            // One persistent pane that keeps every opened session mounted, so
            // switching sessions never tears down or resizes a live surface.
            TerminalPane()
        }
    }
}
