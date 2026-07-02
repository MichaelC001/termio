import GhosttyTerminal
import GhosttyTheme
import ShellCraftKit
import TermioSSH
import TermioShared
import UIKit

/// Full-screen terminal for one session — the bundled demo sandbox shell for
/// mock sessions, or a live SSH connection. The right screen edge slides in
/// the inspector drawer (file tree + changes); the terminal keeps rendering,
/// dimmed, behind it.
final class TerminalViewController: UIViewController {
    private enum Backend {
        case demoShell
        case ssh(SSHConfig)
    }

    private let session: MockSession
    private let backend: Backend

    private lazy var terminalView = TerminalView(frame: .zero)
    private lazy var shellSession = ShellSession(shell: defaultSandboxShell)
    private var sshClient: SSHTerminalClient?
    private var sshTerminalSession: InMemoryTerminalSession?
    private let statusLabel = UILabel()
    private lazy var controller = TerminalController(theme: Self.terminalTheme()) { builder in
        builder.withBackgroundOpacity(0)
    }

    // Drawer
    private lazy var inspectorNav = UINavigationController(
        rootViewController: InspectorViewController(session: session)
    )
    private let dimView = UIControl()
    private var drawerOpen = false
    private var drawerWidth: CGFloat { min(view.bounds.width * 0.85, 420) }

    init(session: MockSession) {
        self.session = session
        backend = .demoShell
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    init(sshConfig: SSHConfig) {
        session = MockSession(
            title: "\(sshConfig.username)@\(sshConfig.host)",
            project: "ssh", agent: .terminal, status: .idle,
            subtitle: "", time: ""
        )
        backend = .ssh(sshConfig)
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    deinit {
        sshClient?.stop()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The terminal page is always dark (Catppuccin Mocha); forcing the
        // trait keeps nav-bar text and the drawer legible over the surface.
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .black
        configureNavigationBar()
        configureTerminal()
        configureDrawer()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !drawerOpen { terminalView.becomeFirstResponder() }
        switch backend {
        case .demoShell:
            shellSession.start()
        case .ssh:
            sshClient?.start()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        terminalView.fitToSize()
        layoutDrawer()
    }

    // MARK: - Navigation bar

    private func configureNavigationBar() {
        let titleLabel = UILabel()
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.text = session.title
        statusLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.textColor = .secondaryLabel
        statusLabel.text = switch backend {
        case .demoShell: "\(session.agent.rawValue) · \(session.time)"
        case .ssh: "连接中…"
        }
        let stack = UIStackView(arrangedSubviews: [titleLabel, statusLabel])
        stack.axis = .vertical
        stack.alignment = .center
        navigationItem.titleView = stack

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "sidebar.trailing"),
            primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                setDrawer(open: !drawerOpen, animated: true)
            }
        )
    }

    // MARK: - Terminal

    private func configureTerminal() {
        terminalView.delegate = self
        terminalView.configuration = TerminalSurfaceOptions(
            backend: .inMemory(makeTerminalSession())
        )
        terminalView.controller = controller
        terminalView.backgroundColor = .clear
        terminalView.isOpaque = false
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
    }

    /// Demo sessions use ShellCraftKit's sandbox shell; SSH sessions bridge
    /// the surface to the SSH channel — keystrokes out, remote bytes in,
    /// grid resize → SSH window-change.
    private func makeTerminalSession() -> InMemoryTerminalSession {
        switch backend {
        case .demoShell:
            return shellSession.terminalSession
        case .ssh(let config):
            let client = SSHTerminalClient(config: config)
            let terminalSession = InMemoryTerminalSession(
                write: { [weak client] data in client?.send(data) },
                resize: { [weak client] viewport in
                    client?.resize(cols: Int(viewport.columns), rows: Int(viewport.rows))
                }
            )
            client.onOutput = { [weak terminalSession] data in
                terminalSession?.receive(data)
            }
            client.onState = { [weak self] state in
                self?.sshStateChanged(state)
            }
            sshClient = client
            sshTerminalSession = terminalSession
            return terminalSession
        }
    }

