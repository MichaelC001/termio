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
    /// Double-clicking a file activates it: the hosting controller routes a previewable
    /// file (image, PDF, HTML) to Quick Look and everything else to the code editor.
    let onActivate: (URL) -> Void

    @State private var root: FileNode?
    /// Bumped to collapse the whole tree: it is the file list's `.id`, so changing it
    /// rebuilds the list fresh — and a fresh `List(children:)` starts fully collapsed.
    @State private var treeGeneration = 0

    /// The directory the tree is rooted at: the selected session's worktree if it
    /// has one, otherwise its project folder. `nil` when nothing is selected.
    private var projectPath: String? {
        guard let id = store.selectedSessionID, let project = store.project(for: id) else { return nil }
        return store.session(id)?.worktreePath ?? project.path
    }

    var body: some View {
        VStack(spacing: 0) {
            switch store.inspectorTab {
            case .files:
                if let root { header(root: root) }
                content
            case .changes:
                if let repoRoot = projectPath {
                    GitChangesView(repoRoot: repoRoot, changeCount: $store.gitChangeCount)
                } else {
                    content
                }
            }
        }
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
        .onAppear { refresh(); seedChangeCount() }
        .onChange(of: projectPath) {
            refresh()
            seedChangeCount()
        }
        .onChange(of: browserState.selection) {
            // Single-click open (VS Code): the table fires native selection on a clean
            // click — reliably, unlike a click recognizer, which `NSOutlineView`'s own
            // primary-button tracking swallows. So opening on selection IS the click
            // handler. Files only; selecting a folder just expands it.
            if let url = browserState.selection, !isDirectory(url) {
                onActivate(url)
            }
            // Keep an open Quick Look panel in step as the selection moves.
            if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
                QLPreviewPanel.shared().reloadData()
            }
        }
    }

    /// Whether `url` points at a directory — used to open only files on selection.
    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    @ViewBuilder
    private var content: some View {
        if let root {
            FileTreeList(
                nodes: root.children ?? [],
                selection: $browserState.selection,
                font: settings.interfaceFont,
                onDrop: { sources, destination in receive(sources, into: destination) },
                rootURL: root.url,
                actions: treeActions
            )
            .onKeyPress(.space) {
                guard browserState.selection != nil else { return .ignored }
                onQuickLook()
                return .handled
            }
            // Collapse All rebuilds the list by changing its identity (see `treeGeneration`).
            .id(treeGeneration)
        } else {
            ContentUnavailableView(
                "No Project",
                systemImage: "folder",
                description: Text("Select a session to browse its files.")
            )
        }
    }

    /// The VS Code-style explorer header: the root folder's name, and trailing action
    /// buttons — New File / New Folder (created at the project root), Refresh (re-read
    /// from disk), and Collapse All.
    private func header(root: FileNode) -> some View {
        HStack(spacing: 2) {
            Text(root.name)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            TreeHeaderButton(codicon: .newFile, help: "New File") {
                createFile(in: root.url)
            }
            TreeHeaderButton(codicon: .newFolder, help: "New Folder") {
                createFolder(in: root.url)
            }
            TreeHeaderButton(codicon: .refresh, help: "Refresh") {
                refresh()
            }
            TreeHeaderButton(codicon: .collapseAll, help: "Collapse All") {
                treeGeneration += 1
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
    }

    /// Seeds the switcher's Changes badge with the repo's dirty-file count, so it is
    /// right before the user ever opens the Changes pane (which then keeps it fresh).
    private func seedChangeCount() {
        guard let repoRoot = projectPath else {
            store.gitChangeCount = 0
            return
        }
        Task { store.gitChangeCount = await GitService.changes(in: repoRoot).count }
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

    /// The create/delete actions the row context menu invokes, plus single-click open
    /// (`onActivate`). Bundled so a row carries one value instead of four closures.
    private var treeActions: FileTreeActions {
        FileTreeActions(
            newFile: { createFile(in: $0) },
            newFolder: { createFolder(in: $0) },
            delete: { delete($0) }
        )
    }

    /// Prompts for a name, creates an empty file in `directory`, then selects and
    /// opens it — VS Code's "New File". A name clash gets a numbered suffix.
    private func createFile(in directory: URL) {
        guard let name = promptForName(title: "New File", defaultName: "untitled.txt") else { return }
        let target = uniqueDestination(for: name, in: directory, manager: .default)
        guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
            NSLog("termio: failed to create file at %@", target.path)
            return
        }
        refresh()
        browserState.selection = target
        onActivate(target)
    }

    /// Prompts for a name and creates a folder in `directory`, then selects it.
    private func createFolder(in directory: URL) {
        guard let name = promptForName(title: "New Folder", defaultName: "untitled folder") else { return }
        let target = uniqueDestination(for: name, in: directory, manager: .default)
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            refresh()
            browserState.selection = target
        } catch {
            NSLog("termio: failed to create folder at %@: %@", target.path, String(describing: error))
        }
    }

    /// Moves `url` to the Trash after a confirm — recoverable, not an unlink — clears
    /// it from the selection, and refreshes.
    private func delete(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "Move “\(url.lastPathComponent)” to the Trash?"
        alert.informativeText = "You can restore it from the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            if browserState.selection == url { browserState.selection = nil }
            refresh()
        } catch {
            NSLog("termio: failed to trash %@: %@", url.path, String(describing: error))
        }
    }

    /// A modal name prompt — one text field in an `NSAlert`, pre-filled with
    /// `defaultName`. Returns the trimmed entry, or `nil` if cancelled or emptied.
    private func promptForName(title: String, defaultName: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = defaultName
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

}

