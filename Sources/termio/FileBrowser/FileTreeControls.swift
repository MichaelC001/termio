import Foundation
import SwiftUI

/// The one quiet-chip chrome worn by every inspector pane-header icon control — the
/// explorer/Changes buttons, the Issues refresh & filter, the ↗ Open-on-GitHub, and the
/// detail's hide-list / maximize / close. A 22×22 hit target with a faint rounded fill that
/// fades in on hover; the glyph itself is coloured secondary→primary by its host. Factored out
/// so a `Button` and a `Menu` label render pixel-identical chrome despite being different types.
struct TreeHeaderChip: ViewModifier {
    @Binding var hovering: Bool
    /// A toggle that is on keeps the chip, as if hovered.
    var isOn = false

    func body(content: Content) -> some View {
        content
            // The window's one glyph button size (`ChromeGlyph`), so the panel's headers match
            // the cards' and the sidebar's.
            .frame(width: ChromeGlyph.frame.width, height: ChromeGlyph.frame.height)
            .background(ChromeHoverChip(isHovering: hovering || isOn))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// A quiet icon button for the explorer / Changes pane headers. The explorer's file
/// actions draw VS Code's own codicon glyphs (see `Codicon`) so the toolbar matches
/// VS Code; the Changes pane uses SF Symbols. Both render quiet `.secondary` at rest,
/// brightening to primary on hover over the shared `TreeHeaderChip` fill.
struct TreeHeaderButton: View {
    /// An SF Symbol, a VS Code codicon, or a Hugeicons stroke glyph — the icon
    /// sources the pane header toolbars draw from.
    enum Source {
        case symbol(String)
        case codicon(Codicon)
        case huge(HugeIcon)
    }

    let source: Source
    let help: String
    let action: () -> Void
    var isOn = false
    @State private var isHovering = false

    init(codicon: Codicon, help: String, action: @escaping () -> Void) {
        self.source = .codicon(codicon)
        self.help = help
        self.action = action
    }

    init(symbol: String, help: String, isOn: Bool = false, action: @escaping () -> Void) {
        self.source = .symbol(symbol)
        self.help = help
        self.isOn = isOn
        self.action = action
    }

    init(huge: HugeIcon, help: String, action: @escaping () -> Void) {
        self.source = .huge(huge)
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            icon.modifier(TreeHeaderChip(hovering: $isHovering, isOn: isOn))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private var icon: some View {
        switch source {
        case .symbol(let name):
            Image(systemName: name)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: ChromeGlyph.size))
                .foregroundStyle(isHovering || isOn ? Color.primary : Color.secondary)
        case .codicon(let codicon):
            CodiconView(icon: codicon, size: ChromeGlyph.size, color: isHovering ? .primary : .secondary)
        case .huge(let icon):
            HugeIconView(icon: icon, size: ChromeGlyph.size(for: icon), color: isHovering ? .primary : .secondary,
                         lineWidthOverride: ChromeGlyph.lineWidth())
        }
    }
}

/// The right-click menu actions the tree's rows invoke: `newFile`/`newFolder`
/// (created inside the given directory), `rename`, and `delete`. Bundled so
/// `FileRow` carries one value rather than a fistful of closures. (Single-click
/// open is driven by the List's native selection, not a row action — see
/// `FileBrowserView`. Reveal in Finder / Copy Path need no view state, so they
/// live directly in the row menu.)
struct FileTreeActions {
    let newFile: (_ directory: URL) -> Void
    let newFolder: (_ directory: URL) -> Void
    let rename: (URL) -> Void
    let delete: (URL) -> Void
    /// Types the row's path into the selected session's agent prompt — Cursor's
    /// "Add File to Chat" verb, on the same shell-quoted token a drag onto the
    /// terminal inserts.
    let addToChat: (URL) -> Void
    /// Read at menu-open time so the item tracks the live session: a plain shell
    /// has no chat to add to, so the row doesn't offer one.
    let canAddToChat: () -> Bool
}
