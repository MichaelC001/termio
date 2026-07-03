import TermioShared
import UIKit

/// The right-side drawer: Files (expandable tree) / Changes (diff list),
/// mirroring the desktop inspector's segmented layout. On a live companion
/// session the tree is the Mac project's real filesystem — directories load
/// lazily over the wire, tapping a file opens the full-screen read-only
/// viewer. Offline (mock sessions) it falls back to the bundled sample tree.
final class InspectorViewController: UIViewController {
    private enum Pane: Int { case files = 0, changes = 1 }

    private let session: MockSession
    private let companionURL: URL?
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let segment = UISegmentedControl(items: ["Files", "Changes"])
    private let spinner = UIActivityIndicatorView(style: .medium)

    /// Offline sample tree (mock sessions, PoC streams).
    private var fileRows: [(node: FileNode, depth: Int)] = []
    /// Live tree mirrored from the Mac, built lazily one directory at a time.
    private var remoteRoots: [RemoteNode] = []
    private var remoteRows: [(node: RemoteNode, depth: Int)] = []
    private var client: CompanionClient?
    /// The file path awaiting a `.file` reply, so late/errored replies don't
    /// open stale viewers.
    private var pendingRead: String?
    /// The presented viewer, kept weak so save acks/conflicts route to it.
    private weak var activeViewer: FileViewerController?
    private var pane: Pane = .files

    /// The file plane needs a companion link and a project to scope it to.
    private var isLive: Bool { companionURL != nil && session.projectRosterID != nil }