/// A quiet icon button for the explorer / Changes pane headers. The explorer's file
/// actions draw VS Code's own codicon glyphs (see `Codicon`) so the toolbar matches
/// VS Code; the Changes pane uses SF Symbols. Both render quiet `.secondary` at rest,
/// brightening to primary on hover over a faint rounded fill.
struct TreeHeaderButton: View {
    /// Either an SF Symbol name or a VS Code codicon — the two icon sources the two
    /// header toolbars draw from.
    enum Source {
        case symbol(String)
        case codicon(Codicon)
    }

    let source: Source
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    init(systemName: String, help: String, action: @escaping () -> Void) {
        self.source = .symbol(systemName)
        self.help = help
        self.action = action
    }

    init(codicon: Codicon, help: String, action: @escaping () -> Void) {
        self.source = .codicon(codicon)
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            icon
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }

    @ViewBuilder
    private var icon: some View {
        switch source {
        case .symbol(let name):
            Image(systemName: name)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 14))
                .foregroundStyle(isHovering ? Color.primary : Color.secondary)
        case .codicon(let codicon):
            CodiconView(icon: codicon, size: 15, color: isHovering ? .primary : .secondary)
        }
    }
}

/// The right-click menu actions the tree's rows invoke: `newFile`/`newFolder`
/// (created inside the given directory) and `delete`. Bundled so `FileRow` carries
/// one value rather than three closures. (Single-click open is driven by the List's
/// native selection, not a row action — see `FileBrowserView`.)
struct FileTreeActions {
    let newFile: (_ directory: URL) -> Void
    let newFolder: (_ directory: URL) -> Void
    let delete: (URL) -> Void
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
    /// The project (or worktree) root — the directory the empty-area menu creates in.
    let rootURL: URL
    /// Open / create / delete actions, forwarded to each row.
    let actions: FileTreeActions

    var body: some View {
        // Keep List's native `selection:` binding — it drives selection at the AppKit
        // layer, which coexists cleanly with `.draggable` (a SwiftUI tap gesture does
        // not, and makes the drag sticky/unreliable). The only downside of the native
        // selection — its edge-to-edge blue accent fill — is removed by setting the
        // outline view's `selectionHighlightStyle = .none` (see `FileRow`), leaving our
        // own `SidebarRowHighlight` as the sole, left-sidebar-matching selection cue.
        List(nodes, children: \.children, selection: $selection) { node in
            FileRow(node: node, font: font, isSelected: selection == node.url, onDrop: onDrop, actions: actions)
        }
        .listStyle(.sidebar)
        // Drop the list's own backing so the terminal-colored background behind it (see
        // `FileBrowserView.body`) shows through — the file column lives in a plain split item, not
        // a panel item, so it carries no system vibrant background of its own.
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
        // A right-click in the empty area below the rows offers New File / New Folder
        // at the project root — the rows' own menus take the clicks that land on them.
        .background(EmptyAreaContextMenu(rootDirectory: rootURL, actions: actions))
    }
}

