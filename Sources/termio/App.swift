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
    // The split controller (sidebar + terminal + inspector). The navigator toggle reaches its
    // `toggleSidebar(_:)` through the responder chain, so this is just a weak handle on the
    // window's content view controller.
    private weak var splitViewController: NSSplitViewController?
    // The trailing file-browser inspector item, retained so the toolbar button and the
    // View menu can collapse/expand it. Starts collapsed (see `makeContentSplitViewController`).
    private var filesInspectorItem: NSSplitViewItem?
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
        // Hide the native title. CodeEdit's recipe renders the folder name + git branch as a
        // custom borderless toolbar item (the branch picker, see `MainToolbarDelegate`) rather
        // than the system title/subtitle, so the toolbar band takes the terminal background
        // cleanly with no mismatched grey title strip. `window.title` is still kept current (for
        // the Window menu and Mission Control) but is not drawn while a toolbar is shown.
        window.titleVisibility = .hidden
        // Let the per-split-item separator styles decide where a hairline shows (CodeEdit's
        // approach: sidebar defers to the system default, terminal `.line`). The window-level
        // `.automatic` defers to those, so the sidebar stays seamless while the terminal gets a
        // clean bounding line — and the tracking separator no longer glares as a black bar in
        // fullscreen. The toolbar style itself is set in `installToolbar` (version-branched).
        window.titlebarSeparatorStyle = .automatic
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
        // CodeEdit's recipe: the divider hairline under the toolbar is owned per split item,
        // not by the window. Pre-macOS 26, the sidebar needs `.none` to stop the sidebar
        // tracking separator from rendering its line as a black bar in fullscreen; on macOS 26
        // the system default already draws seamlessly, so (like CodeEdit's `makeNavigator`) we
        // leave it untouched there.
        if #unavailable(macOS 26) {
            sidebarItem.titlebarSeparatorStyle = .none
        }

        let detail = NSHostingController(rootView: TerminalPane()
            .environmentObject(store)
            .environmentObject(settings))
        let detailItem = NSSplitViewItem(viewController: detail)
        // `.line` only over the terminal: a clean hairline that starts at the sidebar divider
        // and bounds the title strip like Xcode, without bleeding across the sidebar.
        detailItem.titlebarSeparatorStyle = .line

        // The trailing file-tree column is a PLAIN content item (like the terminal), not a
        // `.sidebar`/`.inspector` panel item. macOS 26 gives panel items a Liquid Glass inset in
        // fullscreen (a border/margin on the top, right and bottom); a plain item sits fully flush
        // to the window edges, with only the split divider on its leading edge as a border. The
        // panel items' vibrant material is reproduced by hand inside `FileBrowserHostingController`
        // (a `.sidebar` effect view behind a transparent list), so it still matches the leading
        // sidebar. It starts collapsed — the tree is summoned via the toolbar toggle.
        let inspector = FileBrowserHostingController(store: store, settings: settings)
        let inspectorItem = NSSplitViewItem(viewController: inspector)
        inspectorItem.minimumThickness = 220
        inspectorItem.maximumThickness = 420
        inspectorItem.canCollapse = true
        inspectorItem.isCollapsed = true
        self.filesInspectorItem = inspectorItem

        let splitViewController = NSSplitViewController()
        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(detailItem)
        splitViewController.addSplitViewItem(inspectorItem)
        splitViewController.splitView.autosaveName = "TermioContentSplit"
        self.splitViewController = splitViewController
        return splitViewController
    }

    /// Keeps the native window title in step with the selected session's working directory.
    /// The title is hidden in the toolbar (`titleVisibility = .hidden`) — the folder name and
    /// git branch are drawn by the custom branch-picker toolbar item instead (CodeEdit's
    /// pattern) — so this only feeds the Window menu and Mission Control. The path is the
    /// session's real working directory, so a worktree session shows where it actually runs.
    private func updateWindowTitle() {
        guard let window else { return }
        guard let id = store.selectedSessionID, let project = store.project(for: id) else {
            window.title = "Termio"
            window.subtitle = ""
            return
        }
        let folder = store.session(id)?.worktreePath ?? project.path
        window.title = abbreviatingHome(folder)
        window.subtitle = ""
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
        // Resolve the terminal background to a *static* color for the window's current
        // appearance, rather than handing the window the dynamic (appearance-resolving) color.
        // In fullscreen the title-bar overlay draws in a light appearance context that does not
        // inherit the window's dark appearance, so the dynamic color resolved to white there —
        // the white title band over the terminal. A statically-resolved color can't flip, so the
        // fullscreen title band matches the terminal. Re-run on every appearance change below.
        window.backgroundColor = translucent ? .clear : resolvedTerminalBackground()
        // Make the titlebar transparent so the window background (the terminal color, set
        // just above) shows straight through the title-bar band instead of AppKit's stock
        // grey chrome material — the seam that otherwise leaves the title/subtitle sitting
        // on a mismatched lighter band. The sidebar's vibrant material still wins on the
        // leading column; this only affects the detail (terminal) side.
        //
        // EXCEPT in fullscreen: on macOS 26 the fullscreen title-bar host doesn't honor a
        // transparent titlebar — it composites a light Liquid Glass material, which read as a
        // white band over a dark terminal. Turning transparency off in fullscreen lets the
        // toolbar fall back to the window's own (dark) titlebar material, which tracks the
        // appearance and matches the terminal far better. Windowed keeps the seamless look.
        window.titlebarAppearsTransparent = !window.styleMask.contains(.fullScreen)
    }

    /// The terminal background color flattened to a static color for the window's current
    /// effective appearance. `AppSettings.terminalBackgroundColor` is a dynamic color that picks
    /// light/dark per drawing context; the window (and especially its fullscreen title-bar
    /// overlay) needs a fixed color so it can't resolve to the wrong side.
    private func resolvedTerminalBackground() -> NSColor {
        let dynamic = settings.terminalBackgroundColor
        // Resolve against the appearance the window is pinned to (not its current
        // `effectiveAppearance`, which can lag `applyChromeAppearance` depending on call order).
        let appearance: NSAppearance
        switch settings.appearanceMode {
        case .light: appearance = NSAppearance(named: .aqua) ?? NSAppearance.currentDrawing()
        case .dark: appearance = NSAppearance(named: .darkAqua) ?? NSAppearance.currentDrawing()
        case .system: appearance = window?.effectiveAppearance ?? NSApp.effectiveAppearance
        }
        var resolved = dynamic
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(cgColor: dynamic.cgColor) ?? dynamic
        }
        return resolved
    }

    /// Drop titlebar transparency *before* the enter-fullscreen animation begins. `applyWindow-
    /// Transparency` keys off `styleMask.contains(.fullScreen)`, which isn't set yet at this point,
    /// so it's set directly here. Without this, the still-transparent titlebar flashes the macOS 26
    /// light fullscreen material (a white band) for the duration of the animation until
    /// `windowDidEnterFullScreen` corrects it.
    func windowWillEnterFullScreen(_ notification: Notification) {
        window?.titlebarAppearsTransparent = false
    }

    /// Re-assert the terminal-colored chrome when crossing the fullscreen boundary. macOS rebuilds
    /// the title-bar host on each transition, so the window background/appearance are re-applied to
    /// keep the fullscreen title band matching the terminal. (On enter, transparency was already
    /// dropped in `windowWillEnterFullScreen`; this confirms the rest of the chrome.)
    func windowDidEnterFullScreen(_ notification: Notification) {
        applyChromeAppearance()
        applyWindowTransparency()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        applyChromeAppearance()
        applyWindowTransparency()
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

    /// Installs a real `NSToolbar` carrying CodeEdit's chrome: a leading navigator toggle, the
    /// system sidebar tracking separator, the custom branch-picker title, an inner tracking
    /// separator aligned to the inspector divider, and a trailing inspector toggle. The delegate
    /// holds the split controller (to bind the inner separator to divider 1) and the store +
    /// settings (to host the branch picker). Toolbar style is version-branched the way CodeEdit
    /// does it: `.automatic` on macOS 26, `.unifiedCompact` before. The baseline separator is
    /// dropped so only the per-split-item separators decide where a hairline shows.
    private func installToolbar() {
        guard let window else { return }
        let delegate = MainToolbarDelegate(store: store, settings: settings)
        toolbarDelegate = delegate
        let toolbar = NSToolbar(identifier: "TermioMainToolbar")
        toolbar.delegate = delegate
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.showsBaselineSeparator = false
        if #available(macOS 26, *) {
            window.toolbarStyle = .automatic
        } else {
            window.toolbarStyle = .unifiedCompact
        }
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

    /// File ▸ Open Project Sandboxed… — same picker, but the opened project runs its
    /// sessions under a Seatbelt sandbox profile. The sandbox is chosen here, at open
    /// time, rather than toggled afterward.
    @objc func openProjectSandboxed(_ sender: Any?) {
        store.presentOpenProjectPanel(sandboxed: true)
    }

    /// View ▸ Show Project Files (and the toolbar's trailing inspector button) —
    /// collapses or expands the file-tree inspector. Reached via the responder chain
    /// (the menu item and toolbar item both target `nil`), like the other app actions.
    @objc func toggleFilesInspector(_ sender: Any?) {
        guard let filesInspectorItem else { return }
        filesInspectorItem.animator().isCollapsed.toggle()
    }

    /// Termio ▸ Check for Updates… — hands off to Sparkle's standard update flow.
    /// Reached via the responder chain (the menu item targets `nil`), the same
    /// nil-target routing the other app-menu items use.
    @objc func checkForUpdates(_ sender: Any?) {
        updaterController.checkForUpdates(sender)
    }
}

