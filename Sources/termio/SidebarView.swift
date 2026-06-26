import SwiftUI

/// Left column: projects, each a section containing its sessions. A `+` in the
/// section header adds a session to that project.
struct SidebarView: View {
    @EnvironmentObject var store: TermioStore

    var body: some View {
        List(selection: $store.selectedSessionID) {
            ForEach(store.projects) { project in
                Section {
                    ForEach(project.sessions) { session in
                        SessionRow(session: session)
                            .tag(session.id)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.secondary)
                        Text(project.name)
                            .font(.headline)
                        Spacer()
                        Button {
                            store.addSession(to: project.id)
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                        .help("New session in \(project.name)")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
    }
}

private struct SessionRow: View {
    let session: Session

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.green)
                .frame(width: 7, height: 7)
            Text(session.title)
                .lineLimit(1)
        }
    }
}
