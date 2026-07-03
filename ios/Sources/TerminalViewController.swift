import GhosttyTerminal
import GhosttyTheme
import PhotosUI
import ShellCraftKit
import TermioSSH
import TermioShared
import UIKit
import UniformTypeIdentifiers

/// Full-screen terminal for one session — the bundled demo sandbox shell for
/// mock sessions, or a live SSH connection. The right screen edge slides in
/// the inspector drawer (file tree + changes); the terminal keeps rendering,
/// dimmed, behind it.
final class TerminalViewController: UIViewController {
    private enum Backend {
        case demoShell
        case ssh(SSHConfig)
        case companion(URL)
    }

    private let session: MockSession
    private let backend: Backend

    /// Set by RootContainerViewController: the session DIED (exit or lost
    /// connection), as opposed to the user navigating back, which parks the
    /// screen in the container's keep-alive cache.
    var onClose: (() -> Void)?

    private lazy var terminalView = DisplayTerminalView(frame: .zero)
    private let composerBar = ComposerBar()
    /// Last size actually sent to the engine + the pending coalesced refit —
    /// see viewDidLayoutSubviews for why resizes are rationed.
    private var lastFittedSize: CGSize = .zero
    private var fitDebounce: DispatchWorkItem?
    private lazy var shellSession = ShellSession(shell: defaultSandboxShell)
    private var sshClient: SSHTerminalClient?
    private var sshTerminalSession: InMemoryTerminalSession?
    private var companion: CompanionTransport?
    private var companionSession: InMemoryTerminalSession?
    private let headerBar = UIStackView()
    private let contextLabel = UILabel()
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private var surfaceConfigured = false
    private var backendStarted = false
    private var settingsObserver: NSObjectProtocol?
    private var uploadClient: CompanionClient?
    private var restylePump: Timer?
    private lazy var controller = TerminalController(
        theme: Self.terminalTheme(),
        terminalConfiguration: Self.appearanceConfiguration()
    )

    // Drawer
    private lazy var inspectorNav = UINavigationController(
        rootViewController: InspectorViewController(
            session: session,
            companionURL: {
                if case .companion(let url) = backend { url } else { nil }
            }()
        )
    )
    private let dimView = UIControl()
    private var drawerOpen = false
    /// Direction the surface pan locked at its start: rightward = back to
    /// the list, leftward = drag the drawer.
    private var openPanGoesBack = false
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