/// Delegate for the window's real toolbar, mirroring CodeEdit's chrome. It declares a leading
/// navigator toggle, the AppKit-provided sidebar tracking separator (bound to the sidebar
/// divider), the custom branch-picker title item, and a trailing inspector toggle. The store and
/// settings drive the branch picker.
@MainActor
private final class MainToolbarDelegate: NSObject, NSToolbarDelegate {
    private let store: TermioStore
    private let settings: AppSettings

    init(store: TermioStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    // `.sidebarTrackingSeparator` is AppKit-provided simply by naming the system identifier;
    // AppKit builds it and binds it to the sidebar divider. The navigator/inspector toggles use
    // CodeEdit's symmetric `sidebar.leading`/`sidebar.trailing` glyphs, and the branch picker
    // sits in the content region right after the sidebar separator, so the title reads over the
    // terminal background. (CodeEdit also adds a second hand-built tracking separator over the
    // inspector divider; termio's inspector is a simple summoned file tree, and that item renders
    // as a filled block in this window setup, so it's left out — the toggle alone is enough.)
    private let identifiers: [NSToolbarItem.Identifier] = [
        .toggleNavigator, .flexibleSpace, .sidebarTrackingSeparator, .branchPicker,
        .flexibleSpace, .toggleInspector,
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
        case .toggleNavigator:
            let item = NSToolbarItem(itemIdentifier: .toggleNavigator)
            item.label = "Navigator"
            item.toolTip = "Hide or show the navigator"
            item.image = NSImage(systemSymbolName: "sidebar.leading", accessibilityDescription: "Navigator")
            item.isBordered = true
            // `NSSplitViewController.toggleSidebar(_:)` collapses the first (sidebar) item with
            // the system animation. `nil` target routes up the responder chain to the split
            // controller (the window's content view controller), so no custom action is needed.
            item.action = #selector(NSSplitViewController.toggleSidebar(_:))
            return item
        case .toggleInspector:
            let item = NSToolbarItem(itemIdentifier: .toggleInspector)
            item.label = "Inspector"
            item.toolTip = "Show or hide the project files"
            item.image = NSImage(systemSymbolName: "sidebar.trailing", accessibilityDescription: "Project Files")
            item.isBordered = true
            // `nil` target routes up the responder chain to the app delegate, the same nil-target
            // routing the menu items use.
            item.action = #selector(AppDelegate.toggleFilesInspector(_:))
            return item
        case .branchPicker:
            let item = NSToolbarItem(itemIdentifier: .branchPicker)
            item.view = NSHostingView(rootView: BranchPickerToolbarView()
                .environmentObject(store)
                .environmentObject(settings))
            item.isBordered = false
            return item
        default:
            // `.sidebarTrackingSeparator` and the spaces are provided and styled by AppKit.
            return nil
        }
    }
}

