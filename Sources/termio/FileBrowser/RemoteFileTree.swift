import AppKit
import Darwin
import SwiftUI

/// Owns one staged remote preview. Each lease has an atomic, private 0700
/// directory and removes only that directory when released, so concurrent
/// dev/release app processes cannot delete each other's active previews.
@MainActor
final class RemotePreviewLease {
    let fileURL: URL
    let displayName: String

    private let directoryURL: URL

    fileprivate init(fileURL: URL, displayName: String, directoryURL: URL) {
        self.fileURL = fileURL
        self.displayName = displayName
        self.directoryURL = directoryURL
    }

    deinit {
        let directory = directoryURL
        try? FileManager.default.removeItem(at: directory)
        Task { @MainActor in
            RemotePreviewStorage.didRelease(directory)
        }
    }
}

@MainActor
enum RemotePreviewStorage {
    private static var liveDirectories: Set<URL> = []

    static func stage(_ data: Data, named name: String) throws -> RemotePreviewLease {
        guard isSafeComponent(name) else { throw DeviceFileError.unsafeName }

        let parent = FileManager.default.temporaryDirectory
        var template = Array(
            parent.appendingPathComponent(
                "termio-preview-\(getuid())\(AppChannel.suffix)-XXXXXX",
                isDirectory: true
            ).path.utf8CString)
        let directoryPath: String? = template.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress, mkdtemp(base) != nil else { return nil }
            return String(cString: base)
        }
        guard let directoryPath else {
            throw CocoaError(.fileWriteUnknown)
        }

        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true).standardizedFileURL
        let ext = (name as NSString).pathExtension
        let localName = ext.isEmpty ? "preview" : "preview.\(ext)"
        guard isSafeComponent(localName) else {
            try? FileManager.default.removeItem(at: directory)
            throw DeviceFileError.unsafeName
        }
        let url = directory.appendingPathComponent(localName, isDirectory: false).standardizedFileURL
        guard url.deletingLastPathComponent() == directory.standardizedFileURL else {
            try? FileManager.default.removeItem(at: directory)
            throw DeviceFileError.unsafeName
        }
        do {
            try data.write(to: url, options: .atomic)
            liveDirectories.insert(directory)
            return RemotePreviewLease(
                fileURL: url, displayName: name, directoryURL: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func isSafeComponent(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.contains("\0")
    }

    fileprivate static func didRelease(_ directory: URL) {
        liveDirectories.remove(directory)
    }

    static func cleanup() {
        let directories = liveDirectories
        liveDirectories.removeAll()
        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

/// A node in the remote file tree — the SSH counterpart of `FileNode`. Same
/// lazy shape: SwiftUI's `List(_:children:)` realizes a folder on first expand.
/// But a remote listing can't block the getter, so an unloaded folder answers
/// an empty list and kicks the model's async fetch; when the entries land the
/// model publishes and the rows appear. Identity is the remote path, so the
/// outline keeps its expansion state across a refresh even though the nodes
/// are rebuilt (and a refreshed-but-still-expanded folder re-fetches lazily).
@MainActor
final class RemoteFileNode: Identifiable {
    let path: String
    let name: String
    let isDirectory: Bool
    let canPreview: Bool
    // Nonisolated: `Identifiable.id` is a nonisolated requirement, and the path
    // is immutable — no main-actor state involved.
    nonisolated var id: String { path }

    fileprivate var loadedChildren: [RemoteFileNode]?
    private weak var model: RemoteFileBrowserModel?

    fileprivate init(
        path: String,
        name: String,
        isDirectory: Bool,
        canPreview: Bool,
        model: RemoteFileBrowserModel
    ) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.canPreview = canPreview
        self.model = model
    }

    /// A synthetic local-form URL for the pieces that only look at the name —
    /// `FileIconView` keys icons off `lastPathComponent`. Never touched on disk.
    var iconURL: URL { URL(fileURLWithPath: path) }

    var children: [RemoteFileNode]? {
        guard isDirectory else { return nil }
        if let loadedChildren { return loadedChildren }
        model?.loadChildren(of: self)
        return []
    }
}

/// Drives the tree for a checkout on another machine, over that device's
/// `fs.list`/`fs.read` (`TermiodFiles.swift`).
///
/// No watching yet: the tree reloads on pane/app focus and the explicit refresh
/// button, by dropping the cached nodes — expansion state survives (node
/// identity is the path) and still-expanded folders re-fetch lazily. Live
/// updates are the `fs:` resource, which needs a channel that outlives one
/// request and is deliberately not here.
@MainActor
final class RemoteFileBrowserModel: ObservableObject {
    enum Phase {
        case connecting
        case ready
        case failed(String)
    }

    /// The machine and the directory this tree is rooted at. Identity, not a
    /// route: the pane follows the checkout, never the road it was reached by.
    let checkout: Checkout
    let root: String
    @Published private(set) var phase: Phase = .connecting
    @Published private(set) var rootNodes: [RemoteFileNode] = []

    /// The same read cap as the iOS companion's file preview and the daemon's
    /// own `fs.read` soft cap.
    static let previewByteLimit = Termiod.filePreviewByteLimit

    private let provider: DeviceFileProvider
    private var nodesByPath: [String: RemoteFileNode] = [:]
    private var loadsInFlight: Set<String> = []
    private var refreshing = false

    init(checkout: Checkout, root: String) {
        self.checkout = checkout
        self.root = root
        self.provider = DeviceFileProvider(
            route: checkout.device.route, root: root)
    }

    var host: String { checkout.device.name }

    func node(at path: String) -> RemoteFileNode? { nodesByPath[path] }

    /// Re-roots the tree from the device. Existing rows stay up while the
    /// listing is in flight (no flash to a spinner on an app-focus reconcile);
    /// only the never-loaded state shows `connecting`.
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            defer { refreshing = false }
            do {
                let entries = try await provider.list(root)
                nodesByPath = [:]
                rootNodes = nodes(for: entries, under: root)
                phase = .ready
            } catch {
                report(error, context: "list \(host):\(root)")
            }
        }
    }

    /// Fetches one folder's entries — called from the `children` getter on first
    /// expand, so it must tolerate being re-entered on every list render while
    /// the fetch is in flight.
    fileprivate func loadChildren(of node: RemoteFileNode) {
        guard !loadsInFlight.contains(node.path) else { return }
        loadsInFlight.insert(node.path)
        Task {
            defer { loadsInFlight.remove(node.path) }
            do {
                let entries = try await provider.list(node.path)
                node.loadedChildren = nodes(for: entries, under: node.path)
                objectWillChange.send()
            } catch {
                // Settle the folder as empty rather than leaving it unloaded —
                // the getter would re-fire the fetch on every render otherwise.
                // The next refresh retries it.
                node.loadedChildren = []
                report(error, context: "list \(host):\(node.path)")
            }
        }
    }

    /// Downloads the file into a uniquely-named temp file (keeping the device
    /// file's name, so icon and syntax detection work) for the read-only
    /// overlay. Throws `DeviceFileError.tooLarge` past the preview cap.
    func stageForPreview(_ node: RemoteFileNode) async throws -> RemotePreviewLease {
        guard node.canPreview else { throw DeviceFileError.notRegularFile }
        let data = try await provider.read(node.path, limit: Self.previewByteLimit)
        try Task.checkCancellation()
        return try RemotePreviewStorage.stage(data, named: node.name)
    }

    /// Routes a failure into the pane's state: an already-loaded tree stays up
    /// (a single folder failing shouldn't blank the pane) and only an empty one
    /// fails.
    func report(_ error: Error, context: String) {
        if error is CancellationError { return }
        Log.files.error("device \(context, privacy: .public): \(String(describing: error), privacy: .public)")
        if rootNodes.isEmpty {
            phase = .failed(Self.message(for: error))
        }
    }

    private func nodes(for entries: [FileEntry], under parent: String) -> [RemoteFileNode] {
        let base = parent.hasSuffix("/") ? parent : parent + "/"
        return entries.map { entry in
            let node = RemoteFileNode(
                path: base + entry.name, name: entry.name,
                isDirectory: entry.isDirectory,
                canPreview: entry.isPreviewable,
                model: self)
            nodesByPath[node.path] = node
            return node
        }
    }

    /// The device describes what went wrong; turning that into a sentence is the
    /// client's job, so the daemon's own message is shown verbatim where it has
    /// one and only the client-side cases are worded here.
    private static func message(for error: Error) -> String {
        switch error {
        case DeviceFileError.unsupported:
            return localized("This device’s termiod is too old to browse files.")
        case DeviceFileError.unsafeName:
            return localized("This device sent a name the file tree can’t show.")
        case DeviceFileError.notRegularFile:
            return localized("Only regular files can be previewed.")
        case TermiodClientError.requestFailed(let detail) where !detail.isEmpty:
            return detail
        default:
            return localized("The listing failed.")
        }
    }
}

