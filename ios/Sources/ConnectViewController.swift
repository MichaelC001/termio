import TermioSSH
import UIKit

/// SSH connect form. Host/port/user persist in UserDefaults; the password
/// stays in memory only (key auth and a Keychain store come later).
final class ConnectViewController: UIViewController {
    var onConnect: ((SSHConfig) -> Void)?

    private let hostField = ConnectViewController.field("主机 (如 192.168.1.10)", key: "ssh.host")
    private let portField = ConnectViewController.field("端口", key: "ssh.port", fallback: "22")
    private let userField = ConnectViewController.field("用户名", key: "ssh.user")
    private let passwordField: UITextField = {
        let field = ConnectViewController.field("密码", key: nil)
        field.isSecureTextEntry = true
        return field
    }()
    private let commandField = ConnectViewController.field(
        "命令(可选,如 tmux new -A -s termio)", key: "ssh.command"
    )

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "SSH 连接"
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )

        let connectButton = UIButton(configuration: .borderedProminent())
        connectButton.setTitle("连接", for: .normal)
        connectButton.addAction(UIAction { [weak self] _ in self?.connect() }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            hostField, portField, userField, passwordField, commandField, connectButton,
        ])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
    }

    private func connect() {
        guard let host = hostField.text, !host.isEmpty,
              let user = userField.text, !user.isEmpty
        else { return }
        let defaults = UserDefaults.standard
        defaults.set(host, forKey: "ssh.host")
        defaults.set(portField.text, forKey: "ssh.port")
        defaults.set(user, forKey: "ssh.user")
        defaults.set(commandField.text, forKey: "ssh.command")

        let command = commandField.text?.trimmingCharacters(in: .whitespaces)
        let config = SSHConfig(
            host: host,
            port: Int(portField.text ?? "") ?? 22,
            username: user,
            password: passwordField.text,
            command: (command?.isEmpty == false) ? command : nil
        )
        let onConnect = onConnect
        dismiss(animated: true) { onConnect?(config) }
    }

    private static func field(_ placeholder: String, key: String?, fallback: String? = nil) -> UITextField {
        let field = UITextField()
        field.placeholder = placeholder
        field.borderStyle = .roundedRect
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        if let key, let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty {
            field.text = saved
        } else {
            field.text = fallback
        }
        return field
    }
}