private extension NSToolbarItem.Identifier {
    static let toggleNavigator = NSToolbarItem.Identifier("TermioToggleNavigator")
    static let toggleInspector = NSToolbarItem.Identifier("TermioToggleInspector")
    static let branchPicker = NSToolbarItem.Identifier("TermioBranchPicker")
}

/// The custom title item: the selected session's folder name over its live git branch, drawn as
/// a borderless toolbar view in place of the native title (CodeEdit's `ToolbarBranchPicker`). It
/// observes the store directly, so it tracks the selection and branch without a separate
/// observer. A non-git folder shows just the folder name with a settings-folder glyph.
private struct BranchPickerToolbarView: View {
    @EnvironmentObject var store: TermioStore
    @Environment(\.controlActiveState) private var controlActive

    /// The selected session's working directory: its worktree if it has one, else its project
    /// folder. `nil` when nothing is selected.
    private var folder: String? {
        guard let id = store.selectedSessionID, let project = store.project(for: id) else { return nil }
        return store.session(id)?.worktreePath ?? project.path
    }

    private var title: String {
        guard let folder else { return "Termio" }
        return URL(fileURLWithPath: folder).lastPathComponent
    }

    private var branch: String? {
        guard let folder, let branch = store.branch(forFolder: folder), !branch.isEmpty else { return nil }
        return branch
    }

