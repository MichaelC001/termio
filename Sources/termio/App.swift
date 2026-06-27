import AppKit
import Combine
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
    private var menuBar: MenuBarController?
    private var settingsWindow: NSWindow?
    private var settingsObserver: AnyCancellable?

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
        window.title = "termio"
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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
        window.backgroundColor = translucent ? .clear : terminalBackgroundColor()
    }

    /// The terminal surface's background color, so the window chrome can match it.
    /// With a theme selected this is the theme's background; with none, libghostty
    /// renders `TerminalTheme.default` (Alabaster #F7F7F7 in light, Afterglow
    /// #212121 in dark), so the fallback adapts to the system appearance exactly as
    /// the terminal does.
    private func terminalBackgroundColor() -> NSColor {
        if let chrome = settings.chromeTheme {
            return NSColor(chrome.background)
        }
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0x21 / 255.0, green: 0x21 / 255.0, blue: 0x21 / 255.0, alpha: 1)
                : NSColor(srgbRed: 0xF7 / 255.0, green: 0xF7 / 255.0, blue: 0xF7 / 255.0, alpha: 1)
        }
    }

    /// Matches the window's light/dark appearance to the selected terminal theme so
    /// the title bar, traffic lights, and scrollbars agree with the themed chrome.
    /// With no theme chosen the window follows the system appearance again.
    private func applyChromeAppearance() {
        guard let window else { return }
        if let chrome = settings.chromeTheme {
            window.appearance = NSAppearance(named: chrome.isDark ? .darkAqua : .aqua)
        } else {
            window.appearance = nil
        }
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
            window.contentView = NSHostingView(rootView: SettingsView(settings: settings))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
private func buildMainMenu() -> NSMenu {
    let mainMenu = NSMenu()

    let appItem = NSMenuItem()
    mainMenu.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(
        withTitle: "Settings…",
        action: #selector(AppDelegate.showSettings(_:)),
        keyEquivalent: ","
    )
    appMenu.addItem(.separator())
    appMenu.addItem(
        withTitle: "Quit termio",
        action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"
    )
    appItem.submenu = appMenu

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
