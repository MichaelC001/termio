import TermioShared
import UIKit

struct MockSession: Identifiable {
    let id = UUID()
    let title: String
    let project: String
    let agent: AgentKind
    let status: SessionStatus
    let subtitle: String
    let time: String

    static let samples: [MockSession] = [
        .init(title: "fix-sidebar", project: "termio", agent: .claude,
              status: .needsAttention, subtitle: "「允许运行 npm install?」", time: "2m"),
        .init(title: "landing-hero", project: "termio", agent: .claude,
              status: .working, subtitle: "Editing hero.tsx…", time: "5m"),
        .init(title: "info-pane", project: "termio", agent: .codex,
              status: .done, subtitle: "Done · 3 files changed", time: "1h"),
        .init(title: "kanban-drag", project: "vibewizard", agent: .claude,
              status: .working, subtitle: "Running swift build…", time: "12m"),
        .init(title: "release-notes", project: "termio", agent: .opencode,
              status: .idle, subtitle: "Waiting for input", time: "3h"),
    ]
}

/// A project (an opened folder), the first-level page — mirroring the desktop
/// sidebar's project → session hierarchy as list → sub-list.
struct MockProject: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let sessions: [MockSession]

    /// Projects keep their order; within a project, attention floats up.
    static let samples: [MockProject] = {
        var order: [String] = []
        var byProject: [String: [MockSession]] = [:]
        for session in MockSession.samples {
            if byProject[session.project] == nil { order.append(session.project) }
            byProject[session.project, default: []].append(session)
        }
        return order.map { name in
            MockProject(
                name: name,
                path: "~/Documents/GitHub/\(name)",
                sessions: byProject[name]!.sorted { $0.status.rank < $1.status.rank }
            )
        }
    }()
}

// MARK: - Mock file tree

final class FileNode {
    let name: String
    let children: [FileNode]?
    let changed: Bool
    var isExpanded: Bool

    var isDirectory: Bool { children != nil }

    init(_ name: String, changed: Bool = false, expanded: Bool = false, children: [FileNode]? = nil) {
        self.name = name
        self.changed = changed
        self.children = children
        isExpanded = expanded
    }

    static let sampleRoot: [FileNode] = [
        FileNode("Sources", expanded: true, children: [
            FileNode("termio", expanded: true, children: [
                FileNode("App.swift", changed: true),
                FileNode("Models.swift"),
                FileNode("SessionInfoView.swift", changed: true),
                FileNode("TermioStore", children: [
                    FileNode("TermioStore.swift"),
                    FileNode("TermioStore+TerminalSurface.swift", changed: true),
                    FileNode("TermioStore+AgentStatus.swift"),
                ]),
            ]),
        ]),
        FileNode("web", children: [
            FileNode("landing", children: [
                FileNode("src", children: [
                    FileNode("app", children: [FileNode("page.tsx")]),
                ]),
            ]),
        ]),
        FileNode("Package.swift"),
        FileNode("README.md"),
    ]

    /// Flattens the tree into visible rows (respecting collapsed dirs).
    static func visibleRows(from roots: [FileNode], depth: Int = 0) -> [(node: FileNode, depth: Int)] {
        var rows: [(FileNode, Int)] = []
        for node in roots {
            rows.append((node, depth))
            if node.isDirectory, node.isExpanded, let children = node.children {
                rows.append(contentsOf: visibleRows(from: children, depth: depth + 1))
            }
        }
        return rows
    }
}

// MARK: - Mock changes

struct MockChange {
    let kind: String // "M" / "A" / "D"
    let path: String
    let additions: Int
    let deletions: Int

    static let samples: [MockChange] = [
        .init(kind: "M", path: "Sources/termio/App.swift", additions: 40, deletions: 12),
        .init(kind: "M", path: "Sources/termio/SessionInfoView.swift", additions: 18, deletions: 3),
        .init(kind: "M", path: "Sources/termio/TermioStore/TermioStore+TerminalSurface.swift", additions: 62, deletions: 41),
        .init(kind: "A", path: "Sources/termio/SessionHost.swift", additions: 120, deletions: 0),
    ]

    static let sampleDiff = """
    @@ -41,7 +41,9 @@ func makeContentSplitViewController() {
         let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarVC)
         sidebar.minimumThickness = 220
    -    window.styleMask.insert(.fullSizeContentView)
    +    sidebar.titlebarSeparatorStyle = .automatic
    +    window.titlebarAppearsTransparent = true
    +    window.styleMask.insert(.fullSizeContentView)
         splitViewController.addSplitViewItem(sidebar)

    @@ -88,6 +90,12 @@ func applyTheme(_ theme: TerminalTheme) {
         controller.setTheme(theme)
    +    // Resolve the dynamic color statically: fullscreen windows on
    +    // macOS 26 do not re-evaluate NSColor appearance providers.
    +    let resolved = theme.background.resolvedColor(for: window)
    +    window.backgroundColor = resolved
         inspector.refresh()
     }
    """
}
