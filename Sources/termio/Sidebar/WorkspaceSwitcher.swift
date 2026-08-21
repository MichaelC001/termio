import AppKit
import SwiftUI
import TermioShared

/// The workspace rows, in the order every surface shows them: one item per
/// workspace, the one on screen checked, the first nine carrying ⌘1…9.
///
/// One builder for both menus that draw them — the sidebar switcher and File ▸
/// Workspace — because the digit is positional. Two menus numbering their own
/// rows could disagree about which workspace ⌘2 reaches, and a number that lies
/// is worse than no number at all.
enum WorkspaceMenu {
    /// `representedObject` carries the workspace's uuid string, which is what
    /// `action` reads back — the one thing both callers' handlers share.
    ///
    /// The key equivalents are live only in the menu bar's copy: AppKit matches a
    /// keystroke against the main menu, so the same items in a pull-down draw the
    /// glyphs without claiming ⌘1…9 a second time.
    @MainActor
    static func rows(in store: TermioStore, target: AnyObject, action: Selector) -> [NSMenuItem] {
        let shortcuts = KeybindingStore.workspaceShortcuts
        return store.orderedWorkspaces.enumerated().map { index, workspace in
            let item = NSMenuItem(title: workspace.name, action: action, keyEquivalent: "")
            if index < shortcuts.count {
                item.keyEquivalent = shortcuts[index].keyEquivalent
                item.keyEquivalentModifierMask = shortcuts[index].keyEquivalentModifierMask
            }
            item.target = target
            item.representedObject = workspace.id.uuidString
            item.state = workspace.id == store.currentWorkspaceID ? .on : .off
            return item
        }
    }
}

/// The workspace switcher, in the sidebar's own toolbar region: which scope you
/// are in, and the control that changes it. It sits in the strip above the list
/// rather than in a row of its own, next to the navigator toggle and the
/// sidebar's other actions — the band belongs to the column below it, and a first
/// row that is not a session is a row the tree has to explain.
///
/// Quiet by design — it names the workspace and nothing else — and absent
/// entirely while there is only one, so a user who never makes a second never
/// sees it.
struct WorkspaceSwitcherToolbarView: View {
    @EnvironmentObject var store: TermioStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.controlActiveState) private var controlActive

    /// Long names truncate rather than push the sort and `+` buttons toward
    /// NSToolbar's `»` overflow: the sidebar region has only the room the
    /// navigator's minimum thickness gives it.
    private static let nameWidthCeiling: CGFloat = 130

    var body: some View {
        // The single-workspace collapse. Not "hidden but present": with one scope
        // there is no switch to make, and a control that always reads the same
        // word is a label for a decision the user never took.
        if store.hasMultipleWorkspaces {
            let current = store.currentWorkspace
            // The name and nothing else. No device mark — the rows below already say
            // which machine they are on — and no menu chevron: the toolbar band is
            // three glyphs wide, and every point this control spends on decoration is
            // a point the name truncates at.
            Text(current.name)
                .font(nameFont)
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: Self.nameWidthCeiling)
                .fixedSize()
                // The overlay owns the press, the tooltip, and the accessibility of
                // this control — it is the view under the pointer, so a `.help()` here
                // would be shadowed by it and a SwiftUI accessibility element here would
                // hide it. See `WorkspaceMenuHost`.
                .overlay(WorkspaceMenuPopper(store: store))
                .accessibilityHidden(true)
        }
    }

    /// A step above the sidebar's own row text: this names the whole column, so it
    /// reads as that column's title rather than as one more row of it. Derived from
    /// the interface size rather than fixed, so it still follows the density
    /// preference the rows below it follow.
    private var nameFont: Font {
        let size = settings.interfaceFontSize + 2
        return settings.interfaceFontFamily.isEmpty
            ? .system(size: size)
            : .custom(settings.interfaceFontFamily, size: size)
    }

    // Matched to the sidebar toolbar's native glyphs (the `+` new-terminal item, the
    // sort pull-down): those are bordered `NSToolbarItem`s, which tint their template
    // symbol at full-strength `labelColor`, so the name sits at `.primary` to read as
    // one control band with them rather than a dimmer `.secondary` label.
    private var color: Color {
        controlActive == .inactive ? Color(nsColor: .disabledControlTextColor) : .primary
    }
}

