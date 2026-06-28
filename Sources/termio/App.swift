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
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let settings = AppSettings()
    private lazy var store = TermioStore.restored(settings: settings)
    private lazy var usageMonitor = UsageMonitor(settings: settings)
    private var menuBar: MenuBarController?
    private var settingsWindow: NSWindow?
    private var settingsObserver: AnyCancellable?
    // Re-applies the fullscreen title-bar fill whenever AppKit rebuilds that bar.
    // See `observeTitlebarFill` for why this is needed only in native full screen.
    private var titlebarFillObserver: AnyCancellable?
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        let root = RootView()
            .environmentObject(store)
            .environmentObject(settings)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Termio"
        window.titlebarAppearsTransparent = true
        // Default (`.automatic`) toolbar style — the same one NetNewsWire uses — so
        // the title bar splits at the sidebar divider and the sidebar's vibrant
        // material runs up behind the traffic lights, instead of a unified style
        // painting one flat full-width band across the top. The window title is
        // hidden so a visible title doesn't force a tall second toolbar row.
        window.toolbarStyle = .automatic
        window.titleVisibility = .hidden
        // Host the SwiftUI tree as the window's *contentViewController* (not a bare
        // contentView). Only then does SwiftUI install its own NSSplitViewController
        // and wire it into the title bar, so NavigationSplitView's sidebar gets the
        // native full-height vibrant material, the system sidebar toggle, and the
        // traffic-light safe area — the treatment a SwiftUI `App` window gets for
        // free, and the reason the sidebar no longer hand-rolls any of that.
        window.contentViewController = NSHostingController(rootView: root)
        window.center()
        window.setFrameAutosaveName("TermioMainWindow")
        window.makeKeyAndOrderFront(nil)
        applyWindowTransparency()
        applyChromeAppearance()
        observeTitlebarFill()

        // Background opacity/blur only show through a non-opaque window, and the
        // window's light/dark appearance follows the selected theme, so both track
        // the settings. `objectWillChange` fires before the value lands, hence the
        // next-tick hop (mirrors the store's re-style observer).
        settingsObserver = settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.applyWindowTransparency()
                self?.applyChromeAppearance()
                self?.scheduleTitlebarFillSync()
            }

        menuBar = MenuBarController(store: store) { [weak self] id in
            self?.store.selectedSessionID = id
            NSApp.activate(ignoringOtherApps: true)
            self?.window.makeKeyAndOrderFront(nil)
        }
        usageMonitor.start()

        if !pendingOpenURLs.isEmpty {
            let urls = pendingOpenURLs
            pendingOpenURLs = []
            openProjects(at: urls)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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

    /// Subscribes to the events that rebuild the native-fullscreen title bar so the
    /// fill can be re-applied each time. In native full screen AppKit moves the title
    /// bar out of our window into a transient, system-owned `NSToolbarFullScreenWindow`
    /// that it silently tears down and recreates on wake, Space switches, and occlusion
    /// changes — each time dropping our color. Re-syncing on these notifications (the
    /// approach Ghostty's terminal window uses) keeps the bar painted through every
    /// rebuild. Windowed mode is untouched: there the SwiftUI toolbar already paints
    /// flush, and recoloring would cover the sidebar's vibrant title-bar region.
    private func observeTitlebarFill() {
        guard let window else { return }
        let windowEvents = Publishers.MergeMany(
            [NSWindow.didEnterFullScreenNotification,
             NSWindow.didExitFullScreenNotification,
             NSWindow.didChangeOcclusionStateNotification,
             NSWindow.didBecomeMainNotification]
                .map { NotificationCenter.default.publisher(for: $0, object: window) }
        )
        titlebarFillObserver = windowEvents
            .merge(with: NSWorkspace.shared.notificationCenter
                .publisher(for: NSWorkspace.didWakeNotification))
            .sink { [weak self] _ in self?.scheduleTitlebarFillSync() }
    }

    /// Re-applies the title-bar fill on the next run-loop turn. The fullscreen toolbar
    /// window and its views are not yet constructed when `didEnterFullScreen` fires, so
    /// resolving them synchronously finds nothing; the hop lets AppKit finish first.
    private func scheduleTitlebarFillSync() {
        DispatchQueue.main.async { [weak self] in self?.syncTitlebarFill() }
    }

    /// Paints the native-fullscreen title bar the exact terminal background. On macOS 26
    /// the fullscreen title bar's Liquid Glass material resolves to system white and
    /// leaves a white seam over the dark terminal; SwiftUI's `toolbarBackground` and the
    /// content background can't reach it because it lives in a separate system window.
    /// Following Ghostty, we recolor the real `NSTitlebarView` layer and hide the
    /// `NSTitlebarBackgroundView` — the subview that forces the glass fill — so our color
    /// reads. No-op outside full screen, where the windowed title bar already works.
    private func syncTitlebarFill() {
        guard let window, window.styleMask.contains(.fullScreen),
              let container = fullScreenTitlebarContainer(for: window),
              let titlebarView = container.firstDescendant(className: "NSTitlebarView")
        else { return }
        let translucent = settings.backgroundOpacity < 1.0 || settings.backgroundBlur > 0
        titlebarView.wantsLayer = true
        if translucent {
            // Keep the bar see-through so a low-opacity background and blur still read.
            titlebarView.layer?.backgroundColor = NSColor.clear.cgColor
        } else {
            // Resolve the dynamic terminal color under the window's own appearance, not
            // the (possibly mismatched) system one, so a Dark-pinned app reads dark here.
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                titlebarView.layer?.backgroundColor = settings.terminalBackgroundColor.cgColor
            }
        }
        container.firstDescendant(className: "NSTitlebarBackgroundView")?.isHidden = !translucent
    }

    /// The title-bar container view inside the system's fullscreen toolbar window. In
    /// native full screen AppKit hosts the title bar in a private `NSToolbarFullScreenWindow`
    /// parented to our window (the parent check disambiguates if more than one exists).
    private func fullScreenTitlebarContainer(for window: NSWindow) -> NSView? {
        let fullScreenWindows = NSApplication.shared.windows.filter {
            String(describing: type(of: $0)) == "NSToolbarFullScreenWindow"
        }
        let target = fullScreenWindows.first { $0.parent == window } ?? fullScreenWindows.first
        return target?.contentView?.firstDescendant(className: "NSTitlebarContainerView")
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

    /// Opens (or refocuses) the preferences window. Reached via the responder
    /// chain from the menu item, which targets `nil`. The window is kept alive
    /// (not released on close) so reopening preserves nothing-to-rebuild state.
    @objc func showSettings(_ sender: Any?) {
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
            window.contentView = NSHostingView(rootView: SettingsView(settings: settings, usage: usageMonitor))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// File ▸ Open Project… — presents the folder picker that opens a directory as a new
    /// project. Reached via the responder chain (the menu item targets `nil`),
    /// the same nil-target routing the Settings item uses.
    @objc func openProject(_ sender: Any?) {
        store.presentOpenProjectPanel()
    }

    /// Termio ▸ Check for Updates… — hands off to Sparkle's standard update flow.
    /// Reached via the responder chain (the menu item targets `nil`), the same
    /// nil-target routing the other app-menu items use.
    @objc func checkForUpdates(_ sender: Any?) {
        updaterController.checkForUpdates(sender)
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

private extension NSView {
    /// The first view in this subtree whose runtime class has the given name. Used to
    /// reach AppKit's private title-bar views (`NSTitlebarView`, `NSTitlebarBackgroundView`)
    /// by name, since they have no public type — the same lookup Ghostty uses.
    func firstDescendant(className name: String) -> NSView? {
        if String(describing: type(of: self)) == name { return self }
        for subview in subviews {
            if let match = subview.firstDescendant(className: name) { return match }
        }
        return nil
    }
}
