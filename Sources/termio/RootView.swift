import SwiftUI

/// Two-column layout: projects/sessions sidebar on the left, the selected
/// session's terminal on the right.
struct RootView: View {
    @EnvironmentObject var store: TermioStore

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            if let id = store.selectedSessionID,
               let session = store.session(id),
               let project = store.project(for: id) {
                TerminalPane(project: project, session: session)
                    // Rebind per session; the cached surface keeps the shell alive.
                    .id(session.id)
            } else {
                ContentUnavailableView("No session selected", systemImage: "terminal")
            }
        }
        .navigationTitle("termio")
    }
}