    /// A companion terminal: bridges a real Mac session's PTY when `session`
    /// carries a roster id, else streams whatever the server serves (PoC mode).
    init(companionURL: URL, session: MockSession? = nil) {
        self.session = session ?? MockSession(
            title: companionURL.host ?? "companion",
            project: "companion", agent: .terminal, status: .idle,
            subtitle: "", time: ""
        )
        backend = .companion(companionURL)
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    deinit {
        sshClient?.stop()
        companion?.stop()
        uploadClient?.stop()
        restylePump?.invalidate()
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The page trait comes from the window's app-wide Appearance override
        // (set in AppDelegate), and the backdrop is the active theme's
        // background: the surface renders with zero background opacity, so
        // this view is its canvas.
        view.backgroundColor = Self.backdropColor()
        configureHeader()
        configureTerminal()
        configureDrawer()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: MobileSettings.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyAppearanceSettings() }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Swipe-from-left-edge pop stays available with the bar hidden.
        navigationController?.interactivePopGestureRecognizer?.delegate = nil
        // The surface is configured only now, with the view guaranteed to be
        // in a window: its font metrics bake in the display scale at creation,
        // and off-window the scale resolution falls back and sometimes loses —
        // the intermittent third-size rendering. On-window it's always right.
        if !surfaceConfigured {
            surfaceConfigured = true
            terminalView.configuration = TerminalSurfaceOptions(
                backend: .inMemory(makeTerminalSession())
            )
            terminalView.fitToSize()
            lastFittedSize = terminalView.bounds.size
        }
        if !drawerOpen { focusInput() }
        // Once per lifetime: a parked terminal re-entering the screen (the
        // container's keep-alive cache) must not open a second connection —
        // its backend has been streaming the whole time.
        if !backendStarted {
            backendStarted = true
            switch backend {
            case .demoShell:
                shellSession.start()
            case .ssh:
                sshClient?.start()
            case .companion:
                companion?.start()
            }
        } else if case .companion = backend {
            // Re-entering a parked session claims the PTY's winsize back —
            // the Mac may own it, and this view's size didn't change, so no
            // layout pass would re-send the grid.
            companion?.reassertGrid()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutDrawer()
        // Refit only when the surface's size actually changed, and coalesce
        // the per-frame passes of keyboard/composer animations into one call
        // after the size settles. Every `setSize` can deadlock against the
        // byte stream inside libghostty-spm 1.2.8 (`receive` holds the
        // session lock across a blocking write while the io thread's resize
        // ack wants the same lock — the app-freeze bug), so send as few
        // resizes as possible until that's fixed upstream.
        let size = terminalView.bounds.size
        guard size != lastFittedSize else { return }
        fitDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            lastFittedSize = terminalView.bounds.size
            terminalView.fitToSize()
        }
        fitDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    // MARK: - Header

    /// A compact stand-in for the navigation bar: back · [context/title] ·
    /// drawer, hugging the status bar so no vertical space is spent on the
    /// floating system bar. Line 1: where you are (project · branch). Line 2:
    /// what the session is doing (live from the agent's OSC titles). While
    /// the link is in doubt the status line stands in for the context line.
    private func configureHeader() {
        contextLabel.font = .preferredFont(forTextStyle: .caption2)
        contextLabel.textColor = .secondaryLabel
        contextLabel.text = [session.project, session.branch]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.text = session.title
        statusLabel.font = .preferredFont(forTextStyle: .caption2)
        statusLabel.textColor = .secondaryLabel
        statusLabel.text = switch backend {
        case .demoShell: "\(session.agent.rawValue) · \(session.time)"
        case .ssh, .companion: "Connecting…"
        }
        contextLabel.isHidden = contextLabel.text?.isEmpty ?? true
        switch backend {
        case .ssh, .companion: contextLabel.isHidden = true // until connected
        case .demoShell: break
        }

        let titles = UIStackView(arrangedSubviews: [contextLabel, titleLabel, statusLabel])
        titles.axis = .vertical
        titles.alignment = .center
        titles.spacing = 0

        headerBar.axis = .horizontal
        headerBar.alignment = .center
        headerBar.spacing = 4
        // The Messages-conversation header: back chevron to the inbox, the
        // title stack centered (balanced by an equal-width spacer). On
        // iOS 26 the chevron rides a circular Liquid Glass button, matching
        // the system back button over content; earlier it stays flat.
        let back = UIButton(type: .system)
        // Telegram-scale: an 18pt semibold chevron on a 44pt target, not the
        // 15pt default that reads like a caption glyph.
        back.applyGlassSymbol("chevron.left", pointSize: 18)
        back.accessibilityIdentifier = "terminal.back"
        back.tintColor = .label
        back.addAction(UIAction { [weak self] _ in
            self?.goBack()
        }, for: .touchUpInside)
        let balance = UIView()
        headerBar.addArrangedSubview(back)
        headerBar.addArrangedSubview(titles)
        headerBar.addArrangedSubview(balance)
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerBar)
        NSLayoutConstraint.activate([
            headerBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            headerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            headerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            back.widthAnchor.constraint(equalToConstant: 44),
            back.heightAnchor.constraint(equalToConstant: 44),
            balance.widthAnchor.constraint(equalToConstant: 44),
            balance.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    /// Back to the inbox: the screen parks in the container's keep-alive
    /// cache — the session stays live, unlike `close()`.
    private func goBack() {
        navigationController?.popViewController(animated: true)
    }

    /// The session is over (child exited, connection lost): tell the
    /// container so the parked screen is dropped, or pop if unowned.
    private func close() {
        if let onClose { onClose() } else { navigationController?.popViewController(animated: true) }
    }

    /// The drawer steals keyboard focus while open and hands it back when
    /// it slides away.
    private func setTerminalFocused(_ focused: Bool) {
        if focused {
            focusInput()
        } else {
            composerBar.unfocus()
        }
    }

    /// The composer is the app's single input.
    private func focusInput() {
        composerBar.focus()
    }

    // MARK: - Terminal

    private func configureTerminal() {
        terminalView.delegate = self
        // Scrolling the terminal is reading; give the rows back to content.
        // The draft survives — unfocus only drops the keyboard, and tapping
        // the composer field refocuses natively.
        terminalView.onScrollGesture = { [weak self] in self?.composerBar.unfocus() }
        // configuration (and thus the surface) is deliberately deferred to
        // viewDidAppear — see the display-scale note there.
        terminalView.controller = controller
        terminalView.backgroundColor = .clear
        terminalView.isOpaque = false
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(terminalView)

        composerBar.onSend = { [weak self] text in self?.sendComposedPrompt(text) }
        composerBar.onTerminalKey = { [weak self] payload in self?.terminalView.send(payload) }
        composerBar.onAttach = { [weak self] in self?.presentAttachOptions() }
        composerBar.slashCommands = Self.slashCatalog(for: session.agent)
        if case .companion = backend, session.projectRosterID != nil {
            composerBar.setAttachAvailable(true)
        }
        composerBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(composerBar)

        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            terminalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: composerBar.topAnchor),
            composerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composerBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
    }

    // MARK: - Composer

    /// One atomic PTY write per prompt. Multiline drafts ride inside a
    /// bracketed paste so the agent's TUI treats embedded newlines as part
    /// of the text, not as early submits; the trailing CR is the send.
    private func sendComposedPrompt(_ text: String) {
        var payload = text
        if payload.contains("\n") {
            payload = "\u{1B}[200~" + payload + "\u{1B}[201~"
        }
        terminalView.send(Data((payload + "\r").utf8))
    }

    // MARK: - Attachments

    private func presentAttachOptions() {
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Photo Library", style: .default) { [weak self] _ in
            self?.presentPhotoPicker()
        })
        sheet.addAction(UIAlertAction(title: "Choose File", style: .default) { [weak self] _ in
            self?.presentDocumentPicker()
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
    }

    private func presentPhotoPicker() {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func presentDocumentPicker() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = self
        present(picker, animated: true)
    }

    /// Pushes the picked bytes to the Mac; the reply's absolute path lands
    /// in the draft — Moshi's flow (agents take file paths), but over the
    /// companion link instead of SCP.
    private func upload(name: String, data: Data) {
        guard case .companion(let url) = backend,
              let projectID = session.projectRosterID else { return }
        guard data.count <= 8 << 20 else {
            presentAlert("File too large", "Attachments are capped at 8 MB.")
            return
        }
        composerBar.setAttachBusy(true)
        if uploadClient == nil {
            let client = CompanionClient(url: url)
            client.onUploaded = { [weak self] path in
                self?.composerBar.setAttachBusy(false)
                self?.composerBar.insertDraft(path)
            }
            client.onError = { [weak self] message in
                self?.composerBar.setAttachBusy(false)
                self?.presentAlert("Upload failed", message)
            }
            client.start()
            uploadClient = client
        }
        uploadClient?.send(
            .upload(projectID: projectID, name: name, base64: data.base64EncodedString())
        )
    }

    private func presentAlert(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    /// The "/" panel's catalog — curated per agent CLI, prefix-filtered as
    /// the user types (the full lists live in each CLI's /help).
    private static func slashCatalog(for agent: AgentKind) -> [SlashCommand] {
        switch agent {
        case .claude:
            return [
                SlashCommand(name: "clear", detail: "Start a fresh conversation"),
                SlashCommand(name: "compact", detail: "Compact the context window"),
                SlashCommand(name: "resume", detail: "Resume a past session"),
                SlashCommand(name: "model", detail: "Switch the model"),
                SlashCommand(name: "permissions", detail: "View or change permissions"),
                SlashCommand(name: "memory", detail: "Edit memory files"),
                SlashCommand(name: "status", detail: "Session status and context"),
                SlashCommand(name: "cost", detail: "Token usage for this session"),
                SlashCommand(name: "init", detail: "Generate CLAUDE.md"),
                SlashCommand(name: "help", detail: "All commands"),
            ]
        case .codex:
            return [
                SlashCommand(name: "model", detail: "Switch the model"),
                SlashCommand(name: "review", detail: "Review current changes"),
                SlashCommand(name: "compact", detail: "Compact the context window"),
                SlashCommand(name: "new", detail: "Start a fresh conversation"),
                SlashCommand(name: "diff", detail: "Show the working diff"),
                SlashCommand(name: "status", detail: "Session status"),
            ]
        default:
            return []
        }
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

        case .companion(let url):
            let transport = CompanionTransport(url: url, attachSessionID: session.rosterID)
            let terminalSession = InMemoryTerminalSession(
                write: { [weak transport] data in transport?.send(data) },
                resize: { [weak transport] viewport in
                    transport?.resize(cols: Int(viewport.columns), rows: Int(viewport.rows))
                }
            )
            transport.onOutput = { [weak terminalSession] data in
                terminalSession?.receive(data)
            }
            transport.onState = { [weak self] state in
                self?.companionStateChanged(state)
            }
            companion = transport
            companionSession = terminalSession
            return terminalSession
        }
    }

    private func companionStateChanged(_ state: CompanionTransport.State) {
        // The status line earns its place only while the link is in doubt;
        // once connected it yields to the project · branch context line.
        statusLabel.isHidden = false
        contextLabel.isHidden = true
        switch state {
        case .connecting:
            statusLabel.text = "Connecting…"
        case .reconnecting:
            statusLabel.text = "Reconnecting…"
        case .connected:
            statusLabel.isHidden = true
            contextLabel.isHidden = contextLabel.text?.isEmpty ?? true
        case .failed(let reason):
            statusLabel.text = "Connection failed"
            let alert = UIAlertController(title: "Companion connection failed", message: reason, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
                self?.close()
            })
            present(alert, animated: true)
        case .closed:
            statusLabel.text = "Disconnected"
            companionSession?.finish(exitCode: 0, runtimeMilliseconds: 0)
        }
    }

    private func sshStateChanged(_ state: SSHClientState) {
        statusLabel.isHidden = false
        contextLabel.isHidden = true
        switch state {
        case .idle:
            break
        case .connecting:
            statusLabel.text = "Connecting…"
        case .connected:
            statusLabel.isHidden = true
            contextLabel.isHidden = contextLabel.text?.isEmpty ?? true
        case .failed(let reason):
            statusLabel.text = "Connection failed"
            let alert = UIAlertController(title: "SSH connection failed", message: reason, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
                self?.close()
            })
            present(alert, animated: true)
        case .closed:
            statusLabel.text = "Disconnected"
            sshTerminalSession?.finish(exitCode: 0, runtimeMilliseconds: 0)
        }
    }