/// A single tree row. A view of its own (rather than an inline builder) so each
/// row can hold the `isHovering`/`isTargeted` state that drives its highlight.
private struct FileRow: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    let node: FileNode
    let font: Font
    let isSelected: Bool
    let onDrop: (_ sources: [URL], _ destination: URL) -> Bool
    let actions: FileTreeActions

    @State private var isHovering = false
    /// True while a drag hovers this folder, lighting its background the way the VS
    /// Code explorer marks the folder a drop would land in.
    @State private var isTargeted = false

    private var chrome: ChromeTheme? { settings.chromeTheme(for: colorScheme) }

    var body: some View {
        // One explicit HStack for both kinds (not `Label`, whose internal insets shift
        // the title): a folder is just its name pulled flush to the disclosure chevron
        // (VS Code, no glyph); a file leads with its type icon. Because both start at
        // the HStack's leading edge, a folder's name lines up exactly under the file
        // icons below it.
        let row = HStack(spacing: 5) {
            if !node.isDirectory {
                Image(systemName: node.symbolName)
                    .foregroundStyle(.secondary)
                    .frame(width: 16, alignment: .leading)
            }
            Text(node.name)
                .font(font)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        // Tighten the generous default sidebar-row height into a denser tree, the
        // way the project sidebar floors its own rows.
        .padding(.vertical, 1)
        // Nudge the whole row off the disclosure chevron so a folder name isn't
        // crowded against the arrow. Applied to both kinds, so folder names and file
        // icons stay in the same column.
        .padding(.leading, 6)
        // Fill the row so the tap target — and any folder drop target — spans its
        // full width, not just the label's footprint.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        // Strip the source list's blue selection fill at the AppKit layer, so the only
        // selection cue is our `SidebarRowHighlight` below. Lives in a row so it can
        // walk up to the enclosing outline view.
        .background(OutlineSelectionStyleStripper())
        // Drag a row out as its file URL. The terminal pane catches the drop and
        // inserts the shell-quoted path at the prompt (see `TerminalPane.sendPaths`);
        // a folder row catches it to move the file into that folder. Selection is the
        // List's own `selection:` binding (set up in `FileTreeList`), which coexists
        // with `.draggable` — so the drag stays immediate.
        .draggable(node.url)
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
        // Right-click menu via an AppKit `NSMenu`, NOT SwiftUI's `.contextMenu` —
        // the latter paints an accent highlight ring around the targeted row that
        // can't be styled off. New File / New Folder appear only for a folder (they
        // create inside it); a file gets just Delete. The empty area below the rows
        // has its own root menu (see `EmptyAreaContextMenu`).
        .background(RowContextMenu(
            isDirectory: node.isDirectory,
            target: node.url,
            actions: actions
        ))

        // Only folders are drop targets — dropping a file onto a folder moves it in,
        // the VS Code tree gesture. Files are not targets (no "drop onto a file").
        // A single click opens a file via the List's native selection (see
        // `FileBrowserView.onChange(of: selection)`), so no per-row open handler here.
        if node.isDirectory {
            row.dropDestination(for: URL.self) { urls, _ in
                onDrop(urls, node.url)
            } isTargeted: { isTargeted = $0 }
        } else {
            row
        }
    }
}

/// The per-row right-click menu, via AppKit `NSMenu` rather than SwiftUI's
/// `.contextMenu` — the latter rings the targeted row with an un-styleable accent
/// highlight. A secondary-click recognizer on the row's own view pops the menu up,
/// so nothing emphasizes the row. New File / New Folder appear only for a folder
/// (created inside it); a file gets just Delete.
private struct RowContextMenu: NSViewRepresentable {
    let isDirectory: Bool
    let target: URL
    let actions: FileTreeActions

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.owner = view
        context.coordinator.configure(isDirectory: isDirectory, target: target, actions: actions)
        context.coordinator.attach()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.configure(isDirectory: isDirectory, target: target, actions: actions)
        context.coordinator.attach()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var owner: NSView?
        private var isDirectory = false
        private var target = URL(fileURLWithPath: "/")
        private var actions: FileTreeActions?
        private weak var hostView: NSView?
        private var recognizer: NSClickGestureRecognizer?

        func configure(isDirectory: Bool, target: URL, actions: FileTreeActions) {
            self.isDirectory = isDirectory
            self.target = target
            self.actions = actions
        }

