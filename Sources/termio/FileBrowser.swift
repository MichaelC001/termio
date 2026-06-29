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

    /// The directory the tree is rooted at: the selected session's worktree if it
    /// has one, otherwise its project folder. `nil` when nothing is selected.
    private var projectPath: String? {
        guard let id = store.selectedSessionID, let project = store.project(for: id) else { return nil }
        return store.session(id)?.worktreePath ?? project.path
    }

    var body: some View {
        content
        // The file column lives on the terminal side, so it takes the terminal's own background
        // (rather than a sidebar material) — it reads as an extension of the content area. Fills
        // the whole column behind the transparent list, ignoring the safe area so it runs
        // full-height. Tracks the terminal theme live via `settings`.
        .background(Color(nsColor: settings.terminalBackgroundColor).ignoresSafeArea())
        // A single full-height hairline on the leading edge as the border with the terminal. A
        // slightly-bright line (rather than the dim system separator) reads as a clean luminous
        // edge on its own, echoing the leading sidebar's glowing border — no soft bloom gradient.
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.white.opacity(0.15))
                .frame(width: 1)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        // A drop on empty space targets the project root: a file already in the tree
        // is *moved* there, a file dragged in from the Finder is *copied* in. Folder
        // rows install their own, more specific drop targets (see `FileTreeList`), so
        // this only catches drops that miss every row. No panel-wide target ring —
        // dragging a row out is itself a `URL` drag, so a whole-panel highlight would
        // be a false positive; the folder rows light up individually instead.
        .dropDestination(for: URL.self) { urls, _ in
            guard let projectPath else { return false }
            return receive(urls, into: URL(fileURLWithPath: projectPath))
        }
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
                font: settings.interfaceFont,
                onDrop: { sources, destination in receive(sources, into: destination) }
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

    /// Places each dropped file into `destination` (a folder inside the tree, or the
    /// project root). A file that already lives in the project is *moved* — the VS
    /// Code tree gesture; a file dragged in from the Finder is *copied*. A clash with
    /// an existing name gets a numbered suffix rather than clobbering it. No-op drops
    /// (a file onto its own folder) and incoherent ones (a folder onto itself or its
    /// own descendant) are skipped. Refreshes the tree and reports whether anything
    /// changed.
    private func receive(_ sources: [URL], into destination: URL) -> Bool {
        guard let projectPath else { return false }
        let rootPath = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        let destinationDir = destination.standardizedFileURL
        let manager = FileManager.default
        var changedAny = false
        for source in sources {
            let src = source.standardizedFileURL
            // Already in this folder, or a folder dropped onto itself / a descendant.
            if src.deletingLastPathComponent() == destinationDir { continue }
            if destinationDir.path == src.path || destinationDir.path.hasPrefix(src.path + "/") { continue }

            let isInProject = src.path == rootPath || src.path.hasPrefix(rootPath + "/")
            let target = uniqueDestination(for: src.lastPathComponent, in: destinationDir, manager: manager)
            do {
                if isInProject {
                    try manager.moveItem(at: src, to: target)
                } else {
                    try manager.copyItem(at: src, to: target)
                }
                changedAny = true
            } catch {
                NSLog("termio: failed to place %@ into %@: %@", src.path, destinationDir.path, String(describing: error))
            }
        }
        if changedAny { refresh() }
        return changedAny
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
    /// Moves/copies `sources` into a folder `destination`; returns whether the tree
    /// changed. Supplied by `FileBrowserView`, which owns the project path.
    let onDrop: (_ sources: [URL], _ destination: URL) -> Bool

    var body: some View {
        // No `selection:` binding: the system source-list selection paints an
        // edge-to-edge blue accent fill that can't be restyled. Instead each row
        // tracks selection by tap and paints the same `SidebarRowHighlight` the left
        // sidebar uses, so both panels' selected rows read identically (inset, frosted
        // — not a flush blue band).
        List(nodes, children: \.children) { node in
            FileRow(node: node, font: font, selection: $selection, onDrop: onDrop)
        }
        .listStyle(.sidebar)
        // Drop the list's own backing so the terminal-colored background behind it (see
        // `FileBrowserView.body`) shows through — the file column lives in a plain split item, not
        // a panel item, so it carries no system vibrant background of its own.
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
    }
}

/// A single tree row. A view of its own (rather than an inline builder) so each
/// row can hold the `isHovering`/`isTargeted` state that drives its highlight, and
/// so selection is a tap rather than the system source-list accent fill.
private struct FileRow: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    let node: FileNode
    let font: Font
    @Binding var selection: URL?
    let onDrop: (_ sources: [URL], _ destination: URL) -> Bool

    @State private var isHovering = false
    /// True while a drag hovers this folder, lighting its background the way the VS
    /// Code explorer marks the folder a drop would land in.
    @State private var isTargeted = false

    private var isSelected: Bool { selection == node.url }
    private var chrome: ChromeTheme? { settings.chromeTheme(for: colorScheme) }

    /// Folder icons take the same color as the left sidebar's folder mark — the
    /// theme's foreground (or `.primary`), not the blue accent — so the two panels'
    /// folders match. Files stay a muted `.secondary` below them.
    private var iconStyle: AnyShapeStyle {
        if node.isDirectory {
            return chrome.map { AnyShapeStyle($0.foreground) } ?? AnyShapeStyle(.primary)
        }
        return AnyShapeStyle(.secondary)
    }

    var body: some View {
        let row = Label {
            Text(node.name)
                .font(font)
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: node.symbolName)
                .foregroundStyle(iconStyle)
        }
        // Tighten the generous default sidebar-row height into a denser tree, the
        // way the project sidebar floors its own rows.
        .padding(.vertical, 1)
        // Fill the row so the tap target — and any folder drop target — spans its
        // full width, not just the label's footprint.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // Drag a row out as its file URL. The terminal pane catches the drop and
        // inserts the shell-quoted path at the prompt (see `TerminalPane.sendPaths`);
        // a folder row catches it to move the file into that folder. `.draggable`
        // sits *before* the tap so the drag gesture wins the pointer-down; selecting
        // is a `simultaneousGesture` (not `.onTapGesture`, which would compete with
        // the drag and make it start only after a deliberate, sticky pull).
        .draggable(node.url)
        .simultaneousGesture(TapGesture().onEnded { selection = node.url })
        .onHover { isHovering = $0 }
        // The same lift the left sidebar paints for its rows: selection (or a drag
        // hovering a folder) reads as the frosted/accent selected look, hover a
        // fainter step below — so both side panels' rows highlight identically.
        .listRowBackground(
            SidebarRowHighlight(
                isSelected: isSelected || isTargeted,
                isHovering: isHovering,
                chrome: chrome
            )
            .animation(.easeInOut(duration: 0.12), value: isSelected)
            .animation(.easeInOut(duration: 0.12), value: isTargeted)
            .animation(.easeInOut(duration: 0.12), value: isHovering)
        )

        // Only folders are drop targets — dropping a file onto a folder moves it in,
        // the VS Code tree gesture. Files are not targets (no "drop onto a file").
        if node.isDirectory {
            row.dropDestination(for: URL.self) { urls, _ in
                onDrop(urls, node.url)
            } isTargeted: { isTargeted = $0 }
        } else {
            row
        }
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