/// Opens the switcher's menu on click, over the label above it.
///
/// AppKit rather than SwiftUI's `Menu` because only `NSMenuItem` draws both halves
/// a row needs at once: a checkmark in the state column for the workspace on
/// screen, and the ⌘-digit that reaches it, right-aligned in the column macOS puts
/// shortcuts in. SwiftUI offers one or the other — an inline `Picker` checkmarks,
/// a `Button` takes `.keyboardShortcut` — and `.keyboardShortcut` would also
/// *claim* ⌘1…9 for as long as this view is mounted, a second live binding racing
/// File ▸ Workspace for the same keystroke.
private struct WorkspaceMenuPopper: NSViewRepresentable {
    let store: TermioStore

    func makeNSView(context: Context) -> WorkspaceMenuHost {
        let view = WorkspaceMenuHost()
        view.store = store
        view.toolTip = localized("The sidebar shows this workspace")
        return view
    }

    func updateNSView(_ nsView: WorkspaceMenuHost, context: Context) {
        nsView.store = store
    }
}

/// The click target, and the target of the menu it pops. One class rather than a
/// view plus a coordinator: the menu is built when it opens, out of the store this
/// view already holds, so there is no second place for its contents to live.
private final class WorkspaceMenuHost: NSView {
    weak var store: TermioStore?

    /// Flipped so the anchor below reads in the direction the menu opens, rather
    /// than depending on whichever convention the hosting view happens to use.
    override var isFlipped: Bool { true }

    /// A click in a background window opens the menu rather than only raising the
    /// window — the switcher is often the reason the window is being reached for.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        showMenu()
    }

    // MARK: - Accessibility
    //
    // The element is this view rather than the `Text` beneath it. A SwiftUI
    // `.accessibilityAddTraits(.isButton)` only sets a trait — nothing there answers
    // a press — so the control announced itself as a button and then did nothing,
    // which the `Menu` it replaced did not do. Answering here gives the press a real
    // implementation and one description that cannot disagree with the label drawn.

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .popUpButton }
    override func accessibilityLabel() -> String? { localized("Workspace") }
    override func accessibilityValue() -> Any? { store?.currentWorkspace.name }

    override func accessibilityPerformPress() -> Bool {
        showMenu()
        return true
    }

    private func showMenu() {
        guard let store else { return }
        let menu = NSMenu()
        for row in WorkspaceMenu.rows(in: store, target: self, action: #selector(switchToWorkspace(_:))) {
            menu.addItem(row)
        }
        menu.addItem(.separator())
        // This Mac, without asking: the device submenu belongs to the menus that
        // already carry one (File ▸ Workspace and the sidebar `+`), and growing a
        // third here would put a machine list in the switcher, which is the "go to
        // a computer" mode the workspace replaced.
        addAction(localized("New Workspace…"), to: menu, #selector(newWorkspace))
        addAction(localized("Rename Workspace…"), to: menu, #selector(renameWorkspace))
        // Removing the last workspace is refused in the store — the sidebar has to
        // have a scope to show — and this menu only opens while there is more than
        // one, so the row is always live where it is drawn.
        addAction(localized("Remove Workspace"), to: menu, #selector(removeWorkspace))
        // No device verb here, deliberately. A machine you can *go to* is the
        // mode this scope replaced: it made the sidebar answer "which computer"
        // when the question is "which work". A device is a place a new thing is
        // put — New Terminal on it, Clone to it, File ▸ Connect to… for a box
        // never reached — never a place the window travels to.

        // Anchored under the label the way a pull-down opens, rather than at the
        // pointer the way a context menu does.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }

    private func addAction(_ title: String, to menu: NSMenu, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func switchToWorkspace(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) else { return }
        store?.switchToWorkspace(id)
    }

    @objc private func newWorkspace() {
        store?.presentNewWorkspacePanel(on: .thisMac)
    }

    @objc private func renameWorkspace() {
        guard let store else { return }
        store.presentRenameWorkspacePanel(store.currentWorkspaceID)
    }

    @objc private func removeWorkspace() {
        guard let store else { return }
        store.confirmRemoveWorkspace(store.currentWorkspaceID)
    }
}