/// The inspector's Files pane for a checkout on another machine: a read-only
/// disclosure tree served by that device's own daemon. Clicking a file stages it
/// locally and opens the read-only preview overlay; folders open on click like
/// the local tree. No drops, no create/rename/delete — the device's file plane
/// is read-only by design, and the user writes in the terminal, which is the
/// same app.
struct RemoteFileTreeView: View {
    @EnvironmentObject var store: TermioStore
    @EnvironmentObject var settings: AppSettings

    @StateObject private var model: RemoteFileBrowserModel
    @State private var selection: String?
    @State private var outlineView: NSOutlineView?
    @State private var previewTask: Task<Void, Never>?
    @State private var previewRequestID = 0

    init(checkout: Checkout, root: String) {
        _model = StateObject(
            wrappedValue: RemoteFileBrowserModel(checkout: checkout, root: root))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .onAppear { model.refresh() }
        .onDisappear { cancelPreviewRequest() }
        // The refresh model (no remote watching): reload when the app comes back
        // to the front — the same reconcile trigger as the git pane — but only
        // while the pane is actually visible.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if store.inspectorVisible { model.refresh() }
        }
        .onChange(of: store.inspectorVisible) { _, visible in
            if visible {
                model.refresh()
            } else {
                cancelPreviewRequest()
            }
        }
        .onChange(of: selection) {
            // Selection IS the click handler, exactly like the local tree: a
            // folder toggles open/closed, a file opens the preview.
            guard let path = selection, let node = model.node(at: path) else { return }
            if node.isDirectory {
                toggleSelectedFolder()
            } else if node.canPreview {
                preview(node)
                // Every click should be observable, including reopening the same
                // file after the overlay was dismissed.
                selection = nil
            } else {
                selection = nil
            }
        }
    }

    /// The explorer-style header: the host, and a Refresh that re-roots the tree.
    private var header: some View {
        HStack(spacing: 2) {
            Text(model.host)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            TreeHeaderButton(codicon: .refresh, help: "Refresh") {
                model.refresh()
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .connecting:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            PaneEmptyState(
                localized("Can’t browse \(model.host)"),
                icon: .serverStack,
                message: message
            )
        case .ready:
            List(model.rootNodes, children: \.children, selection: $selection) { node in
                RemoteFileRow(node: node, font: settings.interfaceFont,
                              isSelected: selection == node.id,
                              captureOutline: { outlineView = $0 })
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .padding(.leading, 12)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 1)
        }
    }

    /// Same gesture as the local tree (see `FileBrowserView.toggleSelectedFolder`):
    /// the click that selected a folder row is the only signal, so it toggles the
    /// row and clears the selection so the next click registers too.
    private func toggleSelectedFolder(attempt: Int = 0) {
        guard let outline = outlineView else { return }
        let row = outline.selectedRow
        guard row >= 0, let item = outline.item(atRow: row) else {
            if attempt < 3 {
                DispatchQueue.main.async { toggleSelectedFolder(attempt: attempt + 1) }
            }
            return
        }
        guard outline.isExpandable(item) else { return }
        if outline.isItemExpanded(item) {
            outline.animator().collapseItem(item)
        } else {
            outline.animator().expandItem(item)
        }
        selection = nil
    }

    private func preview(_ node: RemoteFileNode) {
        previewTask?.cancel()
        previewRequestID &+= 1
        let requestID = previewRequestID
        let presentationGeneration = store.filePresentationGeneration
        previewTask = Task { @MainActor in
            do {
                let lease = try await model.stageForPreview(node)
                guard !Task.isCancelled, requestID == previewRequestID else { return }
                // Adoption is conditional on no other local/remote presentation
                // winning while the download was in flight. HTML/SVG is routed
                // to source, and failed raster decoding never falls into WebKit.
                _ = store.presentRemoteFilePreview(
                    lease, expectedGeneration: presentationGeneration)
            } catch DeviceFileError.tooLarge {
                guard !Task.isCancelled, requestID == previewRequestID else { return }
                let alert = NSAlert()
                alert.messageText = "“\(node.name)” is too large to preview."
                alert.informativeText = "Preview is capped at 1 MB."
                alert.runModal()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, requestID == previewRequestID else { return }
                model.report(error, context: "read \(node.path)")
            }
        }
    }

    private func cancelPreviewRequest() {
        previewRequestID &+= 1
        previewTask?.cancel()
        previewTask = nil
    }
}

