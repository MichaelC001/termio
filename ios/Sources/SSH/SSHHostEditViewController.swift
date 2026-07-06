import TermioSSH
import UIKit

/// Add or edit one saved SSH host. A grouped form: connection fields, then an
/// authentication picker (password, or one of the stored keys). Save writes
/// metadata to `SSHStore` and the password to `SSHKeychain`.
final class SSHHostEditViewController: UITableViewController {
    private enum Section: Int, CaseIterable { case connection, auth }

    private let existing: SSHHost?

    private let labelField = SSHHostEditViewController.field(placeholder: "Optional label")
    private let hostField = SSHHostEditViewController.field(placeholder: "example.com")
    private let portField = SSHHostEditViewController.field(placeholder: "22")
    private let userField = SSHHostEditViewController.field(placeholder: "root")
    private let passwordField = SSHHostEditViewController.field(placeholder: "Password")

    /// 0 = password, 1 = key. Drives the auth section's second row.
    private let authControl = UISegmentedControl(items: ["Password", "Key"])
    private var selectedKeyID: UUID?

    init(host: SSHHost?) {
        existing = host
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = existing == nil ? "New Host" : "Edit Host"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .save, target: self, action: #selector(save)
        )

        hostField.keyboardType = .URL
        hostField.autocapitalizationType = .none
        hostField.autocorrectionType = .no
        userField.autocapitalizationType = .none
        userField.autocorrectionType = .no
        portField.keyboardType = .numberPad
        passwordField.isSecureTextEntry = true
        passwordField.autocapitalizationType = .none

        authControl.addTarget(self, action: #selector(authChanged), for: .valueChanged)

        if let host = existing {
            labelField.text = host.label
            hostField.text = host.host
            portField.text = String(host.port)
            userField.text = host.username
            switch host.auth {
            case .password:
                authControl.selectedSegmentIndex = 0
                passwordField.text = SSHKeychain.password(for: host.id)
            case .key(let keyID):
                authControl.selectedSegmentIndex = 1
                selectedKeyID = keyID
            }
        } else {
            authControl.selectedSegmentIndex = 0
        }
    }

    @objc private func authChanged() {
        // The key list may have been the last thing edited; default to the
        // first available key when switching to key auth with none chosen.
        if authControl.selectedSegmentIndex == 1, selectedKeyID == nil {
            selectedKeyID = SSHStore.shared.keys.first?.id
        }
        tableView.reloadSections([Section.auth.rawValue], with: .automatic)
    }

    @objc private func save() {
        let host = (hostField.text ?? "").trimmingCharacters(in: .whitespaces)
        let user = (userField.text ?? "").trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !user.isEmpty else {
            present(alert("Host and username are required."), animated: true)
            return
        }
        let auth: SSHAuthMethod
        if authControl.selectedSegmentIndex == 1 {
            guard let keyID = selectedKeyID else {
                present(alert("Add a key under Keys first, or use password auth."), animated: true)
                return
            }
            auth = .key(keyID: keyID)
        } else {
            auth = .password
        }
        var record = existing ?? SSHHost(host: host, username: user)
        record.label = (labelField.text ?? "").trimmingCharacters(in: .whitespaces)
        record.host = host
        record.port = Int(portField.text ?? "") ?? 22
        record.username = user
        record.auth = auth
        if auth == .password {
            SSHKeychain.setPassword(passwordField.text, for: record.id)
        }
        SSHStore.shared.upsertHost(record)
        navigationController?.popViewController(animated: true)
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .connection: 4
        case .auth: 2
        case .none: 0
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .connection: "Connection"
        case .auth: "Authentication"
        case .none: nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section) {
        case .connection:
            let (title, field) = [
                ("Label", labelField), ("Host", hostField),
                ("Port", portField), ("User", userField),
            ][indexPath.row]
            return fieldCell(title: title, field: field)
        case .auth:
            if indexPath.row == 0 {
                let cell = UITableViewCell()
                cell.selectionStyle = .none
                cell.contentView.addSubview(authControl)
                authControl.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    authControl.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
                    authControl.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                    authControl.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 8),
                    authControl.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -8),
                ])
                return cell
            }
            if authControl.selectedSegmentIndex == 0 {
                return fieldCell(title: "Password", field: passwordField)
            }
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            cell.textLabel?.text = "Key"
            cell.detailTextLabel?.text = selectedKeyID
                .flatMap { id in SSHStore.shared.keys.first { $0.id == id }?.label } ?? "Choose…"
            cell.accessoryType = .disclosureIndicator
            return cell
        case .none:
            return UITableViewCell()
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == Section.auth.rawValue, indexPath.row == 1,
              authControl.selectedSegmentIndex == 1 else { return }
        let keys = SSHStore.shared.keys
        guard !keys.isEmpty else {
            present(alert("No keys yet. Add one under Settings ▸ SSH ▸ Keys."), animated: true)
            return
        }
        let sheet = UIAlertController(title: "Choose Key", message: nil, preferredStyle: .actionSheet)
        for key in keys {
            sheet.addAction(UIAlertAction(title: key.label, style: .default) { [weak self] _ in
                self?.selectedKeyID = key.id
                self?.tableView.reloadSections([Section.auth.rawValue], with: .automatic)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = tableView.cellForRow(at: indexPath)
        present(sheet, animated: true)
    }

    // MARK: - Helpers

    private static func field(placeholder: String) -> UITextField {
        let f = UITextField()
        f.placeholder = placeholder
        f.translatesAutoresizingMaskIntoConstraints = false
        f.textAlignment = .right
        return f
    }

    private func fieldCell(title: String, field: UITextField) -> UITableViewCell {
        let cell = UITableViewCell()
        cell.selectionStyle = .none
        let label = UILabel()
        label.text = title
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        cell.contentView.addSubview(label)
        cell.contentView.addSubview(field)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            field.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 8),
            field.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -8),
        ])
        return cell
    }

    private func alert(_ message: String) -> UIAlertController {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        return a
    }
}