    private func sshStateChanged(_ state: SSHClientState) {
        switch state {
        case .idle:
            break
        case .connecting:
            statusLabel.text = "连接中…"
        case .connected:
            statusLabel.text = "已连接"
        case .failed(let reason):
            statusLabel.text = "连接失败"
            let alert = UIAlertController(title: "SSH 连接失败", message: reason, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default) { [weak self] _ in
                self?.navigationController?.popViewController(animated: true)
            })
            present(alert, animated: true)
        case .closed:
            statusLabel.text = "已断开"
            sshTerminalSession?.finish(exitCode: 0, runtimeMilliseconds: 0)
        }
    }

    private static func terminalTheme() -> TerminalTheme {
        let light = GhosttyThemeCatalog.theme(named: "Catppuccin Latte")?
            .toTerminalConfiguration() ?? .alabaster
        let dark = GhosttyThemeCatalog.theme(named: "Catppuccin Mocha")?
            .toTerminalConfiguration() ?? .afterglow
        return TerminalTheme(light: light, dark: dark)
    }

    // MARK: - Drawer

    private func configureDrawer() {
        dimView.backgroundColor = .black
        dimView.alpha = 0
        dimView.isUserInteractionEnabled = false
        dimView.addAction(UIAction { [weak self] _ in
            self?.setDrawer(open: false, animated: true)
        }, for: .touchUpInside)
        view.addSubview(dimView)

        addChild(inspectorNav)
        view.addSubview(inspectorNav.view)
        inspectorNav.didMove(toParent: self)
        inspectorNav.view.layer.shadowColor = UIColor.black.cgColor
        inspectorNav.view.layer.shadowOpacity = 0.3
        inspectorNav.view.layer.shadowRadius = 12
        inspectorNav.view.layer.shadowOffset = CGSize(width: -4, height: 0)

        // Only the screen's right edge opens the drawer — anything inside the
        // surface belongs to the terminal (scroll, selection, mouse reporting).
        let edgePan = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgePan(_:)))
        edgePan.edges = .right
        view.addGestureRecognizer(edgePan)

        // Swiping the open drawer rightwards closes it.
        let closePan = UIPanGestureRecognizer(target: self, action: #selector(handleClosePan(_:)))
        inspectorNav.view.addGestureRecognizer(closePan)
    }

    private func layoutDrawer(progress: CGFloat? = nil) {
        let openness = progress ?? (drawerOpen ? 1 : 0)
        let x = view.bounds.width - drawerWidth * openness
        inspectorNav.view.frame = CGRect(x: x, y: 0, width: drawerWidth, height: view.bounds.height)
        dimView.frame = view.bounds
        dimView.alpha = 0.15 * openness
    }

    func setDrawer(open: Bool, animated: Bool) {
        drawerOpen = open
        dimView.isUserInteractionEnabled = open
        if open { terminalView.resignFirstResponder() }
        let animations = { self.layoutDrawer() }
        if animated {
            UIView.animate(withDuration: 0.35, delay: 0,
                           usingSpringWithDamping: 0.9, initialSpringVelocity: 0,
                           animations: animations)
        } else {
            animations()
        }
        if !open { terminalView.becomeFirstResponder() }
    }

    @objc private func handleEdgePan(_ pan: UIScreenEdgePanGestureRecognizer) {
        let translation = -pan.translation(in: view).x
        let progress = max(0, min(1, translation / drawerWidth))
        switch pan.state {
        case .changed:
            layoutDrawer(progress: progress)
            dimView.isUserInteractionEnabled = true
        case .ended, .cancelled:
            let fling = -pan.velocity(in: view).x > 300
            setDrawer(open: fling || progress > 0.4, animated: true)
        default:
            break
        }
    }

    @objc private func handleClosePan(_ pan: UIPanGestureRecognizer) {
        let translation = pan.translation(in: view).x
        let progress = max(0, min(1, 1 - translation / drawerWidth))
        switch pan.state {
        case .changed:
            layoutDrawer(progress: progress)
        case .ended, .cancelled:
            let fling = pan.velocity(in: view).x > 300
            setDrawer(open: !(fling || progress < 0.6), animated: true)
        default:
            break
        }
    }
}

// MARK: - Terminal callbacks

extension TerminalViewController: TerminalSurfaceTitleDelegate, TerminalSurfaceCloseDelegate {
    func terminalDidChangeTitle(_ title: String) {
        // Session name stays; the shell title is secondary on mobile.
    }

    func terminalDidClose(processAlive _: Bool) {
        navigationController?.popViewController(animated: true)
    }
}