        func attach() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let owner = self.owner else { return }
                guard let host = Self.rowView(above: owner) else { return }
                if hostView === host, recognizer != nil { return }
                detach()
                let recognizer = NSClickGestureRecognizer(target: self, action: #selector(self.showMenu(_:)))
                recognizer.buttonMask = 0x2 // secondary (right) mouse button
                host.addGestureRecognizer(recognizer)
                self.recognizer = recognizer
                self.hostView = host
            }
        }

        func detach() {
            if let recognizer, let hostView { hostView.removeGestureRecognizer(recognizer) }
            recognizer = nil
            hostView = nil
        }

        @objc private func showMenu(_ recognizer: NSClickGestureRecognizer) {
            guard let hostView else { return }
            let menu = NSMenu()
            if isDirectory {
                menu.addItem(menuItem("New File", #selector(newFile)))
                menu.addItem(menuItem("New Folder", #selector(newFolder)))
                menu.addItem(.separator())
            }
            menu.addItem(menuItem("Delete", #selector(deleteItem)))
            menu.popUp(positioning: nil, at: recognizer.location(in: hostView), in: hostView)
        }

        private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            return item
        }

        @objc private func newFile() { actions?.newFile(target) }
        @objc private func newFolder() { actions?.newFolder(target) }
        @objc private func deleteItem() { actions?.delete(target) }

        private static func rowView(above view: NSView) -> NSView? {
            var ancestor = view.superview
            while let current = ancestor {
                if current is NSTableRowView { return current }
                ancestor = current.superview
            }
            return nil
        }
    }
}

/// The right-click menu for the empty area below the rows: New File / New Folder at
/// the project root. One recognizer on the outline view, guarded to fire only where
/// no row sits (a row's own `RowContextMenu` handles clicks that land on it).
private struct EmptyAreaContextMenu: NSViewRepresentable {
    let rootDirectory: URL
    let actions: FileTreeActions

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.owner = view
        context.coordinator.configure(rootDirectory: rootDirectory, actions: actions)
        context.coordinator.attach()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.configure(rootDirectory: rootDirectory, actions: actions)
        context.coordinator.attach()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var owner: NSView?
        private var rootDirectory = URL(fileURLWithPath: "/")
        private var actions: FileTreeActions?
        private weak var table: NSTableView?
        private var recognizer: NSClickGestureRecognizer?

        func configure(rootDirectory: URL, actions: FileTreeActions) {
            self.rootDirectory = rootDirectory
            self.actions = actions
        }

        func attach() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let owner = self.owner else { return }
                guard let table = Self.outlineView(near: owner) else { return }
                if self.table === table, recognizer != nil { return }
                detach()
                let recognizer = NSClickGestureRecognizer(target: self, action: #selector(self.showMenu(_:)))
                recognizer.buttonMask = 0x2 // secondary (right) mouse button
                table.addGestureRecognizer(recognizer)
                self.recognizer = recognizer
                self.table = table
            }
        }

        func detach() {
            if let recognizer, let table { table.removeGestureRecognizer(recognizer) }
            recognizer = nil
            table = nil
        }

        @objc private func showMenu(_ recognizer: NSClickGestureRecognizer) {
            guard let table else { return }
            let point = recognizer.location(in: table)
            // Only the empty area — a click on a real row is handled by its own menu.
            guard table.row(at: point) == -1 else { return }
            let menu = NSMenu()
            menu.addItem(menuItem("New File", #selector(newFile)))
            menu.addItem(menuItem("New Folder", #selector(newFolder)))
            menu.popUp(positioning: nil, at: point, in: table)
        }

        private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            return item
        }

        @objc private func newFile() { actions?.newFile(rootDirectory) }
        @objc private func newFolder() { actions?.newFolder(rootDirectory) }

        /// Walk up to the enclosing scroll view, then find the outline/table view in it.
        private static func outlineView(near view: NSView) -> NSTableView? {
            var ancestor: NSView? = view
            while let current = ancestor {
                if let scroll = current as? NSScrollView, let table = findTable(in: scroll) {
                    return table
                }
                ancestor = current.superview
            }
            return nil
        }

        private static func findTable(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for subview in view.subviews {
                if let table = findTable(in: subview) { return table }
            }
            return nil
        }
    }
}

/// A zero-size helper that finds the `NSOutlineView` hosting the file tree (by
/// walking up from its own placement inside a row) and sets its
/// `selectionHighlightStyle` to `.none`. That strips the source list's blue accent
/// fill while leaving selection itself intact — so the List keeps native, drag-
/// friendly selection and `SidebarRowHighlight` is the only thing that paints it.
/// Re-applied on every update because each row mounts one, so any list rebuild
/// reasserts the style.
private struct OutlineSelectionStyleStripper: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { Self.strip(from: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.strip(from: nsView) }
    }

    private static func strip(from view: NSView) {
        var ancestor = view.superview
        while let current = ancestor {
            // NSOutlineView is an NSTableView subclass, so this catches the tree.
            if let table = current as? NSTableView {
                if table.selectionHighlightStyle != .none {
                    table.selectionHighlightStyle = .none
                }
                return
            }
            ancestor = current.superview
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
            FileBrowserView(
                onQuickLook: { FileBrowserHostingController.toggleQuickLook() },
                // A single click opens the file over the terminal (driven by `store.openFileURL`):
                // a previewable file (image, PDF, HTML) in the read-only preview, everything else
                // in the editor. The terminal pane picks which based on the file kind. (Spacebar
                // still pops Quick Look for a quick peek without leaving the tree.)
                onActivate: { url in
                    store.openFileURL = url
                }
            )
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
