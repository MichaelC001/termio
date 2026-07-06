import GhosttyTerminal
import GhosttyTheme
import Photos
import PhotosUI
import ShellCraftKit
import TermioSSH
import TermioShared
import UIKit
import UniformTypeIdentifiers

/// Full-screen terminal for one session — the bundled demo sandbox shell for
/// mock sessions, a live companion connection to a Mac session, or a direct
/// SSH session to a saved host. The right screen edge slides in the inspector
/// drawer (file tree + changes); the terminal keeps rendering, dimmed, behind it.
final class TerminalViewController: UIViewController {
    private enum Backend {
        case demoShell
        case companion(URL)
        case ssh(SSHHost)
    }

    private let session: MockSession
    private let backend: Backend

    /// Set by RootContainerViewController: the session DIED (exit or lost
    /// connection), as opposed to the user navigating back, which parks the
    /// screen in the container's keep-alive cache.
    var onClose: (() -> Void)?

    /// Set by RootContainerViewController: go back to the session list. The
    /// container keeps this screen parked (view installed, surface alive)
    /// rather than tearing it down — the plain nav-pop that used to do this
    /// freed the surface and raced libghostty's render threads.
    var onRequestBack: (() -> Void)?

    private lazy var terminalView = DisplayTerminalView(frame: .zero)
    private let composerBar = ComposerBar()
    /// Last size actually sent to the engine + the pending coalesced refit —
    /// see viewDidLayoutSubviews for why resizes are rationed.
    private var lastFittedSize: CGSize = .zero
    private var fitDebounce: DispatchWorkItem?
    private lazy var shellSession = ShellSession(shell: defaultSandboxShell)
    private var companion: CompanionTransport?
    private var companionSession: InMemoryTerminalSession?
    private var sshClient: SSHTerminalClient?
    private var sshSession: InMemoryTerminalSession?
    private let headerBar = UIStackView()
    private let contextLabel = UILabel()
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private var surfaceConfigured = false
    private var backendStarted = false
    /// Timestamp of the last renderer-death surface rebuild, to debounce a
    /// scroll that re-trips libghostty's health failsafe many times in a row.
    private var lastRendererRecovery: Date?
    /// Opaque backdrop-colored cover pinned over the surface. libghostty paints
    /// its "non-functional" panel INTO the surface a frame or two before we can
    /// react, so we mask it during the rebuild — the user sees a plain
    /// background blink (like a repaint), never the alarming error text.
    private let rendererCoverView: UIView = {
        let v = UIView()
        v.isHidden = true
        v.isUserInteractionEnabled = false
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()
    private var settingsObserver: NSObjectProtocol?
    private var uploadClient: CompanionClient?
    private var uploadQueue: [(name: String, data: Data)] = []
    private var uploadInFlight = false
    private var uploadTotal = 0
    private var uploadDone = 0
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

    /// A direct SSH terminal to a saved host (Settings ▸ SSH). Secrets are read
    /// from the Keychain when the session is built (see makeTerminalSession).
    init(sshHost: SSHHost) {
        session = MockSession(
            title: sshHost.displayName,
            project: "ssh", agent: .terminal, status: .idle,
            subtitle: "", time: ""
        )
        backend = .ssh(sshHost)
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    deinit {
        companion?.stop()
        sshClient?.stop()
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
            case .companion:
                companion?.start()
            case .ssh:
                sshClient?.start()
            }
        } else if case .companion = backend {
            // Re-entering a parked session claims the PTY's winsize back —
            // the Mac may own it, and this view's size didn't change, so no
            // layout pass would re-send the grid.
            companion?.reassertGrid()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Leaving the terminal (popping back to the session list) must take the
        // keyboard with it — otherwise the composer field stays first responder
        // and the keyboard + terminal accessory bar linger over the list.
        composerBar.unfocus()
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
        case .companion: "Connecting…"
        case .ssh(let host): "Connecting to \(host.host)…"
        }
        contextLabel.isHidden = contextLabel.text?.isEmpty ?? true
        switch backend {
        case .companion, .ssh: contextLabel.isHidden = true // until connected
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
        // The right slot balances the back chevron (keeping the title centered)
        // and holds an overflow menu of per-session actions — View Trace and
        // Copy Path for a companion session. With nothing to offer (the demo
        // shell has no Mac transcript or path) it stays an invisible spacer.
        let overflow = UIButton(type: .system)
        overflow.applyGlassSymbol("ellipsis", pointSize: 16)
        overflow.accessibilityIdentifier = "terminal.overflow"
        overflow.tintColor = .secondaryLabel
        overflow.showsMenuAsPrimaryAction = true
        let menu = makeOverflowMenu()
        overflow.menu = menu
        if menu.children.isEmpty {
            overflow.alpha = 0
            overflow.isUserInteractionEnabled = false
        }
        headerBar.addArrangedSubview(back)
        headerBar.addArrangedSubview(titles)
        headerBar.addArrangedSubview(overflow)
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerBar)
        NSLayoutConstraint.activate([
            headerBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            headerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            headerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            back.widthAnchor.constraint(equalToConstant: 44),
            back.heightAnchor.constraint(equalToConstant: 44),
            overflow.widthAnchor.constraint(equalToConstant: 44),
            overflow.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    /// The header overflow menu. View Trace and Copy Path appear only for a
    /// companion session, where there is a Mac transcript and project path to
    /// reach; the demo shell has neither, so the menu comes back empty and the
    /// button hides itself.
    private func makeOverflowMenu() -> UIMenu {
        var items: [UIMenuElement] = []
        if case .companion = backend {
            items.append(UIAction(
                title: "View Trace", image: UIImage(systemName: "list.bullet.rectangle")
            ) { [weak self] _ in self?.showTrace() })
        }
        if let path = session.projectPath, !path.isEmpty {
            items.append(UIAction(
                title: "Copy Path", image: UIImage(systemName: "doc.on.doc")
            ) { _ in UIPasteboard.general.string = path })
        }
        return UIMenu(children: items)
    }

    /// Present the session's agent transcript as an in-app HTML trace — the
    /// phone counterpart of the desktop Info pane's "View Trace". The Mac
    /// renders it (reusing `SessionTraceRenderer`) and returns the document
    /// over the companion socket; the sheet shows a spinner until it lands.
    private func showTrace() {
        guard case .companion = backend, let companion else { return }
        let trace = TraceViewController()
        companion.onTrace = { [weak trace] html in trace?.load(html: html) }
        let nav = UINavigationController(rootViewController: trace)
        present(nav, animated: true)
        companion.requestTrace(dark: traitCollection.userInterfaceStyle == .dark)
    }

    /// Called by RootContainerViewController when this parked screen slides
    /// back into view. The view was only hidden (never removed from the
    /// window), so `viewDidAppear` does not fire — re-run the parts that must
    /// happen on every return.
    func prepareForReappearance() {
        if !drawerOpen { focusInput() }
        // Re-entering a parked companion session claims the PTY's winsize back —
        // the Mac may own it, and this view's size didn't change while parked,
        // so no layout pass would re-send the grid.
        if case .companion = backend { companion?.reassertGrid() }
    }

    /// Back to the inbox: the screen parks in the container's keep-alive
    /// cache — the session stays live, unlike `close()`.
    private func goBack() {
        if let onRequestBack {
            onRequestBack()
        } else {
            navigationController?.popViewController(animated: true)
        }
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

        // Sits directly above the surface (below the composer/drawer added
        // later), so unhiding it masks libghostty's panel during a rebuild.
        rendererCoverView.backgroundColor = Self.backdropColor()
        view.addSubview(rendererCoverView)
        NSLayoutConstraint.activate([
            rendererCoverView.topAnchor.constraint(equalTo: terminalView.topAnchor),
            rendererCoverView.leadingAnchor.constraint(equalTo: terminalView.leadingAnchor),
            rendererCoverView.trailingAnchor.constraint(equalTo: terminalView.trailingAnchor),
            rendererCoverView.bottomAnchor.constraint(equalTo: terminalView.bottomAnchor),
        ])

        composerBar.onSend = { [weak self] text in self?.sendComposedPrompt(text) }
        composerBar.onTerminalKey = { [weak self] payload in self?.terminalView.send(payload) }
        composerBar.onAttach = { [weak self] in self?.presentAttachOptions() }
        composerBar.slashCommands = Self.slashCatalog(for: session.agent)
        if case .companion = backend, session.projectRosterID != nil {
            composerBar.setAttachAvailable(true)
        }
        composerBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(composerBar)

        activateTerminalConstraints()
        NSLayoutConstraint.activate([
            composerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composerBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
    }

    /// Pins the surface into the header/composer sandwich.
    private func activateTerminalConstraints() {
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            terminalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: composerBar.topAnchor),
        ])
    }

    /// Called by the container right after it removes this screen from the view
    /// hierarchy (which frees the surface via `didMoveToWindow(nil)`), so
    /// libghostty's orphaned Metal layer is dropped before the next
    /// CoreAnimation commit can fault on its dangling delegate.
    func releaseOrphanedSurfaceLayers() {
        detachOrphanedSurfaceLayers()
    }

    /// Neutralize libghostty's orphaned Metal layers after a surface free.
    ///
    /// `ghostty_surface_free` frees the Zig surface object but leaves the
    /// CAMetalLayer it added as a sublayer in the view's layer tree — and that
    /// layer's delegate still points at the now-freed surface. The wrapper never
    /// detaches it, so the next CoreAnimation commit dereferences freed memory:
    /// the `renderer.Metal` / `apprt.surface.Mailbox.push` EXC_BAD_ACCESS inside
    /// `CA::Context::commit_transaction` seen in the device crash logs. Nil the
    /// delegate (a plain unsafe_unretained assignment — never messages the freed
    /// object) and remove the layer, so no commit can call back into it. Only
    /// ever runs while the surface is torn down, never during healthy rendering.
    private func detachOrphanedSurfaceLayers() {
        terminalView.layer.sublayers?.forEach { layer in
            layer.delegate = nil
            layer.removeFromSuperlayer()
        }
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

    private static let uploadByteCap = 8 << 20

    private func presentAttachOptions() {
        let sheet = AttachmentSheetViewController()
        sheet.onPickAssets = { [weak self] assets in self?.uploadAssets(assets) }
        sheet.onCamera = { [weak self] in self?.presentCamera() }
        sheet.onPhotoLibrary = { [weak self] in self?.presentPhotoPicker() }
        sheet.onFiles = { [weak self] in self?.presentDocumentPicker() }
        if let presentation = sheet.sheetPresentationController {
            presentation.detents = [.medium(), .large()]
            presentation.prefersGrabberVisible = true
        }
        present(sheet, animated: true)
    }

    /// Exports the sheet's PHAsset selection through the same downscale +
    /// queue path as the system pickers; original filenames survive the
    /// JPEG re-encode.
    private func uploadAssets(_ assets: [PHAsset]) {
        guard !assets.isEmpty else { return }
        var payloads = [(name: String, data: Data)?](repeating: nil, count: assets.count)
        let group = DispatchGroup()
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        for (index, asset) in assets.enumerated() {
            group.enter()
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 2048, height: 2048),
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !degraded else { return }
                defer { group.leave() }
                guard let image, let data = Self.jpegPayload(from: image) else { return }
                let original = PHAssetResource.assetResources(for: asset)
                    .first(where: { $0.type == .photo })?.originalFilename
                let base = original.map { ($0 as NSString).deletingPathExtension }
                    ?? "photo-\(index + 1)"
                payloads[index] = (base + ".jpg", data)
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.enqueueUploads(payloads.compactMap { $0 })
        }
    }

    private func presentPhotoPicker() {
        var config = PHPickerConfiguration()
        config.filter = .images
        // Telegram's default batch limit; .ordered gives numbered selection
        // circles from the system picker.
        config.selectionLimit = 10
        config.selection = .ordered
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func presentCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = self
        present(picker, animated: true)
    }

    private func presentDocumentPicker() {
        // asCopy avoids the whole security-scope/bookmark dance — the bytes
        // get copied to the Mac anyway.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        present(picker, animated: true)
    }

    /// Pushes picked bytes to the Mac one file at a time; each reply's
    /// absolute path lands in the draft — Moshi's flow (agents take file
    /// paths), but over the companion link instead of SCP. Uploads run
    /// sequentially because .uploaded replies carry no correlation id.
    private func enqueueUploads(_ items: [(name: String, data: Data)]) {
        guard case .companion = backend, session.projectRosterID != nil else { return }
        let oversized = items.filter { $0.data.count > Self.uploadByteCap }
        reportSkipped(oversized: oversized.map(\.name))
        let accepted = items.filter { $0.data.count <= Self.uploadByteCap }
        guard !accepted.isEmpty else { return }
        uploadQueue.append(contentsOf: accepted)
        uploadTotal += accepted.count
        sendNextUpload()
    }

    private func sendNextUpload() {
        guard !uploadInFlight else { return }
        guard let item = uploadQueue.first else {
            uploadTotal = 0
            uploadDone = 0
            composerBar.setAttachBusy(false)
            return
        }
        guard case .companion(let url) = backend,
              let projectID = session.projectRosterID else { return }
        uploadQueue.removeFirst()
        uploadInFlight = true
        composerBar.setAttachBusy(true, progress: (done: uploadDone, total: uploadTotal))
        if uploadClient == nil {
            let client = CompanionClient(url: url)
            client.onUploaded = { [weak self] path in
                guard let self else { return }
                self.composerBar.insertDraft(path)
                self.uploadDone += 1
                self.uploadInFlight = false
                self.sendNextUpload()
            }
            client.onError = { [weak self] message in
                guard let self else { return }
                self.uploadQueue.removeAll()
                self.uploadInFlight = false
                self.uploadTotal = 0
                self.uploadDone = 0
                self.composerBar.setAttachBusy(false)
                self.presentAlert("Upload failed", message)
            }
            client.start()
            uploadClient = client
        }
        uploadClient?.send(
            .upload(projectID: projectID, name: item.name, base64: item.data.base64EncodedString())
        )
    }

    private func reportSkipped(oversized: [String], unreadable: [String] = []) {
        var lines: [String] = []
        if !oversized.isEmpty {
            lines.append("Over the 8 MB cap: \(oversized.joined(separator: ", "))")
        }
        if !unreadable.isEmpty {
            lines.append("Couldn't read: \(unreadable.joined(separator: ", "))")
        }
        guard !lines.isEmpty else { return }
        presentAlert("Some files were skipped", lines.joined(separator: "\n"))
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

    /// Demo sessions use ShellCraftKit's sandbox shell; companion sessions
    /// bridge the surface to the Mac's PTY over the wire — keystrokes out,
    /// remote bytes in, grid resize → window-change.
    private func makeTerminalSession() -> InMemoryTerminalSession {
        switch backend {
        case .demoShell:
            return shellSession.terminalSession
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
        case .ssh(let host):
            var config = SSHConfig(host: host.host, port: host.port, username: host.username)
            switch host.auth {
            case .password: config.password = SSHKeychain.password(for: host.id)
            case .key(let keyID): config.privateKey = SSHKeychain.privateKey(for: keyID)
            }
            let client = SSHTerminalClient(config: config)
            let terminalSession = InMemoryTerminalSession(
                write: { [weak client] data in client?.send(data) },
                resize: { [weak client] viewport in
                    client?.resize(cols: Int(viewport.columns), rows: Int(viewport.rows))
                }
            )
            client.onOutput = { [weak terminalSession] data in terminalSession?.receive(data) }
            client.onState = { [weak self] state in self?.sshStateChanged(state) }
            sshClient = client
            sshSession = terminalSession
            return terminalSession
        }
    }

    private func sshStateChanged(_ state: SSHClientState) {
        statusLabel.isHidden = false
        contextLabel.isHidden = true
        switch state {
        case .idle, .connecting:
            statusLabel.text = "Connecting…"
        case .connected:
            statusLabel.isHidden = true
        case .failed(let reason):
            statusLabel.text = "Connection failed"
            let alert = UIAlertController(title: "SSH connection failed", message: reason, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
                self?.close()
            })
            present(alert, animated: true)
        case .closed:
            statusLabel.text = "Disconnected"
            sshSession?.finish(exitCode: 0, runtimeMilliseconds: 0)
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
            // The phone is a viewer, not the scrollback of record — the Mac keeps
            // the full history. libghostty's renderer paints its "non-functional"
            // panel when it exhausts a GPU/allocator resource reflowing scrollback
            // at this narrow grid during a drag-scroll — a purely internal Zig
            // failure it never reports to us (verified via device logs: it emits
            // no RENDERER_HEALTH action and exposes no health getter). We can't
            // catch it, only reduce what it must build: cap scrollback hard so a
            // drag can't reflow enough rows to tip the renderer over. 256 KB is
            // still ~thousands of lines — plenty for a phone viewer.
            builder.withCustom("scrollback-limit", "256000")
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
        // Leftward opens the drawer; rightward goes back to the list, which the
        // container (or a hosting nav stack) must be able to honor.
        let canGoBack = onRequestBack != nil
            || (navigationController?.viewControllers.count ?? 0) > 1
        return velocity.x < 0 || canGoBack
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
        guard !results.isEmpty else { return }
        // Slots keep the user's selection order while loads land out of order.
        var payloads = [(name: String, data: Data)?](repeating: nil, count: results.count)
        let group = DispatchGroup()
        for (index, result) in results.enumerated() {
            let provider = result.itemProvider
            guard provider.canLoadObject(ofClass: UIImage.self) else { continue }
            group.enter()
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                defer { group.leave() }
                guard let image = object as? UIImage,
                      let data = Self.jpegPayload(from: image) else { return }
                let base = provider.suggestedName.map {
                    ($0 as NSString).deletingPathExtension
                } ?? "photo-\(index + 1)"
                payloads[index] = (base + ".jpg", data)
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.enqueueUploads(payloads.compactMap { $0 })
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
        var items: [(name: String, data: Data)] = []
        var oversized: [String] = []
        var unreadable: [String] = []
        for url in urls {
            // Size gate before reading — no point pulling an over-cap file
            // into memory just to reject it.
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
            guard size <= Self.uploadByteCap else {
                oversized.append(url.lastPathComponent)
                continue
            }
            guard let data = try? Data(contentsOf: url) else {
                unreadable.append(url.lastPathComponent)
                continue
            }
            items.append((url.lastPathComponent, data))
        }
        reportSkipped(oversized: oversized, unreadable: unreadable)
        enqueueUploads(items)
    }
}

extension TerminalViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        picker.dismiss(animated: true)
        guard let image = info[.originalImage] as? UIImage,
              let data = Self.jpegPayload(from: image) else { return }
        enqueueUploads([("camera.jpg", data)])
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
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

extension TerminalViewController: TerminalSurfaceRendererHealthDelegate {
    /// libghostty flipped its renderer health. `healthy == false` means it just
    /// tripped the failsafe that paints the "This terminal is non-functional"
    /// panel INTO the surface — the exact bug we're chasing. Our forked wrapper
    /// forwards this (upstream drops it); log it so the moment is visible in the
    /// unified log, then rebuild the surface so the dead panel doesn't linger.
    func terminalDidChangeRendererHealth(_ healthy: Bool) {
        // NOTE: device logs proved libghostty's embedded build never dispatches
        // GHOSTTY_ACTION_RENDERER_HEALTH, so this never fires — kept only so the
        // wiring is ready if a Zig-source build starts emitting it. The real
        // mitigation is prevention (scrollback + parked-surface caps).
        Log.terminal.error("renderer health changed: healthy=\(healthy, privacy: .public)")
        guard !healthy else { return }
        recoverFromRendererDeath()
    }

    /// Rebuild the surface in place, reusing the SAME in-memory session so the
    /// companion/SSH byte stream is never dropped — only the dead Metal surface
    /// is replaced. Debounced: if a single scroll re-trips health repeatedly we
    /// must not loop-flicker, so we rebuild at most once every couple seconds.
    private func recoverFromRendererDeath() {
        let now = Date()
        if let last = lastRendererRecovery, now.timeIntervalSince(last) < 2 {
            Log.terminal.error("renderer recovery skipped (debounced)")
            return
        }
        lastRendererRecovery = now

        let existing: InMemoryTerminalSession?
        switch backend {
        case .demoShell: existing = shellSession.terminalSession
        case .companion: existing = companionSession
        case .ssh: existing = sshSession
        }
        guard surfaceConfigured, let session = existing else { return }

        Log.terminal.error("rebuilding surface after renderer death")
        // Mask first, synchronously, so the panel libghostty already painted is
        // hidden by the backdrop before the next screen commit shows it.
        rendererCoverView.backgroundColor = Self.backdropColor()
        rendererCoverView.isHidden = false
        // Drop the freed surface's orphaned Metal layer before the rebuild adds
        // a fresh one, else the dead panel's layer stays composited underneath.
        detachOrphanedSurfaceLayers()
        terminalView.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        terminalView.fitToSize()
        lastFittedSize = terminalView.bounds.size
        // A rebuilt surface starts blank; the stream won't repaint until the
        // next byte. Reclaim the grid so the Mac re-sends current content.
        if case .companion = backend { companion?.reassertGrid() }
        // Reveal once the rebuilt surface has had a beat to repaint (companion
        // content arrives over the network) so we don't uncover a blank grid.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.rendererCoverView.isHidden = true
        }
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

    /// The wrapper's `ghostty_surface_t`, resolved once per scroll interaction
    /// so the per-frame draw path never re-walks its private mirror at touch-
    /// sample rate (up to 120 Hz on ProMotion).
    private var scrollSurfaceHandle: UnsafeMutableRawPointer?

    /// Vsync-aligned draw pump that owns the whole scroll interaction — the
    /// active finger drag AND the momentum glide after it lifts. The wrapper
    /// paints through `DispatchQueue.main.async` (its `startDisplayLink` is a
    /// stub), off the vsync boundary, so we drive the draws ourselves.
    ///
    /// Crucially the pump draws *at most once per vsync*. The active drag used
    /// to draw synchronously on every pan `.changed`, which fires several times
    /// per frame — each `ghostty_surface_draw` grabs a `CAMetalDrawable`, and
    /// the layer's pool is only ~3 deep. Faster-than-vsync draws starve it, the
    /// next drawable comes back nil, libghostty logs a Metal error, and after a
    /// few it trips its renderer-health failsafe — the "This terminal is
    /// non-functional" panel painted straight into the surface. Coalescing the
    /// drag onto this link caps us at one drawable per frame, so the pool never
    /// empties. See docs/design/ios-scroll-renderer-health.md.
    private var scrollPump: CADisplayLink?
    /// Set by pan `.changed`; the pump consumes it once per frame during a drag.
    private var needsScrollDraw = false
    /// True once the finger lifts: the pump paints every frame through the
    /// deceleration tail instead of waiting on `needsScrollDraw`.
    private var scrollCoasting = false
    private var scrollCoastDeadline: CFTimeInterval = 0

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

    /// The wrapper renders every frame through `DispatchQueue.main.async`
    /// (its `startDisplayLink` is a stub — no real vsync loop), so a finger
    /// scroll lands a beat behind the gesture: the viewport is already moved
    /// but the GPU draw slips past the CA commit deadline. We ride the same
    /// pan recognizer — our target is added after the wrapper's, so by the
    /// time `.changed` reaches us the viewport is current — and hand the draw
    /// to the vsync pump, which coalesces it to one frame. The pump keeps
    /// painting through the momentum tail until the wrapper's glide decelerates.
    @objc private func scrollGestureChanged(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            onScrollGesture?()
            scrollSurfaceHandle = ghosttySurfaceHandle()
            scrollCoasting = false
            needsScrollDraw = true
            startScrollPump()
        case .changed:
            // Mark the frame dirty; the pump draws it once at the next vsync.
            // Never draw synchronously here — see `scrollPump` for why that
            // starves the drawable pool and trips libghostty's failsafe.
            needsScrollDraw = true
        case .ended, .cancelled, .failed:
            // Enter the momentum tail; the already-running pump keeps painting.
            scrollCoasting = true
            scrollCoastDeadline = 0 // armed from the first coasting frame
        default:
            break
        }
    }

    /// Mirror the coordinator's proven per-tick sequence (refresh then draw),
    /// on the vsync-aligned call path instead of a deferred main-queue block.
    private func drawScrollFrameNow() {
        guard let handle = scrollSurfaceHandle ?? ghosttySurfaceHandle() else { return }
        termio_ghostty_surface_refresh(handle)
        termio_ghostty_surface_draw(handle)
    }

    private func startScrollPump() {
        guard scrollPump == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(scrollPumpFrame(_:)))
        link.add(to: .main, forMode: .common)
        scrollPump = link
    }

    @objc private func scrollPumpFrame(_ link: CADisplayLink) {
        if scrollCoasting {
            // 0.92-per-frame decel from a hard fling reaches the wrapper's
            // <50 px/s cutoff well inside 1.2 s; past that the surface is idle
            // and the pump is pure waste, so it stops itself.
            if scrollCoastDeadline == 0 { scrollCoastDeadline = link.timestamp + 1.2 }
            if link.timestamp >= scrollCoastDeadline { stopScrollPump(); return }
            drawScrollFrameNow()
        } else if needsScrollDraw {
            // One drawable per vsync, no matter how many `.changed` events the
            // pan delivered this frame — that cap is the whole fix.
            needsScrollDraw = false
            drawScrollFrameNow()
        }
    }

    private func stopScrollPump() {
        scrollPump?.invalidate()
        scrollPump = nil
        scrollCoasting = false
        needsScrollDraw = false
        scrollSurfaceHandle = nil
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

/// `ghostty_surface_refresh` / `ghostty_surface_draw` — the same synchronous
/// render pair the coordinator runs each tick, bound by symbol so the scroll
/// path can present a frame at vsync instead of on a deferred main-queue block.
@_silgen_name("ghostty_surface_refresh")
private func termio_ghostty_surface_refresh(_ surface: UnsafeMutableRawPointer)

@_silgen_name("ghostty_surface_draw")
private func termio_ghostty_surface_draw(_ surface: UnsafeMutableRawPointer)
