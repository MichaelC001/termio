import AppKit
import Combine
import Sparkle
import SwiftUI

/// AppKit bootstrap. We drive `NSApplication` directly (rather than the SwiftUI
/// `App` lifecycle) so a plain SwiftPM executable launches as a real foreground
/// app — `.regular` activation policy plus an explicit activate — and hosts the
/// SwiftUI tree in a window. This keeps key/focus handling reliable for the
/// terminal surface without needing an Xcode app bundle.
@main
enum Termio {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.mainMenu = buildMainMenu()
        application.activate(ignoringOtherApps: true)
        application.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private let settings = AppSettings()
    private lazy var store = TermioStore.restored(settings: settings)
    private lazy var usageMonitor = UsageMonitor(settings: settings)
    private let licenseManager = LicenseManager()
    private var menuBar: MenuBarController?
    private var settingsWindow: NSWindow?
    private var settingsObserver: AnyCancellable?
    // Drives in-app auto-update. Started only in release builds — a debug build has
    // no Developer-ID signature for Sparkle to validate the appcast's EdDSA against,
    // and we don't want dev runs phoning the update feed. The feed URL and public
    // key live in packaging/Info.plist (SUFeedURL / SUPublicEDKey).
    #if DEBUG
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    #else
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    #endif
    // Folders handed to us by the `termio` CLI (via `open -b com.termio.app <dir>`)
    // before the window exists, replayed once it does. macOS may deliver the open
    // event during a cold launch, ahead of `applicationDidFinishLaunching`.
    private var pendingOpenURLs: [URL] = []
    // The split controller, retained so `installToolbar` can bind the native sidebar
    // toggle and the sidebar tracking separator to its split view.
    private weak var splitViewController: NSSplitViewController?
    // The window's real toolbar delegate (must be retained); it carries the native
    // sidebar toggle (see `installToolbar`).
    private var toolbarDelegate: MainToolbarDelegate?
    // Keeps the native window title (path) and subtitle (git branch) in step with the
    // selected session — NetNewsWire's approach, no custom title-bar views.
    private var titleObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Termio"
        // Floor the window size so it can't be dragged down to an unusable sliver: the
        // sidebar alone wants ~220pt, leaving room for a workable terminal beside it.
        window.contentMinSize = NSSize(width: 640, height: 420)
        // Stock window chrome, NetNewsWire-style: a normal system toolbar with the native
        // title + subtitle (showing the session's path and git branch), the native sidebar
        // toggle, and `.fullSizeContentView` letting the sidebar's vibrant material run up
        // behind the traffic lights. No custom title-bar painting. `.automatic` toolbar style
        // splits the bar at the sidebar divider rather than painting one flat unified band.
        window.toolbarStyle = .automatic
        // Drive the split with a real AppKit `NSSplitViewController` whose first item
        // has `.sidebar` behavior — NetNewsWire's architecture. This is the *only* way to
        // get the native full-height sidebar (vibrant material running up behind the
        // traffic lights, the toggle, the title-bar tracking separator). A SwiftUI
        // `NavigationSplitView` only gets that treatment as the root of a `WindowGroup`
        // scene; hosted inside a manual `NSWindow` it renders as an embedded
        // representable with no connection to the title bar, so the sidebar can never
        // reach behind the traffic lights. SwiftUI still renders each pane's contents.
        window.contentViewController = makeContentSplitViewController()
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("TermioMainWindow")
        window.makeKeyAndOrderFront(nil)
        applyWindowTransparency()
        applyChromeAppearance()
        installToolbar()
        updateWindowTitle()
        // Keep the native title/subtitle in step with the selected session and its live branch.
        titleObserver = store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                MainActor.assumeIsolated { self?.updateWindowTitle() }
            }

        // Background opacity/blur only show through a non-opaque window, and the
        // window's light/dark appearance follows the selected theme, so both track
        // the settings. `objectWillChange` fires before the value lands, hence the
        // next-tick hop (mirrors the store's re-style observer).
        settingsObserver = settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.applyWindowTransparency()
                self?.applyChromeAppearance()
            }

        menuBar = MenuBarController(store: store) { [weak self] id in
            self?.store.selectedSessionID = id
            NSApp.activate(ignoringOtherApps: true)
            self?.window.makeKeyAndOrderFront(nil)
        }
        usageMonitor.start()
        checkLicenseAtLaunch()

        if !pendingOpenURLs.isEmpty {
            let urls = pendingOpenURLs
            pendingOpenURLs = []
            openProjects(at: urls)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop any per-project sandbox containers so no helper VM outlives the app.
        store.containerManager.teardownAll()
    }

    /// Builds the window's content: an `NSSplitViewController` with a native sidebar item
    /// and a detail item, each hosting its SwiftUI view. `sidebarWithViewController` is what
    /// gives the leading column the full-height vibrant `.sidebar` material behind the traffic
    /// lights and the title-bar tracking separator. The panes no longer bridge their toolbars —
    /// the window owns a real `NSToolbar` (see `installToolbar`) so it can carry the native
    /// `.toggleSidebar` item. The standard `toggleSidebar(_:)` responder action collapses the item.
    private func makeContentSplitViewController() -> NSSplitViewController {
        let sidebar = NSHostingController(rootView: SidebarView()
            .environmentObject(store)
            .environmentObject(settings))
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 400
        sidebarItem.canCollapse = true
        sidebarItem.allowsFullHeightLayout = true

        let detail = NSHostingController(rootView: TerminalPane()
            .environmentObject(store)
            .environmentObject(settings))
        let detailItem = NSSplitViewItem(viewController: detail)

        let splitViewController = NSSplitViewController()
        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(detailItem)
        splitViewController.splitView.autosaveName = "TermioContentSplit"
        self.splitViewController = splitViewController
        return splitViewController
    }

    /// Mirrors the selected session's working directory into the native window title and its
    /// live git branch into the subtitle — NetNewsWire's pattern (the system draws them in the
    /// toolbar; no custom views). The path is the session's real working directory, so a
    /// worktree session shows where it actually runs; a non-git folder leaves the subtitle empty.
    private func updateWindowTitle() {
        guard let window else { return }
        guard let id = store.selectedSessionID, let project = store.project(for: id) else {
            window.title = "Termio"
            window.subtitle = ""
            return
        }
        let folder = store.session(id)?.worktreePath ?? project.path
        window.title = abbreviatingHome(folder)
        window.subtitle = store.branch(forFolder: folder) ?? ""
    }

    /// Home-abbreviates an absolute path to `~`, matching how a shell prompt shows it.
    private func abbreviatingHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Entry point for the `termio` CLI: macOS delivers the folder passed to
    /// `open -b com.termio.app <dir>` here. Because termio is single-instance, an
    /// already-running app receives this in place, so the project opens in the
    /// existing window rather than spawning a second one.
    func application(_ application: NSApplication, open urls: [URL]) {
        openProjects(at: urls)
    }

    /// Adds each directory as a project in the one shared store and brings the
    /// window forward. Called before the window exists buffers into `pendingOpenURLs`.
    private func openProjects(at urls: [URL]) {
        guard window != nil else {
            pendingOpenURLs.append(contentsOf: urls)
            return
        }
        let directories = urls.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        guard !directories.isEmpty else { return }
        for url in directories {
            store.addProject(at: url)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Makes the window non-opaque (so a translucent terminal background reveals
    /// the desktop and Ghostty's blur can take effect) only when the user has
    /// actually dialed opacity below full; at full opacity the window takes the
    /// terminal's own background so the transparent title bar sits flush with the
    /// terminal instead of showing the system window grey. Re-run on every settings
    /// change, so the title bar tracks the terminal theme live.
    private func applyWindowTransparency() {
        guard let window else { return }
        let translucent = settings.backgroundOpacity < 1.0 || settings.backgroundBlur > 0
        window.isOpaque = !translucent
        window.backgroundColor = translucent ? .clear : settings.terminalBackgroundColor
    }

    /// Applies the user's appearance mode. `.system` leaves every surface tracking
    /// the OS (termio keeps a separate terminal theme per appearance, and libghostty
    /// switches between them in step); `.light`/`.dark` pin a fixed `NSAppearance`
    /// app-wide, which the title bar, traffic lights, scrollbars, and the terminal's
    /// effective appearance (hence its light/dark theme) all follow together.
    private func applyChromeAppearance() {
        let appearance: NSAppearance?
        switch settings.appearanceMode {
        case .system: appearance = nil
        case .light: appearance = NSAppearance(named: .aqua)
        case .dark: appearance = NSAppearance(named: .darkAqua)
        }
        NSApp.appearance = appearance
        window?.appearance = appearance
        settingsWindow?.appearance = appearance
    }

    /// Installs a real `NSToolbar`, the way NetNewsWire does, so the window gets the
    /// genuine system sidebar toggle. The native `.toggleSidebar` item — provided and
    /// styled by AppKit, with the proper macOS 26 Liquid Glass on hover — can only live in
    /// a real toolbar, not SwiftUI's bridged one, so the panes no longer bridge their
    /// toolbars (`sceneBridgingOptions` dropped). `.sidebarTrackingSeparator` keeps the
    /// toolbar's split aligned with the sidebar divider, and the toggle stays put (after
    /// the traffic lights) when the sidebar collapses.
    private func installToolbar() {
        guard let window, let splitViewController else { return }
        let delegate = MainToolbarDelegate(splitView: splitViewController.splitView)
        toolbarDelegate = delegate
        let toolbar = NSToolbar(identifier: "TermioMainToolbar")
        toolbar.delegate = delegate
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
    }

    /// Opens (or refocuses) the preferences window. Reached via the responder
    /// chain from the menu item, which targets `nil`. The window is kept alive
    /// (not released on close) so reopening preserves nothing-to-rebuild state.
    @objc func showSettings(_ sender: Any?) {
        openSettings(initialTab: .appearance)
    }

    /// Opens (or refocuses) the preferences window on a specific tab. The content
    /// view is rebuilt each call so the requested tab takes effect even when the
    /// window is reused — harmless because every control binds straight to
    /// `AppSettings`, so there is no transient UI state to preserve.
    func openSettings(initialTab: SettingsTab) {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 460),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Settings"
            // Drop the hairline under the title bar so the icon-tab strip reads as
            // one continuous surface with the title bar, Dia-style. A transparent
            // titlebar is what actually removes the separator when there is no
            // toolbar; `.none` alone leaves a faint line.
            window.titlebarSeparatorStyle = .none
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.contentView = NSHostingView(rootView: SettingsView(
            settings: settings,
            usage: usageMonitor,
            license: licenseManager,
            initialTab: initialTab
        ))
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Re-validate any stored license against Lemon Squeezy, then — if the trial has
    /// lapsed with no valid license — show the once-a-day purchase reminder. Order
    /// matters: validating first means a refunded key flips to "expired" and a still
    /// -valid key suppresses the reminder.
    private func checkLicenseAtLaunch() {
        Task { [weak self] in
            await self?.licenseManager.refreshOnLaunch()
            self?.presentLicenseReminderIfNeeded()
        }
    }

    /// The gentle nudge: termio never locks after the trial, it just reminds — at
    /// most once per day — that a one-time license unlocks it for good. Shown as a
    /// sheet on the main window so it doesn't steal focus as a free-floating dialog.
    private func presentLicenseReminderIfNeeded() {
        guard licenseManager.shouldNagOnLaunch(), let window else { return }
        licenseManager.recordNagShown()

        let alert = NSAlert()
        alert.messageText = "Your termio trial has ended"
        alert.informativeText = "termio keeps working exactly as before. If it has earned a place in your workflow, a one-time license unlocks it for good and supports development."
        alert.addButton(withTitle: "Buy termio…")
        alert.addButton(withTitle: "Enter License Key…")
        alert.addButton(withTitle: "Later")
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                if let url = LicenseConfiguration.purchaseURL {
                    NSWorkspace.shared.open(url)
                }
            case .alertSecondButtonReturn:
                self?.openSettings(initialTab: .license)
            default:
                break
            }
        }
    }

    /// File ▸ Open Project… — presents the folder picker that opens a directory as a new
    /// project. Reached via the responder chain (the menu item targets `nil`),
    /// the same nil-target routing the Settings item uses.
    @objc func openProject(_ sender: Any?) {
        store.presentOpenProjectPanel()
    }

    /// File ▸ Open Project in VM… — same picker, but the opened project runs its
    /// sessions inside an isolated sandbox VM. The sandbox is chosen here, at open
    /// time, rather than toggled afterward.
    @objc func openProjectInVM(_ sender: Any?) {
        store.presentOpenProjectPanel(sandboxed: true)
    }

    /// Termio ▸ Check for Updates… — hands off to Sparkle's standard update flow.
    /// Reached via the responder chain (the menu item targets `nil`), the same
    /// nil-target routing the other app-menu items use.
    @objc func checkForUpdates(_ sender: Any?) {
        updaterController.checkForUpdates(sender)
    }
}

