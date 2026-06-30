import AppKit
import Highlightr
import SwiftUI

/// A soft-wrapped, monospaced `NSTextView` whose backing store is Highlightr's `CodeAttributedString`
/// — so syntax highlighting happens in the text storage as the buffer changes, no manual re-coloring.
/// AppKit's prose conveniences (smart quotes, dashes, replacement, spell-check) are off for code, and
/// long lines wrap rather than scroll horizontally.
struct HighlightedTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var cursor: EditorCursor?
    let language: String?
    let theme: String
    let font: NSFont
    let backgroundColor: NSColor
    let caretColor: NSColor
    let lineNumberColor: NSColor
    /// When false the text stays selectable (copyable) but cannot be typed into — the read-only
    /// preview path. Defaults to editable so the inspector's own opens are unchanged.
    var isEditable: Bool = true
    /// Invoked when the user presses ⌘S — flushes the buffer to disk immediately.
    let onSave: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, cursor: $cursor) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = context.coordinator.textStorage
        _ = storage.highlightr.setTheme(to: theme)
        storage.highlightr.theme.setCodeFont(font)
        storage.language = language
        context.coordinator.appliedTheme = theme
        context.coordinator.appliedFont = font
        context.coordinator.appliedLanguage = language

        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer()
        container.widthTracksTextView = true          // wrap to the view width
        layoutManager.addTextContainer(container)

        let textView = SavingTextView(frame: .zero, textContainer: container)
        textView.onSave = onSave
        textView.delegate = context.coordinator
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.usesFindBar = true
        textView.textContainerInset = NSSize(width: 6, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        apply(to: textView)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = backgroundColor
        // Paint the clip view the same color so the ruler/text seam can never show as a hairline.
        scrollView.contentView.drawsBackground = true
        scrollView.contentView.backgroundColor = backgroundColor

        // Xcode-style line-number gutter down the leading edge.
        let ruler = LineNumberRulerView(
            scrollView: scrollView, editorFont: font,
            numberColor: lineNumberColor, gutterColor: backgroundColor
        )
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        context.coordinator.ruler = ruler

        // The ruler must fully redraw on three events: lines added/removed, the view re-wrapping on
        // resize (both via the text view's frame changes), and — crucially — *scrolling*. AppKit's
        // copy-on-scroll only repaints the newly-exposed strip, so without a full invalidation the
        // gutter's absolutely-positioned numbers desync into a garbled smear. Observing the clip
        // view's bounds change and forcing `needsDisplay` repaints every number at its true position.
        textView.postsFrameChangedNotifications = true
        context.coordinator.observeFrame(of: textView)
        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observeScroll(of: scrollView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? SavingTextView else { return }
        // Refresh the save closure each update so ⌘S always flushes the latest buffer (the closure
        // captures the view's current state, which SwiftUI re-creates on every change).
        textView.onSave = onSave
        if textView.isEditable != isEditable { textView.isEditable = isEditable }
        let coordinator = context.coordinator
        let storage = coordinator.textStorage

        // Re-theme / re-font only when they actually change (an appearance or font-setting switch) —
        // not on every keystroke. Each is a whole-document recolor, so doing it per edit would jank
        // large files; the text storage already re-highlights edited ranges incrementally on its own.
        var needsRehighlight = false
        if coordinator.appliedTheme != theme {
            _ = storage.highlightr.setTheme(to: theme)
            coordinator.appliedTheme = theme
            needsRehighlight = true
        }
        if coordinator.appliedFont != font {
            storage.highlightr.theme.setCodeFont(font)
            coordinator.appliedFont = font
            needsRehighlight = true
        }
        if coordinator.appliedLanguage != language {
            coordinator.appliedLanguage = language
            needsRehighlight = true
        }
        // Setting the language re-runs the highlight over the whole document, applying any new theme
        // colors — so it doubles as the "re-color everything" trigger after a theme/font change.
        if needsRehighlight { storage.language = language }

        // Only overwrite on a genuine external change — writing on every keystroke would stomp the
        // insertion point. In practice text only changes from inside this view.
        if textView.string != text { textView.string = text }
        apply(to: textView)
        scrollView.backgroundColor = backgroundColor
        scrollView.contentView.backgroundColor = backgroundColor
        coordinator.ruler?.restyle(editorFont: font, numberColor: lineNumberColor, gutterColor: backgroundColor)
    }

    private func apply(to textView: NSTextView) {
        textView.font = font
        textView.backgroundColor = backgroundColor
        textView.insertionPointColor = caretColor
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let textStorage = CodeAttributedString()
        /// What's currently applied to the text storage, so `updateNSView` only re-themes / re-fonts
        /// / re-highlights when something genuinely changed (not on every keystroke).
        var appliedTheme: String?
        var appliedFont: NSFont?
        var appliedLanguage: String?
        weak var ruler: LineNumberRulerView?
        private let text: Binding<String>
        private let cursor: Binding<EditorCursor?>

        init(text: Binding<String>, cursor: Binding<EditorCursor?>) {
            self.text = text
            self.cursor = cursor
        }

        /// Redraw the gutter whenever the text view's frame changes — new lines grow it, a window
        /// resize re-wraps it; both shift where each line sits.
        func observeFrame(of textView: NSTextView) {
            NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: textView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.ruler?.needsDisplay = true }
            }
        }

        /// Fully redraw the gutter on every scroll tick — AppKit's copy-on-scroll otherwise leaves
        /// stale, smeared numbers (and numbers stranded in the titlebar strip) behind.
        func observeScroll(of scrollView: NSScrollView) {
            NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.ruler?.needsDisplay = true }
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            ruler?.needsDisplay = true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let location = textView.selectedRange().location
            let full = textView.string as NSString
            guard location <= full.length else { return }
            // Line = lines up to the caret; column = characters past the last newline + 1.
            let lines = full.substring(to: location).components(separatedBy: "\n")
            cursor.wrappedValue = EditorCursor(line: lines.count, column: (lines.last?.count ?? 0) + 1)
        }
    }
}

/// An `NSTextView` that intercepts ⌘S to flush a manual save before AppKit routes it anywhere else,
/// then lets every other key equivalent fall through unchanged. The editor auto-saves on idle, so
/// this only serves the reflex of pressing ⌘S — there is still no Save button.
private final class SavingTextView: NSTextView {
    var onSave: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "s" {
            onSave?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