/// A remote tree row: the local `FileRow`'s look (shared icon column, hover and
/// selection lift) minus everything write-shaped — no drag, no drop, no context
/// menu.
private struct RemoteFileRow: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    let node: RemoteFileNode
    let font: Font
    let isSelected: Bool
    let captureOutline: (NSOutlineView?) -> Void

    @State private var isHovering = false

    private var chrome: ChromeTheme? { settings.chromeTheme(for: colorScheme) }

    var body: some View {
        HStack(spacing: 5) {
            if node.isDirectory {
                HugeIconView(icon: .folder, size: 15, color: chrome?.foreground ?? .primary)
                    .frame(width: 16, alignment: .leading)
            } else {
                FileIconView(url: node.iconURL, size: 12, symbolSize: 11, ink: chrome?.foreground ?? .primary)
                    .frame(width: 16, alignment: .leading)
            }
            Text(node.name)
                .font(font)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
        .padding(.leading, -6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .opacity(node.isDirectory || node.canPreview ? 1 : 0.55)
        .help(node.isDirectory || node.canPreview ? "" : "Special files can't be previewed")
        .background(OutlineViewFixups())
        .background(OutlineViewCapture(onFound: captureOutline))
        .listRowBackground(
            SidebarRowHighlight(
                isSelected: isSelected,
                isHovering: isHovering,
                chrome: chrome
            )
            .padding(.leading, -6)
            .animation(.easeInOut(duration: 0.12), value: isSelected)
            .animation(.easeInOut(duration: 0.12), value: isHovering)
        )
    }
}