    /// The light/dark pair from settings; libghostty switches slots as the
    /// page's effective appearance changes (system mode tracks the device).
    private static func terminalTheme() -> TerminalTheme {
        let settings = MobileSettings.shared
        let light = GhosttyThemeCatalog.theme(named: settings.lightThemeName)?
            .toTerminalConfiguration() ?? .alabaster
        let dark = GhosttyThemeCatalog.theme(named: settings.darkThemeName)?
            .toTerminalConfiguration() ?? .afterglow
        return TerminalTheme(light: light, dark: dark)
    }

    /// A dynamic color mirroring the active theme slot's background, so the
    /// canvas behind the transparent surface always matches — including the
    /// unpainted band under the keyboard guide and the safe areas.
    private static func backdropColor() -> UIColor {
        UIColor { traits in
            let settings = MobileSettings.shared
            let dark = traits.userInterfaceStyle == .dark
            let name = dark ? settings.darkThemeName : settings.lightThemeName
            return GhosttyThemeCatalog.theme(named: name)
                .flatMap { UIColor(ghosttyHex: $0.background) }
                ?? (dark ? .black : .white)
        }
    }

    /// The settings-driven half of the surface config — the single place the
    /// appearance keys are named, so creation and the live re-style path
    /// can't drift apart (same rule as the Mac app's applyAppearance).
    private static func appearanceConfiguration() -> TerminalConfiguration {
        TerminalConfiguration { builder in
            builder.withBackgroundOpacity(0)
            builder.withFontSize(Float(MobileSettings.shared.fontSize))
            builder.withWindowPaddingX(8)
        }
    }