    init(session: MockSession, companionURL: URL? = nil) {
        self.session = session
        self.companionURL = companionURL
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        client?.stop()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        segment.selectedSegmentIndex = 0
        segment.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            pane = Pane(rawValue: segment.selectedSegmentIndex) ?? .files
            tableView.reloadData()
        }, for: .valueChanged)
        navigationItem.titleView = segment

        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 44
        tableView.frame = view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(tableView)

        spinner.hidesWhenStopped = true
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: spinner)

        if isLive {
            connectFilePlane()
        } else {
            reloadFileRows()
        }
    }

    private func reloadFileRows() {
        fileRows = FileNode.visibleRows(from: FileNode.sampleRoot)
    }

    // MARK: - Live tree (companion file plane)

    /// A dedicated control connection for file browsing — the terminal's own
    /// socket is a raw PTY byte stream once attached, so it can't carry these.
    private func connectFilePlane() {
        guard let companionURL, let projectID = session.projectRosterID else { return }
        spinner.startAnimating()
        let client = CompanionClient(url: companionURL)
        client.onConnected = { [weak self] connected in
            guard let self, connected, remoteRoots.isEmpty else { return }
            client.send(.listFiles(projectID: projectID, path: ""))
        }
        client.onFileList = { [weak self] path, entries in
            self?.receiveListing(path: path, entries: entries)
        }
        client.onFile = { [weak self] file in
            self?.receiveFile(file)
        }
        client.onWritten = { [weak self] _, mtime in
            self?.activeViewer?.didSave(mtime: mtime)
        }
        client.onError = { [weak self] message in
            guard let self else { return }
            // With no read in flight, the failed request was the viewer's write.
            if pendingRead == nil {
                activeViewer?.saveFailed(message)
                return
            }
            pendingRead = nil
            spinner.stopAnimating()
            let alert = UIAlertController(title: "Couldn't open file", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
        client.start()
        self.client = client
    }

    private func receiveListing(path: String, entries: [WireFileEntry]) {
        spinner.stopAnimating()
        let nodes = entries.map { RemoteNode(entry: $0, parentPath: path) }
        if path.isEmpty {
            remoteRoots = nodes
        } else if let dir = findRemoteNode(path, in: remoteRoots) {
            dir.children = nodes
            dir.isExpanded = true
        }
        rebuildRemoteRows()
        if pane == .files { tableView.reloadData() }
    }

    private func receiveFile(_ file: WireFile) {
        guard file.path == pendingRead else { return }
        pendingRead = nil
        spinner.stopAnimating()
        if file.binary {
            guard let quickLook = FileViewerController.quickLook(for: file) else { return }
            present(quickLook, animated: true)
            return
        }
        let viewer = FileViewerController(file: file)
        viewer.onSave = { [weak self] data, baseMtime in
            guard let self, let projectID = session.projectRosterID else { return }
            client?.send(.writeFile(
                projectID: projectID, path: file.path,
                base64: data.base64EncodedString(), baseMtime: baseMtime
            ))
        }
        viewer.onReload = { [weak self] in
            self?.requestFile(file.path)
        }
        activeViewer = viewer
        present(viewer, animated: true)
    }

    private func requestFile(_ path: String) {
        guard let projectID = session.projectRosterID else { return }
        pendingRead = path
        spinner.startAnimating()
        client?.send(.readFile(projectID: projectID, path: path))
    }

    private func findRemoteNode(_ path: String, in nodes: [RemoteNode]) -> RemoteNode? {
        for node in nodes {
            if node.relPath == path { return node }
            // Only walk ancestors of the target path.
            if node.isDir, path.hasPrefix(node.relPath + "/"),
               let children = node.children,
               let found = findRemoteNode(path, in: children) {
                return found
            }
        }
        return nil
    }

    private func rebuildRemoteRows(from nodes: [RemoteNode]? = nil, depth: Int = 0) {
        if depth == 0 { remoteRows = [] }
        for node in nodes ?? remoteRoots {
            remoteRows.append((node, depth))
            if node.isDir, node.isExpanded, let children = node.children {
                rebuildRemoteRows(from: children, depth: depth + 1)
            }
        }
    }

    private static func changedDot() -> UIView {
        let dot = UIView(frame: CGRect(x: 0, y: 0, width: 8, height: 8))
        dot.backgroundColor = .systemBlue
        dot.layer.cornerRadius = 4
        return dot
    }
}

extension InspectorViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch pane {
        case .files: isLive ? remoteRows.count : fileRows.count
        case .changes: MockChange.samples.count
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell")
            ?? UITableViewCell(style: .value1, reuseIdentifier: "cell")
        switch pane {
        case .files:
            let name: String, isDir: Bool, expanded: Bool, changed: Bool, depth: Int
            if isLive {
                let (node, d) = remoteRows[indexPath.row]
                (name, isDir, expanded, changed, depth) =
                    (node.name, node.isDir, node.isExpanded, node.changed, d)
            } else {
                let (node, d) = fileRows[indexPath.row]
                (name, isDir, expanded, changed, depth) =
                    (node.name, node.isDirectory, node.isExpanded, node.changed, d)
            }
            var config = cell.defaultContentConfiguration()
            config.text = name
            config.textProperties.font = .preferredFont(forTextStyle: .subheadline)
            if isDir {
                config.image = UIImage(systemName: expanded ? "chevron.down" : "chevron.right")
                config.imageProperties.tintColor = .secondaryLabel
            } else {
                config.image = UIImage(systemName: "doc")
                config.imageProperties.tintColor = .systemGray2
            }
            config.imageProperties.maximumSize = CGSize(width: 14, height: 14)
            config.directionalLayoutMargins.leading = CGFloat(depth) * 18 + 12
            cell.contentConfiguration = config
            cell.accessoryView = changed ? Self.changedDot() : nil
            cell.accessoryType = .none
        case .changes:
            let change = MockChange.samples[indexPath.row]
            var config = cell.defaultContentConfiguration()
            config.text = (change.path as NSString).lastPathComponent
            config.secondaryText = "\(change.kind)  +\(change.additions) −\(change.deletions)"
            config.textProperties.font = .preferredFont(forTextStyle: .subheadline)
            config.secondaryTextProperties.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            config.secondaryTextProperties.color = change.kind == "A" ? .systemGreen : .systemOrange
            cell.contentConfiguration = config
            cell.accessoryView = nil
            cell.accessoryType = .disclosureIndicator
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch pane {
        case .files where isLive:
            let (node, _) = remoteRows[indexPath.row]
            if node.isDir {
                if node.children != nil {
                    node.isExpanded.toggle()
                    rebuildRemoteRows()
                    tableView.reloadData()
                } else if let projectID = session.projectRosterID {
                    // First expand: fetch, then `receiveListing` opens it.
                    spinner.startAnimating()
                    client?.send(.listFiles(projectID: projectID, path: node.relPath))
                }
            } else {
                requestFile(node.relPath)
            }
        case .files:
            let (node, _) = fileRows[indexPath.row]
            if node.isDirectory {
                node.isExpanded.toggle()
                reloadFileRows()
                tableView.reloadData()
            }
        case .changes:
            let change = MockChange.samples[indexPath.row]
            navigationController?.pushViewController(DiffViewController(change: change), animated: true)
        }
    }
}

// MARK: - Remote tree node

/// One node of the live tree. `children == nil` means "not fetched yet" —
/// the first expand requests the listing and the reply fills it in.
private final class RemoteNode {
    let name: String
    let relPath: String
    let isDir: Bool
    let changed: Bool
    var children: [RemoteNode]?
    var isExpanded = false

    init(entry: WireFileEntry, parentPath: String) {
        name = entry.name
        relPath = parentPath.isEmpty ? entry.name : "\(parentPath)/\(entry.name)"
        isDir = entry.isDir
        changed = entry.changed
    }
}
