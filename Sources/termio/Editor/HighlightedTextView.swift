import AppKit
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
    /// The full-width wash under the caret's line (Xcode-style), already dimmed to sit on any
    /// terminal background. Only drawn while the buffer is editable — a read-only peek has no
    /// caret, so a highlighted line would just be a mystery stripe.
    let currentLineColor: NSColor
    /// When false the text stays selectable (copyable) but cannot be typed into — the read-only
    /// preview path. Defaults to editable so the inspector's own opens are unchanged.
    var isEditable: Bool = true
    /// A 1-based line to scroll to and flash (a content-search hit). Applied once on creation and
    /// again whenever the value changes — clicking a different hit in the same file re-scrolls.
    var jumpToLine: Int? = nil
    /// Invoked when the user presses ⌘S — flushes the buffer to disk immediately.
    let onSave: () -> Void
    /// Jump-to-definition (⌘-click on an identifier, or ⌃⌘J at the caret), handed the UTF-16
    /// offset of the symbol. `nil` — no language server for this file — leaves the whole
    /// gesture layer dormant: no underline, no hand cursor, clicks behave as stock.
    var onDefinitionRequest: ((Int) -> Void)? = nil
    /// Hover documentation: given the UTF-16 offset under a dwelling ⌘-hover, returns the
    /// markdown to show in a popover (`nil` shows nothing).
    var hoverProvider: ((Int) async -> String?)? = nil

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
        textView.onDefinitionRequest = onDefinitionRequest
        textView.hoverProvider = hoverProvider
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

        // Reveal the requested line once the view has a real frame — at make time it hasn't been
        // laid out, so scrolling now would land nowhere.
        if let jumpToLine {
            context.coordinator.appliedJumpLine = jumpToLine
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                Self.reveal(line: jumpToLine, in: textView)
            }
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? SavingTextView else { return }
        // Refresh the save closure each update so ⌘S always flushes the latest buffer (the closure
        // captures the view's current state, which SwiftUI re-creates on every change).
        textView.onSave = onSave
        textView.onDefinitionRequest = onDefinitionRequest
        textView.hoverProvider = hoverProvider
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

        // A new jump target while the same file stays open (the user clicked another search hit).
        if jumpToLine != coordinator.appliedJumpLine {
            coordinator.appliedJumpLine = jumpToLine
            if let jumpToLine { Self.reveal(line: jumpToLine, in: textView) }
        }
    }

    private func apply(to textView: NSTextView) {
        textView.font = font
        textView.backgroundColor = backgroundColor
        textView.insertionPointColor = caretColor
        if let saving = textView as? SavingTextView {
            saving.currentLineColor = currentLineColor
            // The matched pair glows in the caret's own accent, dimmed to a wash.
            saving.bracketHighlightColor = caretColor.withAlphaComponent(0.28)
        }
    }

    /// Scrolls the 1-based `line` into view, parks the caret at its start, and flashes the find
    /// indicator over it — Xcode's jump-to-line gesture. The caret is placed with a zero-length
    /// selection (not the whole line) so a keystroke in an editable buffer can't wipe the line.
    private static func reveal(line: Int, in textView: NSTextView) {
        let full = textView.string as NSString
        guard full.length > 0 else { return }
        var location = 0, current = 1
        while current < line, location < full.length {
            location = NSMaxRange(full.lineRange(for: NSRange(location: location, length: 0)))
            current += 1
        }
        let lineRange = full.lineRange(for: NSRange(location: min(location, full.length - 1), length: 0))
        textView.setSelectedRange(NSRange(location: lineRange.location, length: 0))
        textView.scrollRangeToVisible(lineRange)
        textView.showFindIndicator(for: lineRange)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let textStorage = CodeAttributedString()
        /// What's currently applied to the text storage, so `updateNSView` only re-themes / re-fonts
        /// / re-highlights when something genuinely changed (not on every keystroke).
        var appliedTheme: String?
        var appliedFont: NSFont?
        var appliedLanguage: String?
        /// The last jump target acted on, so `updateNSView` only re-scrolls on a genuine new hit.
        var appliedJumpLine: Int?
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
            (textView as? SavingTextView)?.caretDidMove()
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
///
/// It also carries the editor's code-intelligence gestures, all dormant unless a language server
/// owns the file (`onDefinitionRequest` set): ⌘-hover underlines the identifier under the cursor
/// IDE-style, ⌘-click jumps to its definition, ⌃⌘J jumps from the caret (Xcode's key), and a
/// ⌘-hover that *dwells* shows the hover documentation in a transient popover. The underline is a
/// layout-manager temporary attribute — it never touches the Highlightr text storage, so it can't
/// trigger a re-highlight or pollute undo.
private final class SavingTextView: NSTextView {
    var onSave: (() -> Void)?
    var onDefinitionRequest: ((Int) -> Void)?
    var hoverProvider: ((Int) async -> String?)?
    /// Full-width wash under the caret's line; `.clear` (or a read-only buffer) draws nothing.
    var currentLineColor: NSColor = .clear { didSet { needsDisplay = true } }
    /// Background wash on a bracket pair when the caret sits against one of them.
    var bracketHighlightColor: NSColor = .clear

    /// The identifier currently underlined under a ⌘-hover.
    private var linkRange: NSRange?
    /// The bracket pair currently washed, so the previous pair can be cleanly un-washed.
    private var bracketRanges: [NSRange] = []
    /// The armed dwell → hover-popover chain, cancelled whenever the target changes.
    private var hoverTask: Task<Void, Never>?
    private var hoverPopover: NSPopover?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, event.charactersIgnoringModifiers == "s" {
            onSave?()
            return true
        }
        if modifiers == [.command, .control], event.charactersIgnoringModifiers == "j",
           let onDefinitionRequest {
            let caret = selectedRange().location
            if identifierRange(at: caret) != nil || caret > 0 && identifierRange(at: caret - 1) != nil {
                onDefinitionRequest(caret)
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Current line

    /// Xcode-style band under the logical line holding the caret (all of its wrapped rows),
    /// drawn behind the text. Only for a zero-length selection — a real selection is its own
    /// highlight — and only while editable, since a read-only peek shows no caret.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard isEditable, currentLineColor.alphaComponent > 0,
              let layoutManager, let textContainer else { return }
        let selection = selectedRange()
        guard selection.length == 0 else { return }
        let text = string as NSString

        var lineRect: NSRect
        if text.length == 0 || (selection.location == text.length && text.character(at: text.length - 1) == 0x0A) {
            // The empty trailing line (or empty document) has no glyphs — AppKit tracks its
            // fragment separately.
            lineRect = layoutManager.extraLineFragmentRect
            if lineRect.isEmpty {
                lineRect = NSRect(x: 0, y: 0, width: 0, height: layoutManager.defaultLineHeight(for: font ?? .systemFont(ofSize: 12)))
            }
        } else {
            let caret = min(selection.location, text.length - 1)
            let lineRange = text.lineRange(for: NSRange(location: caret, length: 0))
            let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        }
        lineRect.origin.y += textContainerOrigin.y
        lineRect.origin.x = 0
        lineRect.size.width = bounds.width
        guard lineRect.intersects(rect) else { return }
        currentLineColor.setFill()
        lineRect.fill()
    }

    /// Selection moved: the line band follows the caret, and the bracket wash re-derives.
    func caretDidMove() {
        needsDisplay = true
        updateBracketMatch()
    }

    // MARK: Bracket matching

    /// Washes the bracket beside the caret and its partner. Plain text-scan matching — a bracket
    /// inside a string or comment can fool it, the classic lightweight-editor tradeoff; the scan
    /// is bounded so an unbalanced megafile can't stall caret movement.
    private func updateBracketMatch() {
        if !bracketRanges.isEmpty, let layoutManager {
            for range in bracketRanges {
                layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
            }
            bracketRanges = []
        }
        guard bracketHighlightColor.alphaComponent > 0, let layoutManager else { return }
        let selection = selectedRange()
        guard selection.length == 0 else { return }
        let text = string as NSString
        // The bracket just left of the caret wins (the one you typed or stepped past), else the
        // one right under it.
        for index in [selection.location - 1, selection.location]
        where index >= 0 && index < text.length {
            guard let match = matchingBracket(for: index, in: text) else { continue }
            bracketRanges = [NSRange(location: index, length: 1), NSRange(location: match, length: 1)]
            for range in bracketRanges {
                layoutManager.addTemporaryAttribute(
                    .backgroundColor, value: bracketHighlightColor, forCharacterRange: range
                )
            }
            return
        }
    }

    private func matchingBracket(for index: Int, in text: NSString) -> Int? {
        let pairs: [(open: unichar, close: unichar)] = [(40, 41), (91, 93), (123, 125)] // () [] {}
        let character = text.character(at: index)
        if let pair = pairs.first(where: { $0.open == character }) {
            return scanForMatch(from: index, in: text, pair: pair, forward: true)
        }
        if let pair = pairs.first(where: { $0.close == character }) {
            return scanForMatch(from: index, in: text, pair: pair, forward: false)
        }
        return nil
    }

    private func scanForMatch(
        from index: Int, in text: NSString, pair: (open: unichar, close: unichar), forward: Bool
    ) -> Int? {
        var depth = 0
        var position = index
        var steps = 0
        while steps < 100_000 {
            let character = text.character(at: position)
            if character == pair.open { depth += forward ? 1 : -1 }
            else if character == pair.close { depth += forward ? -1 : 1 }
            if depth == 0 { return position == index ? nil : position }
            position += forward ? 1 : -1
            guard position >= 0, position < text.length else { return nil }
            steps += 1
        }
        return nil
    }

    // MARK: ⌘-hover / ⌘-click

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["lsp"] != nil {
            removeTrackingArea(area)
        }
        guard onDefinitionRequest != nil else { return }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: ["lsp": true]
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard onDefinitionRequest != nil,
              event.modifierFlags.contains(.command),
              let index = characterIndex(at: event.locationInWindow),
              let range = identifierRange(at: index)
        else {
            clearLink()
            return
        }
        guard range != linkRange else { return }
        clearLink()
        linkRange = range
        layoutManager?.addTemporaryAttributes(
            [.underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand],
            forCharacterRange: range
        )
        armHover(for: range)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        clearLink()
    }

    override func flagsChanged(with event: NSEvent) {
        if !event.modifierFlags.contains(.command) { clearLink() }
        super.flagsChanged(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           let onDefinitionRequest,
           let range = linkRange,
           let index = characterIndex(at: event.locationInWindow),
           NSLocationInRange(index, range) {
            // Swallow the click: stock ⌘-click starts a discontiguous selection, which would
            // fight the jump.
            clearLink()
            onDefinitionRequest(range.location)
            return
        }
        clearLink()
        super.mouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        clearLink()
        super.scrollWheel(with: event)
    }

    private func clearLink() {
        hoverTask?.cancel()
        hoverTask = nil
        hoverPopover?.close()
        hoverPopover = nil
        guard let range = linkRange else { return }
        linkRange = nil
        layoutManager?.removeTemporaryAttribute(.underlineStyle, forCharacterRange: range)
        layoutManager?.removeTemporaryAttribute(.cursor, forCharacterRange: range)
    }

    /// The character under `windowPoint`, or `nil` when the point isn't over actual glyphs (past
    /// the line end, below the last line — where AppKit clamps to the nearest index).
    private func characterIndex(at windowPoint: NSPoint) -> Int? {
        guard let layoutManager, let textContainer else { return nil }
        let local = convert(windowPoint, from: nil)
        let containerPoint = NSPoint(
            x: local.x - textContainerOrigin.x,
            y: local.y - textContainerOrigin.y
        )
        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(
            for: containerPoint, in: textContainer, fractionOfDistanceThroughGlyph: &fraction
        )
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textContainer
        )
        guard glyphRect.insetBy(dx: -2, dy: -2).contains(containerPoint) else { return nil }
        return layoutManager.characterRange(
            forGlyphRange: NSRange(location: glyphIndex, length: 1), actualGlyphRange: nil
        ).location
    }

    /// The identifier (alphanumerics + `_`) spanning `index`, or `nil` when the character there
    /// isn't part of one.
    private func identifierRange(at index: Int) -> NSRange? {
        let text = string as NSString
        guard index >= 0, index < text.length, Self.isIdentifierChar(text.character(at: index))
        else { return nil }
        var start = index
        while start > 0, Self.isIdentifierChar(text.character(at: start - 1)) { start -= 1 }
        var end = index + 1
        while end < text.length, Self.isIdentifierChar(text.character(at: end)) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    private static func isIdentifierChar(_ unit: unichar) -> Bool {
        unit == UInt16(UnicodeScalar("_").value)
            || (UnicodeScalar(unit).map { CharacterSet.alphanumerics.contains($0) } ?? false)
    }

    // MARK: Hover documentation

    /// After a short dwell on the underlined identifier, asks the provider for hover markdown and
    /// shows it in a transient popover anchored to the word. Moving off, releasing ⌘, scrolling,
    /// or clicking all tear it down via `clearLink`.
    private func armHover(for range: NSRange) {
        guard let hoverProvider else { return }
        hoverTask?.cancel()
        hoverTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            guard let markdown = await hoverProvider(range.location) else { return }
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self, self.linkRange == range else { return }
                self.showHoverPopover(markdown: markdown, over: range)
            }
        }
    }

    private func showHoverPopover(markdown: String, over range: NSRange) {
        guard let layoutManager, let textContainer else { return }
        hoverPopover?.close()
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: range, actualCharacterRange: nil
        )
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        let controller = NSViewController()
        controller.view = NSHostingView(rootView: LSPHoverContent(markdown: markdown))
        popover.contentViewController = controller
        popover.show(relativeTo: rect, of: self, preferredEdge: .maxY)
        hoverPopover = popover
    }
}

/// The hover popover's body: the server's markdown, code-styled where fenced, capped to a
/// readable column and height. Deliberately plain — a tooltip, not a browser.
private struct LSPHoverContent: View {
    let markdown: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    if segment.isCode {
                        Text(segment.text)
                            .font(.system(size: 11.5, design: .monospaced))
                            .textSelection(.enabled)
                    } else {
                        Text(attributed(segment.text))
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 440)
        .frame(maxHeight: 320)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Splits on fenced code blocks so signatures render monospaced; everything else goes through
    /// Foundation's inline-markdown parser (bold/italic/code spans — enough for hover prose).
    private var segments: [(text: String, isCode: Bool)] {
        var result: [(String, Bool)] = []
        var inCode = false
        var current: [String] = []
        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                let text = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { result.append((text, inCode)) }
                current = []
                inCode.toggle()
            } else {
                current.append(line)
            }
        }
        let text = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { result.append((text, inCode)) }
        return result
    }

    private func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
