import TermioShared
import UIKit

/// The Settings ▸ SSH page: the saved-host list plus a Keys entry. Tapping a
/// host opens a terminal session to it; the ⓘ accessory edits it. The list is
/// the manager's home — Add lives in the nav bar, delete is a row swipe.
final class SSHHostListViewController: UITableViewController {
    private enum Section: Int, CaseIterable { case hosts, keys }

    private var storeObserver: NSObjectProtocol?
    /// Short-lived roster socket used only to pull the Mac's `~/.ssh/config`.
    private var importClient: CompanionClient?

    init() { super.init(style: .insetGrouped) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "SSH"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "plus"), menu: UIMenu(children: [
                UIAction(title: "New Host", image: UIImage(systemName: "plus")) { [weak self] _ in
                    self?.addHost()
                },
                UIAction(title: "Import from Mac", image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in
                    self?.importFromMac()
                },
            ])
        )
        storeObserver = NotificationCenter.default.addObserver(
            forName: SSHStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in self?.tableView.reloadData() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }

    private func addHost() {
        navigationController?.pushViewController(SSHHostEditViewController(host: nil), animated: true)
    }

    /// Pull the Mac's `~/.ssh/config` over a throwaway roster socket and import
    /// its hosts. The phone can't read `~/.ssh` itself (sandbox), so the Mac
    /// parses it; imported rows still need a phone-side key or password.
    private func importFromMac() {
        guard let url = CompanionLink.savedURL else {
            present(alert("Pair with your Mac first (Settings ▸ Connectivity)."), animated: true)
            return
        }
        let progress = UIAlertController(
            title: "Importing…", message: "Reading ~/.ssh/config on your Mac", preferredStyle: .alert
        )
        present(progress, animated: true)

        let client = CompanionClient(url: url)
        importClient = client
        var settled = false
        let finish: ([WireSSHHost]?, String?) -> Void = { [weak self] hosts, error in
            guard let self, !settled else { return }
            settled = true
            client.stop()
            importClient = nil
            progress.dismiss(animated: true) {
                if let hosts { self.applyImport(hosts) }
                else { self.present(self.alert(error ?? "Import failed."), animated: true) }
            }
        }
        client.onConnected = { connected in if connected { client.send(.sshConfigHosts) } }
        client.onSSHConfig = { hosts in finish(hosts, nil) }
        client.onError = { reason in finish(nil, reason) }
        client.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { finish(nil, "Couldn't reach your Mac.") }
    }

    private func applyImport(_ wireHosts: [WireSSHHost]) {
        var added = 0
        for wire in wireHosts {
            let duplicate = SSHStore.shared.hosts.contains {
                $0.host == wire.hostName && $0.username == wire.user && $0.port == wire.port
            }
            guard !duplicate else { continue }
            SSHStore.shared.upsertHost(SSHHost(
                label: wire.alias == wire.hostName ? "" : wire.alias,
                host: wire.hostName, port: wire.port, username: wire.user,
                auth: .password, importedFromConfig: true
            ))
            added += 1
        }
        let message = added == 0
            ? "No new hosts to import."
            : "Imported \(added) host\(added == 1 ? "" : "s"). Add a key or password to each before connecting."
        present(alert(message), animated: true)
    }

    private func alert(_ message: String) -> UIAlertController {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        return a
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == Section.hosts.rawValue ? SSHStore.shared.hosts.count : 1
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == Section.hosts.rawValue ? "Hosts" : "Keys"
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == Section.hosts.rawValue, SSHStore.shared.hosts.isEmpty else { return nil }
        return "No saved hosts yet. Tap + to add one."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        switch Section(rawValue: indexPath.section) {
        case .keys:
            cell.textLabel?.text = "Manage Keys"
            cell.imageView?.image = UIImage(systemName: "key")
            cell.imageView?.tintColor = .label
            cell.accessoryType = .disclosureIndicator
        default:
            let host = SSHStore.shared.hosts[indexPath.row]
            cell.textLabel?.text = host.displayName
            let auth: String = switch host.auth {
            case .password: "password"
            case .key: SSHStore.shared.key(for: host)?.label ?? "key"
            }
            let port = host.port == 22 ? "" : ":\(host.port)"
            cell.detailTextLabel?.text = "\(host.username)@\(host.host)\(port) · \(auth)"
            cell.detailTextLabel?.textColor = .secondaryLabel
            cell.imageView?.image = UIImage(systemName: host.importedFromConfig ? "doc.text" : "server.rack")
            cell.imageView?.tintColor = .label
            cell.accessoryType = .detailDisclosureButton
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section) {
        case .keys:
            navigationController?.pushViewController(SSHKeyListViewController(), animated: true)
        default:
            connect(to: SSHStore.shared.hosts[indexPath.row])
        }
    }

    /// The ⓘ accessory edits; a plain tap connects.
    override func tableView(_ tableView: UITableView, accessoryButtonTappedForRowWith indexPath: IndexPath) {
        guard indexPath.section == Section.hosts.rawValue else { return }
        let host = SSHStore.shared.hosts[indexPath.row]
        navigationController?.pushViewController(SSHHostEditViewController(host: host), animated: true)
    }

    override func tableView(
        _ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard indexPath.section == Section.hosts.rawValue else { return nil }
        let host = SSHStore.shared.hosts[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: "Delete") { _, _, done in
            SSHStore.shared.deleteHost(host)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    /// Open a full-screen terminal bridged to this host. Presented over the
    /// Settings sheet; dismissing it returns here.
    private func connect(to host: SSHHost) {
        let terminal = TerminalViewController(sshHost: host)
        terminal.modalPresentationStyle = .fullScreen
        // Presented bare (no nav controller), so the header back button and a
        // connection failure must dismiss rather than pop.
        terminal.onRequestBack = { [weak terminal] in terminal?.dismiss(animated: true) }
        terminal.onClose = { [weak terminal] in terminal?.dismiss(animated: true) }
        present(terminal, animated: true)
    }
}
