import UIKit

/// The right-side drawer: Files (expandable tree) / Changes (diff list),
/// mirroring the desktop inspector's segmented layout.
final class InspectorViewController: UIViewController {
    private enum Pane: Int { case files = 0, changes = 1 }

    private let session: MockSession
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let segment = UISegmentedControl(items: ["文件", "改动"])

    private var fileRows: [(node: FileNode, depth: Int)] = []
    private var pane: Pane = .files

    init(session: MockSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

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

        reloadFileRows()
    }

    private func reloadFileRows() {
        fileRows = FileNode.visibleRows(from: FileNode.sampleRoot)
    }
}

extension InspectorViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch pane {
        case .files: fileRows.count
        case .changes: MockChange.samples.count
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell")
            ?? UITableViewCell(style: .value1, reuseIdentifier: "cell")
        switch pane {
        case .files:
            let (node, depth) = fileRows[indexPath.row]
            var config = cell.defaultContentConfiguration()
            config.text = node.name
            config.textProperties.font = .preferredFont(forTextStyle: .subheadline)
            if node.isDirectory {
                config.image = UIImage(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                config.imageProperties.tintColor = .secondaryLabel
            } else {
                config.image = UIImage(systemName: "doc")
                config.imageProperties.tintColor = .systemGray2
            }
            config.imageProperties.maximumSize = CGSize(width: 14, height: 14)
            config.directionalLayoutMargins.leading = CGFloat(depth) * 18 + 12
            cell.contentConfiguration = config
            cell.accessoryView = node.changed ? Self.changedDot() : nil
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

    private static func changedDot() -> UIView {
        let dot = UIView(frame: CGRect(x: 0, y: 0, width: 8, height: 8))
        dot.backgroundColor = .systemBlue
        dot.layer.cornerRadius = 4
        return dot
    }
}
