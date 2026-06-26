import AppKit
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
    private let store = TermioStore(projects: Project.sampleProjects())

    func applicationDidFinishLaunching(_ notification: Notification) {
        let root = RootView().environmentObject(store)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "termio"
        window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(rootView: root)
        window.center()
        window.setFrameAutosaveName("TermioMainWindow")
        window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@MainActor
private func buildMainMenu() -> NSMenu {
    let mainMenu = NSMenu()

    let appItem = NSMenuItem()
    mainMenu.addItem(appItem)
    let appMenu = NSMenu()
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