/// Delegate for the window's real toolbar. It declares the native sidebar toggle and the
/// sidebar tracking separator — both system-provided — so the delegate only supplies the
/// tracking separator binding (to the sidebar divider) and lets AppKit provide the toggle.
@MainActor
private final class MainToolbarDelegate: NSObject, NSToolbarDelegate {
    private weak var splitView: NSSplitView?

    init(splitView: NSSplitView) {
        self.splitView = splitView
    }

    private let identifiers: [NSToolbarItem.Identifier] = [
        .toggleSidebar, .sidebarTrackingSeparator,
    ]

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        identifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        identifiers
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .sidebarTrackingSeparator:
            guard let splitView else { return nil }
            return NSTrackingSeparatorToolbarItem(
                identifier: .sidebarTrackingSeparator, splitView: splitView, dividerIndex: 0)
        default:
            // `.toggleSidebar` is provided and styled by AppKit.
            return nil
        }
    }
}

@MainActor
private func buildMainMenu() -> NSMenu {
    let mainMenu = NSMenu()

    let appItem = NSMenuItem()
    mainMenu.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(
        withTitle: "Check for Updates…",
        action: #selector(AppDelegate.checkForUpdates(_:)),
        keyEquivalent: ""
    )
    appMenu.addItem(.separator())
    appMenu.addItem(
        withTitle: "Settings…",
        action: #selector(AppDelegate.showSettings(_:)),
        keyEquivalent: ","
    )
    appMenu.addItem(.separator())
    appMenu.addItem(
        withTitle: "Quit Termio",
        action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"
    )
    appItem.submenu = appMenu

    let fileItem = NSMenuItem()
    mainMenu.addItem(fileItem)
    let fileMenu = NSMenu(title: "File")
    fileMenu.addItem(
        withTitle: "Open Project…",
        action: #selector(AppDelegate.openProject(_:)),
        keyEquivalent: "o"
    )
    // Open the project straight into an isolated sandbox VM. Shift-⌘O sits right
    // beside the plain Open Project (⌘O), so the two open modes read as a pair.
    let openInVM = fileMenu.addItem(
        withTitle: "Open Project in VM…",
        action: #selector(AppDelegate.openProjectInVM(_:)),
        keyEquivalent: "O"
    )
    openInVM.keyEquivalentModifierMask = [.command, .shift]
    fileItem.submenu = fileMenu

    // Standard Edit menu so copy/paste/select-all responder actions work.
    let editItem = NSMenuItem()
    mainMenu.addItem(editItem)
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = editMenu

    return mainMenu
}
