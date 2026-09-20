import AppKit
import SwiftUI
import TermioShared

/// The diff header's file name as a jump bar: the files this overlay walks with ← / → are one
/// click away, so a reader goes straight to the file they want instead of stepping to it. Rows
/// come from `walkableSiblings` — the walk's own set, so the menu offers exactly what the arrow
/// keys reach — the file on screen is the checked one, and picking a row re-aims the open diff in
/// place through `onSelect`, so the document is never rebuilt.
enum DiffFileMenu {
    /// One row per walkable sibling, titled the way the Changes list draws the same file: status
    /// letter, name, the directory receding behind it, then the line counts.
    @MainActor
    static func rows(of request: GitDiffRequest, target: AnyObject, action: Selector) -> [NSMenuItem] {
        request.walkableSiblings.map { change in
            let item = NSMenuItem(title: change.name, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = change.path
            item.state = change.path == request.change.path ? .on : .off
            item.attributedTitle = title(of: change)
            return item
        }
    }

    /// AppKit rather than SwiftUI's `Menu` for the rows: only `NSMenuItem` draws a title in more
    /// than one colour, and the row worth scanning here is the Changes list's own — status and
    /// counts carrying their tint, a rename's directory stepping back behind the name.
    @MainActor
    private static func title(of change: GitChange) -> NSAttributedString {
        let title = NSMutableAttributedString(
            string: change.status.letter + "  ",
            attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: NSColor(change.status.tint),
            ])
        title.append(NSAttributedString(
            string: change.name,
            attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: NSColor.labelColor,
            ]))
        if !change.directory.isEmpty {
            title.append(NSAttributedString(
                string: "  " + change.directory,
                attributes: [
                    .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
        }
        let counts: [(count: Int, sign: String, tint: NSColor)] = [
            (change.additions, "+", .systemGreen),
            (change.deletions, "−", .systemRed),
        ]
        for count in counts where count.count > 0 {
            title.append(NSAttributedString(
                string: "  \(count.sign)\(count.count)",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize,
                                                            weight: .medium),
                    .foregroundColor: count.tint,
                ]))
        }
        return title
    }
}

/// The file's name in the diff header, drawn as a closed jump bar: the text handed to it, then a
/// small chevron saying a list opens under the name. The press, the hover cue, the tooltip and the
/// accessibility all belong to the AppKit view over it — see `DiffFileMenuHost`; that is the view
/// under the pointer, so a SwiftUI `.onHover` or `.help` here would never hear about either.
struct DiffFileMenuLabel<Content: View>: View {
    let request: GitDiffRequest
    let onSelect: (GitChange) -> Void
    let content: () -> Content

    @State private var isHighlighted = false

    /// The chip's inset on each side. The leading half is given back below, so the name keeps the
    /// x it had as plain text and the header's spacing stays measured against a label.
    private static var chipInset: CGFloat { 6 }

    init(request: GitDiffRequest,
         onSelect: @escaping (GitChange) -> Void,
         @ViewBuilder content: @escaping () -> Content) {
        self.request = request
        self.onSelect = onSelect
        self.content = content
    }

    var body: some View {
        HStack(spacing: 5) {
            content()
                .lineLimit(1)
                .truncationMode(.tail)
            // The sidebar's own disclosure mark, a quarter-turn down: the same chevron at the same
            // size and weight is what the app already uses to say a list opens under a name.
            HugeIconView(icon: .chevronRight, size: 7.5, color: .secondary, lineWidthOverride: 1.75)
                .rotationEffect(.degrees(90))
        }
        .padding(.horizontal, Self.chipInset)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(isHighlighted ? 0.08 : 0))
                // Hover cues snap: they paint on the next frame and clear on the next frame.
                .animation(nil, value: isHighlighted))
        .padding(.leading, -Self.chipInset)
        .overlay(DiffFileMenuPopper(request: request, onSelect: onSelect,
                                    highlighted: $isHighlighted))
        .accessibilityHidden(true)
    }
}

/// Opens the file menu on click, over the name above it.
private struct DiffFileMenuPopper: NSViewRepresentable {
    let request: GitDiffRequest
    let onSelect: (GitChange) -> Void
    /// Driven by the host below: the pointer entering or leaving, and the menu being up. Hover is
    /// answered there rather than by a SwiftUI `.onHover` for the same reason the tooltip is — that
    /// view is the one the pointer hits, so the label beneath it never learns the pointer arrived.
    @Binding var highlighted: Bool

    func makeNSView(context: Context) -> DiffFileMenuHost {
        let view = DiffFileMenuHost()
        view.request = request
        view.onSelect = onSelect
        view.onHighlight = { highlighted = $0 }
        view.toolTip = localized("Show another file in this diff")
        return view
    }

    func updateNSView(_ nsView: DiffFileMenuHost, context: Context) {
        nsView.request = request
        // Rebound every update: the closure captures this struct's binding, and a stale one writes
        // to a view tree that has been replaced.
        nsView.onSelect = onSelect
        nsView.onHighlight = { highlighted = $0 }
    }
}

/// The click target, and the target of the menu it pops. One class rather than a view plus a
/// coordinator — the menu is built when it opens, out of the request this view already holds, so
/// there is no second place for its contents to live.
private final class DiffFileMenuHost: NSView {
    var request: GitDiffRequest?
    var onSelect: ((GitChange) -> Void)?
    var onHighlight: ((Bool) -> Void)?

    private var hoverTracking: NSTrackingArea?

    /// Flipped so the anchor below reads in the direction the menu opens, rather than depending on
    /// whichever convention the hosting view happens to use.
    override var isFlipped: Bool { true }

    /// A click in a background window opens the menu rather than only raising the window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        showMenu()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHighlight?(true) }

    override func mouseExited(with event: NSEvent) { onHighlight?(false) }

    /// Whether the pointer is over this view right now, asked rather than remembered: the tracking
    /// area is silent while a menu holds the event loop, so this settles the cue on the way out.
    private var isUnderPointer: Bool {
        guard let location = window?.mouseLocationOutsideOfEventStream else { return false }
        return bounds.contains(convert(location, from: nil))
    }

    // The element is this view rather than the text beneath it, so the press has a real
    // implementation and the description cannot disagree with the label drawn.

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .popUpButton }

    override func accessibilityLabel() -> String? { localized("File") }

    override func accessibilityValue() -> Any? { request?.name }

    override func accessibilityPerformPress() -> Bool {
        showMenu()
        return true
    }

    private func showMenu() {
        guard let request else { return }
        let menu = NSMenu()
        for row in DiffFileMenu.rows(of: request, target: self, action: #selector(selectFile(_:))) {
            menu.addItem(row)
        }
        // Held highlighted for as long as the menu is up, the way a pull-down stays pressed under
        // its own menu. `popUp` runs a nested event loop and returns once the menu closes, so the
        // cue is settled on the line after it — from where the pointer actually is, since no exit
        // was delivered while the menu had the loop.
        onHighlight?(true)
        // Anchored under the name the way a pull-down opens, rather than at the pointer the way a
        // context menu does.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
        onHighlight?(isUnderPointer)
    }

    @objc private func selectFile(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String,
              let change = request?.siblings.first(where: { $0.path == path })
        else { return }
        onSelect?(change)
    }
}