    /// Restyles the live surface in place after a settings change, then
    /// drives the renderer for a short window: without PTY output nothing
    /// else wakes the surface, and the new look would wait for the next
    /// byte to arrive.
    private func applyAppearanceSettings() {
        // Re-assigned (not just relied on as dynamic) so a theme-name change
        // busts UIKit's resolved-color cache without a trait flip.
        view.backgroundColor = Self.backdropColor()
        guard surfaceConfigured else { return }
        controller.setTheme(Self.terminalTheme())
        controller.setTerminalConfiguration(Self.appearanceConfiguration())
        terminalView.fitToSize()
        restylePump?.invalidate()
        let started = Date()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.controller.tick()
                if Date().timeIntervalSince(started) > 0.5 { timer.invalidate() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        restylePump = timer
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

        // A leftward drag anywhere on the surface pulls the drawer out
        // (ChatGPT's sidebar gesture, mirrored). The delegate keeps drags
        // that belong to controls, scrollers, and the composer out of it,
        // and the direction check leaves vertical scrollback alone.
        let openPan = UIPanGestureRecognizer(target: self, action: #selector(handleOpenPan(_:)))
        openPan.delegate = self
        openPan.maximumNumberOfTouches = 1 // two fingers stay pinch-zoom
        view.addGestureRecognizer(openPan)

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
        if open { setTerminalFocused(false) }
        let animations = { self.layoutDrawer() }
        if animated {
            UIView.animate(withDuration: 0.35, delay: 0,
                           usingSpringWithDamping: 0.9, initialSpringVelocity: 0,
                           animations: animations)
        } else {
            animations()
        }
        if !open { focusInput() }
    }

    /// One pan, two meanings, split by the direction it starts in (the
    /// delegate only lets clearly horizontal drags through): leftward drags
    /// the drawer out, rightward goes back to the session list — the same
    /// swipe Messages answers with a pop to the inbox.
    @objc private func handleOpenPan(_ pan: UIPanGestureRecognizer) {
        if pan.state == .began {
            openPanGoesBack = pan.velocity(in: view).x > 0
        }
        if openPanGoesBack {
            guard pan.state == .ended else { return }
            let fling = pan.velocity(in: view).x > 300
            if fling || pan.translation(in: view).x > view.bounds.width * 0.3 {
                goBack()
            }
            return
        }
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

// MARK: - Drawer pan gating

extension TerminalViewController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let pan = gesture as? UIPanGestureRecognizer, pan.view === view else { return true }
        guard !drawerOpen else { return false }
        let velocity = pan.velocity(in: view)
        // Clearly horizontal either way — vertical drags are the terminal's
        // scrollback. Leftward opens the drawer; rightward pops to the list,
        // so it only engages when there is a stack to pop.
        guard abs(velocity.x) > abs(velocity.y) else { return false }
        return velocity.x < 0 || navigationController?.viewControllers.count ?? 0 > 1
    }

    func gestureRecognizer(
        _ gesture: UIGestureRecognizer, shouldReceive touch: UITouch
    ) -> Bool {
        guard gesture.view === view else { return true }
        // Horizontal drags inside controls, scrollers (the composer's text
        // view), or the drawer itself mean something else.
        var candidate = touch.view
        while let current = candidate, current !== view {
            if current is UIControl || current is UIScrollView { return false }
            if current === composerBar || current === inspectorNav.view { return false }
            candidate = current.superview
        }
        return true
    }

    func gestureRecognizer(
        _ gesture: UIGestureRecognizer,
        shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
        // The surface's own pans (touch scroll, pointer selection) recognize
        // any drag instantly and would win every touch that starts over the
        // terminal — the drawer could then only open from the header. Making
        // them wait for this pan costs vertical scrolling only the ~10pt it
        // takes the direction check to bow out.
        gesture.view === view && other.view is UITerminalView
    }
}

// MARK: - Terminal callbacks

// MARK: - Attachment pickers

extension TerminalViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider,
              provider.canLoadObject(ofClass: UIImage.self) else { return }
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            guard let image = object as? UIImage,
                  let data = Self.jpegPayload(from: image) else { return }
            DispatchQueue.main.async { self?.upload(name: "photo.jpg", data: data) }
        }
    }

    /// Downscales to ≤ 2048 px JPEG — plenty for an agent to read, small
    /// enough to ride one WebSocket frame.
    private static func jpegPayload(from image: UIImage) -> Data? {
        let maxSide: CGFloat = 2048
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.8)
    }
}