    private var primaryColor: Color {
        controlActive == .inactive ? Color(nsColor: .disabledControlTextColor) : .primary
    }

    private var secondaryColor: Color {
        controlActive == .inactive ? Color(nsColor: .disabledControlTextColor) : .secondary
    }

    var body: some View {
        HStack(alignment: .center, spacing: 7) {
            Image(systemName: branch != nil ? "arrow.triangle.branch" : "folder.fill.badge.gearshape")
                .foregroundStyle(secondaryColor)
                .font(.system(size: 13))
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(primaryColor)
                    .lineLimit(1)
                    .help(title)
                if let branch {
                    Text(branch)
                        .font(.subheadline)
                        .foregroundStyle(secondaryColor)
                        .lineLimit(1)
                }
            }
        }
        .padding(.leading, 4)
        .frame(minWidth: 80)
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
    // Open the project straight into a Seatbelt sandbox. Shift-⌘O sits right beside
    // the plain Open Project (⌘O), so the two open modes read as a pair.
    let openSandboxed = fileMenu.addItem(
        withTitle: "Open Project Sandboxed…",
        action: #selector(AppDelegate.openProjectSandboxed(_:)),
        keyEquivalent: "O"
    )
    openSandboxed.keyEquivalentModifierMask = [.command, .shift]
    fileItem.submenu = fileMenu

    // Standard Edit menu so copy/paste/select-all responder actions work.
    let editItem = NSMenuItem()
    mainMenu.addItem(editItem)
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = editMenu

    let viewItem = NSMenuItem()
    mainMenu.addItem(viewItem)
    let viewMenu = NSMenu(title: "View")
    // Mirrors Xcode's inspector shortcut (⌥⌘0) for the trailing file-tree panel.
    let toggleFiles = viewMenu.addItem(
        withTitle: "Show Project Files",
        action: #selector(AppDelegate.toggleFilesInspector(_:)),
        keyEquivalent: "0"
    )
    toggleFiles.keyEquivalentModifierMask = [.command, .option]
    viewItem.submenu = viewMenu

    return mainMenu
}
