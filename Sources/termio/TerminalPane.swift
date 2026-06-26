import SwiftUI
import GhosttyTerminal

/// Right column for the selected session: a top bar (`project ⌥ branch` + live
/// terminal title) above the live libghostty terminal surface.
struct TerminalPane: View {
    @EnvironmentObject var store: TermioStore
    let project: Project
    let session: Session

    var body: some View {
        // Resolve the cached surface here and hand it to the content view as an
        // @ObservedObject so title/bell updates re-render the top bar.
        TerminalPaneContent(
            project: project,
            session: session,
            surface: store.surface(for: session, in: project)
        )
    }
}

private struct TerminalPaneContent: View {
    let project: Project
    let session: Session
    @ObservedObject var surface: TerminalViewState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(project.name)
                    .fontWeight(.semibold)
                Image(systemName: "arrow.triangle.branch")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                Text(project.branch)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(title)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            TerminalSurfaceView(context: surface)
        }
    }

    private var title: String {
        surface.title.isEmpty ? session.title : surface.title
    }
}
