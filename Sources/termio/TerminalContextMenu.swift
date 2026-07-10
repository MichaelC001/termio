import AppKit
import GhosttyTerminal

/// Ghostty-style right-click menu over the terminal surfaces: Copy/Paste plus
/// the split-pane actions the ⌘⇧P palette offers, so a mouse-first user can
/// split without learning the palette.
///
/// The libghostty wrapper's own `rightMouseDown` either pops a Copy-only menu
/// (over a selection) or forwards the click to the terminal program — the app
/// never gets a say, and the wrapper instantiates its view class itself so a
/// subclass override can't be injected. So the menu is added one level up: a
/// local `rightMouseDown` monitor that spots clicks landing on a terminal
/// surface in the main window and consumes them with termio's menu instead
/// (Ghostty likewise claims right-click for its menu).
@MainActor
final class TerminalContextMenu: NSObject {
    private weak var store: TermioStore?
    // Held for the app's lifetime; never removed.
    private var monitor: Any?
    /// The surface the open menu acts on, resolved at click time.
    private weak var clickedView: TerminalView?

    init(store: TermioStore) {
        self.store = store
        super.init()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { event in
            // Local event monitors are always called on the main thread; the
            // annotation just can't say so (and `NSEvent` isn't `Sendable`, so
            // only the Bool verdict crosses the `assumeIsolated` boundary).
            nonisolated(unsafe) let event = event
            let consumed = MainActor.assumeIsolated { self.intercept(event) }
            return consumed ? nil : event
        }
    }

    /// Returns whether the click was consumed by showing the menu; `false`
    /// lets right-clicks outside the terminal behave as before.
    private func intercept(_ event: NSEvent) -> Bool {
        guard let store,
              let window = event.window,
              window.frameAutosaveName == AppDelegate.mainWindowFrameAutosaveName,
              let contentView = window.contentView,
              // A file editor / diff / trace overlay covers the terminal; its
              // right-clicks (text-view menus) are its own.
              store.openFileURL == nil, store.openDiff == nil, store.openTrace == nil
        else { return false }

        // Resolve the pane by geometry rather than `hitTest`: every activated
        // session stays mounted (invisible ones at full pane size, see
        // `TerminalPane`), and raw AppKit hit-testing doesn't honor SwiftUI's
        // `allowsHitTesting(false)` on those, so the topmost view under the
        // cursor may be a hidden sibling. Visible panes tile without
        // overlapping, so "contains the point and is visible" is unambiguous.
        let point = event.locationInWindow
        let target = terminalViews(in: contentView).first { view in
            guard view.window === window,
                  view.convert(view.bounds, to: nil).contains(point),
                  let id = sessionID(for: view) else { return false }
            return store.visiblePaneIDs.contains(id)
        }
        guard let target else { return false }

        // Focus follows the right-click (the wrapper's own `rightMouseDown`
        // does the same), and the selection is moved synchronously so the
        // split actions below operate on the clicked pane, not a stale one.
        window.makeFirstResponder(target)
        if let id = sessionID(for: target), store.selectedSessionID != id {
            store.selectedSessionID = id
        }
        clickedView = target
        NSMenu.popUpContextMenu(makeMenu(), with: event, for: target)
        return true
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        // Copy/Paste target the surface's own responder actions: copy is a
        // no-op without a selection, and paste routes through ghostty's
        // `paste_from_clipboard` binding so bracketed paste is preserved.
        menu.addItem(surfaceItem("Copy", action: "copy:", symbol: "doc.on.doc"))
        menu.addItem(surfaceItem("Paste", action: "paste:", symbol: "doc.on.clipboard"))
        menu.addItem(.separator())
        menu.addItem(storeItem("Split Right", action: #selector(splitRight), symbol: "rectangle.split.2x1"))
        menu.addItem(storeItem("Split Down", action: #selector(splitDown), symbol: "rectangle.split.1x2"))
        if store?.splitRoot != nil {
            menu.addItem(storeItem("Close Pane", action: #selector(closePane), symbol: "rectangle"))
        }
        return menu
    }

    private func surfaceItem(_ title: String, action: String, symbol: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: NSSelectorFromString(action), keyEquivalent: "")
        item.target = clickedView
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    private func storeItem(_ title: String, action: Selector, symbol: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    @objc private func splitRight() { store?.splitSelectedPane(.horizontal) }
    @objc private func splitDown() { store?.splitSelectedPane(.vertical) }
    @objc private func closePane() { store?.closeSelectedPane() }

    /// All terminal surface views under `root`, in tree order.
    private func terminalViews(in root: NSView) -> [TerminalView] {
        var found: [TerminalView] = []
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            if let terminal = view as? TerminalView { found.append(terminal) }
            stack.append(contentsOf: view.subviews)
        }
        return found
    }

    /// Maps a surface view back to its session through the store's surface
    /// cache — the view and its cached `TerminalViewState` share a controller.
    private func sessionID(for view: TerminalView) -> Session.ID? {
        store?.surfaces.first { $0.value.controller === view.controller }?.key
    }
}
