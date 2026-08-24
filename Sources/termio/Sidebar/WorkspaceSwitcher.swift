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
            // Which machine, in words, and only when the name does not already
            // say it — an auto-created workspace *is* named after its alias.
            // In words rather than as a mark: a machine's name is the thing a
            // person types, and the row has the room for it.
            if let alias = workspace.deviceAlias,
               !workspace.name.localizedCaseInsensitiveContains(alias) {
                item.attributedTitle = titled(workspace.name, on: alias)
            }
            return item
        }
    }

    /// The row's title with the machine trailing it in the secondary colour, so
    /// the name still reads as the name.
    @MainActor
    private static func titled(_ name: String, on alias: String) -> NSAttributedString {
        let title = NSMutableAttributedString(
            string: name,
            attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.labelColor])
        title.append(NSAttributedString(
            string: "  " + alias,
            attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        return title
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

    /// One fixed box, wide enough for an ordinary name and narrow enough to leave the
    /// sort and `+` buttons clear of NSToolbar's `»` overflow at the navigator's 240pt
    /// minimum (the toggle, this box and those two buttons come to roughly 220).
    ///
    /// Fixed, not sized to the string. A label that measures its own text hands the
    /// toolbar item a new intrinsic width on every switch, and NSToolbar answers by
    /// re-laying out the region — which is what was seen as the name flicking and
    /// shifting as the scope changed. That relayout belongs to AppKit, below SwiftUI,
    /// so the deliberately un-animated transaction in `switchToWorkspace` cannot reach
    /// it. Holding the width constant means there is nothing to re-lay out: no name,
    /// of any length, can put the toolbar back into motion.
    ///
    /// A floor would have hidden this for short names and let it back for long ones.
    /// Measuring the widest name and sizing to that keeps the box honest but needs
    /// text metrics, a font bridge and a re-measure on every rename — machinery in
    /// exchange for slack the flexible space beside it already absorbs.
    private static let nameWidth: CGFloat = 104

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
                // The very font the sidebar's rows and section headers use — not a copy of its
                // definition, which is what this was and what let the two drift on paper. The band
                // and the column below it share an x-height and read as one thing: this names that
                // column, and a size step would separate it from what it names. Rank comes from
                // weight instead — a label larger than the window title beside it is what makes a
                // titlebar look mis-scaled.
                .font(settings.interfaceFont)
                .fontWeight(.medium)
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.middle)
                // Leading, so every name starts at the same x. Centred, a short one would
                // sit in the middle of the box and the label's left edge would move on each
                // switch — the same shift by a different route.
                .frame(width: Self.nameWidth, alignment: .leading)
                // The overlay owns the press, the tooltip, and the accessibility of
                // this control — it is the view under the pointer, so a `.help()` here
                // would be shadowed by it and a SwiftUI accessibility element here would
                // hide it. See `WorkspaceMenuHost`.
                .overlay(WorkspaceMenuPopper(store: store))
                .accessibilityHidden(true)
        }
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

    /// The name as well as the sentence, because the label above draws in a fixed box and
    /// a name too long for it is middle-truncated with nowhere else to be read in place.
    private static func toolTip(for store: TermioStore) -> String {
        "\(store.currentWorkspace.name) — \(localized("The sidebar shows this workspace"))"
    }

    func makeNSView(context: Context) -> WorkspaceMenuHost {
        let view = WorkspaceMenuHost()
        view.store = store
        view.toolTip = Self.toolTip(for: store)
        return view
    }

    func updateNSView(_ nsView: WorkspaceMenuHost, context: Context) {
        nsView.store = store
        // Set here too: the scope changes far more often than this view is made.
        nsView.toolTip = Self.toolTip(for: store)
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
        // This Mac, without asking: the device submenu belongs to the menus that
        // already carry one (File ▸ Workspace and the sidebar `+`), and growing a
        // third here would put a machine list in the switcher, which is the "go to
        // a computer" mode the workspace replaced.
        addAction(localized("New Workspace…"), to: menu, #selector(newWorkspace))
        menu.addItem(.separator())
        // Renaming and removing are in Settings ▸ Workspaces. Creating stays here
        // because it is the one verb that does not need the user to pick which
        // workspace it acts on — the other two do, and this menu can only ever
        // offer them for the row it already shows checked.
        addAction(localized("Workspace Settings…"), to: menu, #selector(openWorkspaceSettings))
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

    @objc private func openWorkspaceSettings() {
        NSApp.sendAction(#selector(AppDelegate.openWorkspaceSettings(_:)), to: nil, from: nil)
    }
}
