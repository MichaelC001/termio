import AppKit
import Quartz
import SwiftUI

/// A node in the project file tree. A class (not a struct) so SwiftUI's
/// `List(_:children:)` can lazily realize a folder's contents the first time it is
/// expanded — the `children` getter reads the directory on demand and caches it —
/// rather than walking the whole repo up front. Identity is the file URL, so the
/// outline keeps its expansion state across a refresh even though the nodes are
/// rebuilt.
final class FileNode: Identifiable {
    let url: URL
    let isDirectory: Bool
    var id: URL { url }
    var name: String { url.lastPathComponent }

    private var loadedChildren: [FileNode]?

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    /// `nil` for a file (so the outline draws no disclosure triangle); a folder's
    /// contents — read lazily and cached — for a directory. SwiftUI only asks for
    /// the children of an *expanded* node, so this stays cheap on a large tree.
    var children: [FileNode]? {
        guard isDirectory else { return nil }
        if let loadedChildren { return loadedChildren }
        let contents = FileNode.readContents(of: url)
        loadedChildren = contents
        return contents
    }

    /// Directory entries, folders first then files, each alphabetized the way the
    /// Finder orders names. Hidden entries are dropped (`.git`, dotfiles), as are a
    /// few heavy build directories that would only bloat the tree.
    private static func readContents(of url: URL) -> [FileNode] {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries
            .filter { !ignoredNames.contains($0.lastPathComponent) }
            .map { entry in
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return FileNode(url: entry, isDirectory: isDirectory)
            }
            .sorted { left, right in
                if left.isDirectory != right.isDirectory { return left.isDirectory }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
    }

    /// Non-hidden directories that are noise in a project tree (the hidden ones —
    /// `.git`, `.DS_Store` — are already excluded by `.skipsHiddenFiles`).
    private static let ignoredNames: Set<String> = ["node_modules", ".build", "DerivedData"]

    /// SF Symbol drawn beside the node: an open-ended folder, or a glyph hinting at
    /// the file's kind (image, document, code, or a plain page).
    var symbolName: String {
        if isDirectory { return "folder" }
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "svg":
            return "photo"
        case "pdf":
            return "doc.richtext"
        case "swift", "js", "ts", "tsx", "jsx", "py", "rs", "go", "c", "h", "cpp",
             "m", "json", "yml", "yaml", "toml", "sh", "md", "txt", "css", "html":
            return "doc.text"
        default:
            return "doc"
        }
    }
}

/// The current selection in the file tree, shared between the SwiftUI view (which
/// writes it) and the hosting controller (which reads it to feed Quick Look). Held
/// as its own object so the controller can answer `QLPreviewPanel`'s data-source
/// callbacks without reaching into SwiftUI's view state.
@MainActor
final class FileBrowserState: ObservableObject {
    @Published var selection: URL?
}

/// The trailing inspector's content: a native disclosure tree of the selected
/// session's project, rooted at the project (or worktree) directory. Selecting a
/// file and pressing space opens it in Quick Look (Finder's gesture); dragging
/// files from the Finder onto the panel copies them into the project root.
struct FileBrowserView: View {
    @EnvironmentObject var store: TermioStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var browserState: FileBrowserState
    /// Toggles the shared Quick Look panel — supplied by the hosting controller,
    /// which is the responder that drives `QLPreviewPanel`.
    let onQuickLook: () -> Void

    @State private var root: FileNode?
    @State private var isDropTargeted = false

    /// The directory the tree is rooted at: the selected session's worktree if it
    /// has one, otherwise its project folder. `nil` when nothing is selected.
    private var projectPath: String? {
        guard let id = store.selectedSessionID, let project = store.project(for: id) else { return nil }
        return store.session(id)?.worktreePath ?? project.path
    }

