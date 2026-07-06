import TermioSSH
import UIKit

/// Settings ▸ SSH ▸ Keys: the stored SSH keys. v1 imports an unencrypted
/// OpenSSH Ed25519 private key (validated by `SSHKeyParser`); the private bytes
/// go to the Keychain, only the label + type stay in `SSHStore`. Generation and
/// other algorithms are deferred.
final class SSHKeyListViewController: UITableViewController {
    private var storeObserver: NSObjectProtocol?

    init() { super.init(style: .insetGrouped) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Keys"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add, target: self, action: #selector(importKey)
        )
        storeObserver = NotificationCenter.default.addObserver(
            forName: SSHStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in self?.tableView.reloadData() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }

    @objc private func importKey() {
        navigationController?.pushViewController(SSHKeyImportViewController(), animated: true)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        SSHStore.shared.keys.count
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        SSHStore.shared.keys.isEmpty ? "No keys yet. Tap + to import an OpenSSH Ed25519 private key." : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let key = SSHStore.shared.keys[indexPath.row]
        cell.textLabel?.text = key.label
        cell.detailTextLabel?.text = key.type.displayName
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.imageView?.image = UIImage(systemName: "key.fill")
        cell.imageView?.tintColor = .label
        cell.selectionStyle = .none
        return cell
    }

    override func tableView(
        _ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        let key = SSHStore.shared.keys[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: "Delete") { _, _, done in
            SSHStore.shared.deleteKey(key)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }
}

/// Paste-an-Ed25519-key form. Validates with `SSHKeyParser` before storing, so
/// a bad or passphrase-protected key is rejected with a clear reason rather
/// than failing silently at connect time.
final class SSHKeyImportViewController: UIViewController {
    private let labelField = UITextField()
    private let keyView = UITextView()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Import Key"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Import", style: .done, target: self, action: #selector(save)
        )

        labelField.placeholder = "Label (e.g. work laptop)"
        labelField.borderStyle = .roundedRect
        labelField.autocapitalizationType = .none
        labelField.translatesAutoresizingMaskIntoConstraints = false

        keyView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        keyView.autocapitalizationType = .none
        keyView.autocorrectionType = .no
        keyView.layer.cornerRadius = 8
        keyView.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        keyView.translatesAutoresizingMaskIntoConstraints = false

        let hint = UILabel()
        hint.text = "Paste an unencrypted OpenSSH private key\n(-----BEGIN OPENSSH PRIVATE KEY-----)."
        hint.numberOfLines = 0
        hint.font = .preferredFont(forTextStyle: .footnote)
        hint.textColor = .secondaryLabel
        hint.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(labelField)
        view.addSubview(hint)
        view.addSubview(keyView)
        let margins = view.layoutMarginsGuide
        NSLayoutConstraint.activate([
            labelField.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            labelField.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            labelField.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            hint.topAnchor.constraint(equalTo: labelField.bottomAnchor, constant: 12),
            hint.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            keyView.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 8),
            keyView.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            keyView.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            keyView.heightAnchor.constraint(equalToConstant: 240),
        ])
    }

    @objc private func save() {
        let text = keyView.text ?? ""
        do {
            _ = try SSHKeyParser.parseED25519(openSSHPrivateKey: text)
        } catch {
            let a = UIAlertController(title: "Can't import key",
                                      message: (error as? SSHKeyError)?.description ?? error.localizedDescription,
                                      preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "OK", style: .default))
            present(a, animated: true)
            return
        }
        let label = (labelField.text ?? "").trimmingCharacters(in: .whitespaces)
        let record = SSHKeyRecord(label: label.isEmpty ? "Ed25519 key" : label, type: .ed25519)
        SSHKeychain.setPrivateKey(text, for: record.id)
        SSHStore.shared.upsertKey(record)
        navigationController?.popViewController(animated: true)
    }
}