extension TerminalViewController: UIDocumentPickerDelegate {
    func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first, let data = try? Data(contentsOf: url) else { return }
        upload(name: url.lastPathComponent, data: data)
    }
}

extension TerminalViewController: TerminalSurfaceTitleDelegate, TerminalSurfaceCloseDelegate {
    func terminalDidChangeTitle(_ title: String) {
        // The agent's OSC title rides the byte stream (Claude Code updates it
        // as it works), so the bar tracks what the session is doing live.
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in self?.titleLabel.text = trimmed }
    }

    func terminalDidClose(processAlive _: Bool) {
        close()
    }
}

// MARK: - Display-only surface

/// The terminal renders, scrolls, and selects — it never takes the keyboard.
/// The composer is the app's single input (the Moshi shape): prompts and
/// menu answers are whole atomic writes, not keystroke streams, so there is
/// no second input UI to learn and no raw-keys mode to toggle.
private final class DisplayTerminalView: UITerminalView {
    override var canBecomeFirstResponder: Bool { false }

    /// Fired when a finger scroll begins on the surface. The controller uses
    /// it to dismiss the composer keyboard — the chat convention (ChatGPT,
    /// Messages): scrolling back through output means reading, so the screen
    /// yields to content; tapping the composer brings the keyboard back.
    var onScrollGesture: (() -> Void)?
    private var scrollHookInstalled = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        installScrollHookIfNeeded()
    }

    /// The wrapper's own pan-to-scroll recognizer (direct touches, single
    /// finger) gains a second target so scroll-begin is observable without
    /// a competing recognizer.
    private func installScrollHookIfNeeded() {
        guard !scrollHookInstalled else { return }
        let directTouch = NSNumber(value: UITouch.TouchType.direct.rawValue)
        guard let pan = gestureRecognizers?
            .compactMap({ $0 as? UIPanGestureRecognizer })
            .first(where: {
                !($0 is UIScreenEdgePanGestureRecognizer)
                    && $0.maximumNumberOfTouches == 1
                    && $0.allowedTouchTypes == [directTouch]
            })
        else { return }
        pan.addTarget(self, action: #selector(scrollGestureChanged(_:)))
        scrollHookInstalled = true
    }

    @objc private func scrollGestureChanged(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { onScrollGesture?() }
    }

    /// Raw bytes straight to the PTY — every termio backend is in-memory.
    /// Prompts and terminal keys are whole writes, the same delivery a
    /// keyboard's keys would use.
    func send(_ data: Data) {
        guard case let .inMemory(session) = configuration.backend else { return }
        session.sendInput(data)
    }

    /// Ghostty's embedded surface starts its mouse position at (-1,-1) and
    /// only `ghostty_surface_mouse_pos` moves it — which the wrapper's touch
    /// path never calls. Mouse-reporting TUIs (Claude Code sets ?1003/?1006)
    /// then never receive the scroll gesture: the core encodes wheel events
    /// at the last mouse position and silently drops any event that falls
    /// outside the viewport. Seeding the position from every direct touch
    /// makes the wrapper's own pan-to-scroll reporting work. Remove once the
    /// wrapper sends positions itself (or once we hold a fork of it).
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = touches.first(where: { $0.type == .direct }),
           let handle = ghosttySurfaceHandle() {
            let location = touch.location(in: self)
            termio_ghostty_surface_mouse_pos(handle, location.x, location.y, 0)
        }
        super.touchesBegan(touches, with: event)
    }

    /// The `ghostty_surface_t` behind this view, via the wrapper's stored
    /// properties (`core` → `surface` → `surface`) — none of them public.
    /// Resolved fresh per touch so a recreated surface is never stale.
    /// `ghostty_surface_t` is `void *`, which Swift imports as
    /// `UnsafeMutableRawPointer`.
    private func ghosttySurfaceHandle() -> UnsafeMutableRawPointer? {
        guard let coordinator = storedProperty(of: self, named: "core"),
              let terminalSurface = storedProperty(of: coordinator, named: "surface"),
              let handle = storedProperty(of: terminalSurface, named: "surface")
        else { return nil }
        return handle as? UnsafeMutableRawPointer
    }

    private func storedProperty(of subject: Any, named label: String) -> Any? {
        var mirror: Mirror? = Mirror(reflecting: subject)
        while let current = mirror {
            if let value = current.children.first(where: { $0.label == label })?.value {
                let valueMirror = Mirror(reflecting: value)
                guard valueMirror.displayStyle == .optional else { return value }
                return valueMirror.children.first?.value
            }
            mirror = current.superclassMirror
        }
        return nil
    }
}

/// `ghostty_surface_mouse_pos` from the statically linked GhosttyKit, bound
/// by symbol name because the package neither re-exports the C module to app
/// targets nor wraps this call in public API.
@_silgen_name("ghostty_surface_mouse_pos")
private func termio_ghostty_surface_mouse_pos(
    _ surface: UnsafeMutableRawPointer, _ x: Double, _ y: Double, _ mods: Int32
)