    var body: some View {
        content
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        // Dragging files from the Finder onto the panel copies them into the project
        // root — the "drop files into the project" gesture. termio is not sandboxed,
        // so the dragged URLs are readable without a security-scope dance.
        .dropDestination(for: URL.self) { urls, _ in
            copyIntoProject(urls)
        } isTargeted: { isDropTargeted = $0 }
        .onAppear { refresh() }
        .onChange(of: projectPath) { refresh() }
        // Keep an open Quick Look panel in step as the selection moves.
        .onChange(of: browserState.selection) {
            if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
                QLPreviewPanel.shared().reloadData()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let root {
            FileTreeList(
                nodes: root.children ?? [],
                selection: $browserState.selection,
                font: settings.interfaceFont
            )
            .onKeyPress(.space) {
                guard browserState.selection != nil else { return .ignored }
                onQuickLook()
                return .handled
            }
        } else {
            ContentUnavailableView(
                "No Project",
                systemImage: "folder",
                description: Text("Select a session to browse its files.")
            )
        }
    }

    /// Rebuilds the tree from the current project path. Called on appear, whenever
    /// the selected session moves to a different project, and after a drop.
    private func refresh() {
        guard let projectPath else {
            root = nil
            return
        }
        root = FileNode(url: URL(fileURLWithPath: projectPath), isDirectory: true)
    }

    /// Copies each dropped file into the project root, never overwriting an existing
    /// name (a clash gets a numbered suffix), then refreshes the tree. Returns
    /// whether anything was copied.
    private func copyIntoProject(_ urls: [URL]) -> Bool {
        guard let projectPath else { return false }
        let destination = URL(fileURLWithPath: projectPath)
        let manager = FileManager.default
        var copiedAny = false
        for source in urls {
            let target = uniqueDestination(for: source.lastPathComponent, in: destination, manager: manager)
            do {
                try manager.copyItem(at: source, to: target)
                copiedAny = true
            } catch {
                NSLog("termio: failed to copy %@ into project: %@", source.path, String(describing: error))
            }
        }
        if copiedAny { refresh() }
        return copiedAny
    }

    /// A non-colliding URL for `name` in `directory`: the plain name if free, else
    /// `name 2.ext`, `name 3.ext`, … so a drop never clobbers an existing file.
    private func uniqueDestination(for name: String, in directory: URL, manager: FileManager) -> URL {
        let candidate = directory.appendingPathComponent(name)
        guard manager.fileExists(atPath: candidate.path) else { return candidate }

        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 2
        while true {
            let suffixed = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let url = directory.appendingPathComponent(suffixed)
            if !manager.fileExists(atPath: url.path) { return url }
            index += 1
        }
    }

}

/// The disclosure tree itself, split out of `FileBrowserView` so the generic
/// `List(_:children:selection:)` expression type-checks on its own rather than as
/// one giant expression alongside the drop target and Quick Look wiring.
private struct FileTreeList: View {
    let nodes: [FileNode]
    @Binding var selection: URL?
    let font: Font

    var body: some View {
        List(nodes, children: \.children, selection: $selection) { node in
            Label {
                Text(node.name)
                    .font(font)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: node.symbolName)
                    .foregroundStyle(node.isDirectory ? Color.accentColor : Color.secondary)
            }
            // Tighten the generous default sidebar-row height into a denser tree, the
            // way the project sidebar floors its own rows.
            .padding(.vertical, 1)
            // Drag a row out as its file URL. The terminal pane catches the drop and
            // inserts the shell-quoted path at the prompt (see `TerminalPane.sendPaths`).
            .draggable(node.url)
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 1)
    }
}

/// Hosts `FileBrowserView` in the trailing inspector and drives the shared Quick
/// Look panel for it. `QLPreviewPanel` finds its controller by walking the
/// responder chain from the key window's first responder; because this view
/// controller sits in that chain (above the SwiftUI tree it hosts), it is the
/// natural owner of the panel while the inspector is focused.
@MainActor
final class FileBrowserHostingController: NSHostingController<AnyView>, @MainActor QLPreviewPanelDataSource {
    private let state: FileBrowserState

    init(store: TermioStore, settings: AppSettings) {
        let state = FileBrowserState()
        self.state = state
        super.init(rootView: AnyView(
            FileBrowserView(onQuickLook: { FileBrowserHostingController.toggleQuickLook() })
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(state)
        ))
    }

    @available(*, unavailable)
    required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows the Quick Look panel for the current selection, or hides it if it is
    /// already up — Finder's spacebar toggle.
    private static func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        state.selection == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        state.selection as? NSURL
    }
}
