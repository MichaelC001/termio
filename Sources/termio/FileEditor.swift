import AppKit
import Highlightr
import SwiftUI

/// Routing for a double-clicked file in the inspector: a previewable file (image, PDF, HTML)
/// opens in Quick Look — handled in `FileBrowserHostingController` — and everything else opens in
/// the editor that covers the terminal (`FileEditorView`, driven by `TermioStore.openFileURL`).
enum FileActivation {
    /// File kinds Quick Look renders well on its own, so a double-click previews them rather than
    /// dropping into the text editor. Everything else is treated as editable text.
    static func isPreviewable(_ url: URL) -> Bool {
        previewExtensions.contains(url.pathExtension.lowercased())
    }

    private static let previewExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "bmp", "icns", "svg",
        "pdf", "html", "htm",
    ]
}

/// A caret position for the footer, 1-based the way an editor's status bar reads.
struct EditorCursor: Equatable { var line: Int; var column: Int }

/// The editor that covers the terminal pane: a soft-wrapped, monospaced `NSTextView` whose text is
/// syntax-highlighted by Highlightr (highlight.js), with a slim header (file name + close) and a VS
/// Code-style footer (language · caret · encoding). The file is read once on open and **auto-saved**
/// — a short idle after the last keystroke flushes it to disk, and closing flushes any pending
/// write — so there is no Save button. Escape (or the close button) dismisses back to the terminal.
/// Non-text files that can't be decoded as UTF-8 show a short notice rather than a wall of mojibake.
struct FileEditorView: View {
    let url: URL
    @ObservedObject var settings: AppSettings
    /// Dismisses the overlay (clears `store.openFileURL`) and hands focus back to the terminal.
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    @State private var text: String
    /// The text last written to disk, so auto-save only writes on a genuine change.
    @State private var savedText: String
    @State private var loadFailed: Bool
    @State private var saveError: String?
    @State private var cursor: EditorCursor?
    /// The pending debounced write, cancelled and rescheduled on each keystroke.
    @State private var saveTask: Task<Void, Never>?

    /// The highlight.js language id, sniffed once from the file extension (`nil` lets highlight.js
    /// auto-detect). Stable for the lifetime of the open file.
    private let language: String?
    /// The file's path relative to its git root — shown next to the name like the diff header
    /// (`GitDiffView`), so the two overlays read the same. `nil` outside a repo.
    private let relativePath: String?

    init(url: URL, settings: AppSettings, onClose: @escaping () -> Void) {
        self.url = url
        self.settings = settings
        self.onClose = onClose
        let contents = try? String(contentsOf: url, encoding: .utf8)
        _text = State(initialValue: contents ?? "")
        _savedText = State(initialValue: contents ?? "")
        _loadFailed = State(initialValue: contents == nil)
        self.language = Self.highlightLanguage(for: url)
        self.relativePath = Self.repoRelativePath(for: url)
    }

    /// Walks up from the file to its git root and returns the path relative to it (the form the diff
    /// header shows, e.g. `core 2/lib/fs.ts`). `nil` when the file isn't inside a git work tree.
    private static func repoRelativePath(for url: URL) -> String? {
        let file = url.standardizedFileURL
        let manager = FileManager.default
        var dir = file.deletingLastPathComponent()
        while dir.path != "/" {
            if manager.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                return String(file.path.dropFirst(dir.path.count + 1))
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    private var isDirty: Bool { text != savedText }

    /// The editor font, borrowed from the terminal so an opened file reads in the same face the
    /// agent's output does. Falls back to the system monospace when no family is pinned.
    private var editorFont: NSFont {
        let size = max(11, settings.fontSize)
        if !settings.fontFamily.isEmpty, let font = NSFont(name: settings.fontFamily, size: size) {
            return font
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Foreground/caret fall back to the terminal theme's colors (the rest of the chrome's source of
    /// truth) so plain text and the insertion point sit on the terminal background cleanly.
    private var chrome: ChromeTheme? { settings.chromeTheme(for: colorScheme) }
    private var caretColor: NSColor { chrome.map { NSColor($0.accent) } ?? .textColor }
    /// Muted line-number ink — the theme foreground dimmed, so the gutter recedes against the
    /// code the way Xcode's does (and always contrasts the terminal background, whatever it is).
    private var lineNumberColor: NSColor {
        (chrome.map { NSColor($0.foreground) } ?? .textColor).withAlphaComponent(0.4)
    }

    var body: some View {
        // The editor's chrome (header, gutter) already sits in the safe content area below the
        // toolbar — only the *background* bleeds up under the transparent titlebar, for a seamless
        // fill with the terminal. (No manual titlebar inset: the overlay's content top is already at
        // the safe-area top; padding it again just opened a dead band above the header.)
        Group {
            if loadFailed {
                ContentUnavailableView(
                    "Can't Open as Text",
                    systemImage: "doc.questionmark",
                    description: Text("\(url.lastPathComponent) isn't a UTF-8 text file.")
                )
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()
                    HighlightedTextView(
                        text: $text,
                        cursor: $cursor,
                        language: language,
                        theme: colorScheme == .dark ? "xcode-dark" : "xcode",
                        font: editorFont,
                        backgroundColor: settings.terminalBackgroundColor,
                        caretColor: caretColor,
                        lineNumberColor: lineNumberColor
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    statusBar
                }
            }
        }
        // Match the diff overlay (`GitDiffView`): a plain VStack whose background bleeds under the
        // titlebar — no outer `.frame`, which was reserving an empty band above the header.
        .background(Color(nsColor: settings.terminalBackgroundColor).ignoresSafeArea())
        // Auto-save: debounce a write after each edit; Escape closes (flushing first).
        .onChange(of: text) { scheduleSave() }
        .onExitCommand { close() }
        // A safety flush if the overlay goes away without the close button (file switch, app quit).
        .onDisappear { saveTask?.cancel(); writeIfNeeded() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            // A file-type glyph, tinted by kind — sized to match the diff header's leading status
            // badge (12–13pt in a 16-wide slot) so the editor and diff headers are the same height.
            let icon = FileTypeIcon.icon(for: url)
            Image(systemName: icon.symbol)
                .font(.system(size: 13))
                .foregroundStyle(icon.color)
                .frame(width: 16)
            Text(url.lastPathComponent)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            // The repo-relative path next to the name, exactly like the diff header.
            if let relativePath {
                Text(relativePath)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            // A faint dot while an auto-save is pending — quieter than a word, no button to click.
            if isDirty {
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 5, height: 5)
                    .help("Unsaved changes — saving…")
                    .transition(.opacity)
            }
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: settings.terminalBackgroundColor))
        .animation(.easeOut(duration: 0.15), value: isDirty)
    }

    /// A slim VS Code-style footer: language on the left, cursor position and file facts on the
    /// right. The caret tracks as you move around the file.
    private var statusBar: some View {
        HStack(spacing: 0) {
            Text(languageName)
            Spacer()
            if let cursor {
                statusItem("Ln \(cursor.line), Col \(cursor.column)")
            }
            statusItem("UTF-8")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(nsColor: settings.terminalBackgroundColor))
    }

    private func statusItem(_ text: String) -> some View {
        Text(text).padding(.leading, 14)
    }

    /// A human-readable name for the detected language ("Plain Text" when auto/unknown).
    private var languageName: String {
        guard let language else { return "Plain Text" }
        return language.prefix(1).uppercased() + language.dropFirst()
    }

    /// (Re)arms the debounced write — the previous pending save is cancelled so only a quiet pause
    /// after the last keystroke actually hits the disk.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            if Task.isCancelled { return }
            writeIfNeeded()
        }
    }

    /// Closes the overlay, flushing any pending edit first so nothing is lost on the way out.
    private func close() {
        saveTask?.cancel()
        writeIfNeeded()
        onClose()
    }

    /// Writes the buffer to disk if it differs from what's already there. The single place a save
    /// happens, shared by the debounce, the close button, and the disappear safety net.
    private func writeIfNeeded() {
        guard text != savedText else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            savedText = text
            saveError = nil
        } catch {
            saveError = "Save failed: \(error.localizedDescription)"
        }
    }

    /// Maps a file to a highlight.js language id, matched against grammars the bundled highlight.js
    /// actually ships (e.g. it has no `toml`/`jsonc` — those fold into `ini`/`json`). The whole file
    /// name is checked first (so `Dockerfile`, `Cargo.lock`, `yarn.lock`, … resolve by name, not
    /// extension), then the extension. Unknown files return `nil` to let highlight.js auto-detect.
    private static func highlightLanguage(for url: URL) -> String? {
        // Extension-less or specially-named files, keyed by the whole (lowercased) name.
        switch url.lastPathComponent.lowercased() {
        case "dockerfile", "containerfile": return "dockerfile"
        case "makefile", "gnumakefile": return "makefile"
        case "cmakelists.txt": return "cmake"
        case "gemfile", "podfile", "rakefile", "gemfile.lock": return "ruby"
        case "cargo.lock", "poetry.lock", "pipfile": return "ini" // TOML-ish (no toml grammar)
        case "yarn.lock": return "yaml"
        case ".gitignore", ".dockerignore", ".npmignore": return "bash"
        case ".env", ".editorconfig", ".npmrc": return "ini"
        case "nginx.conf": return "nginx"
        default: break
        }

        switch url.pathExtension.lowercased() {
        case "swift": return "swift"
        case "js", "mjs", "cjs", "jsx": return "javascript"
        case "ts", "tsx", "mts", "cts": return "typescript"
        case "py", "pyw", "pyi": return "python"
        case "rb": return "ruby"
        case "go": return "go"
        case "rs": return "rust"
        case "c", "h": return "c"
        case "cpp", "cc", "cxx", "hpp", "hh", "hxx": return "cpp"
        case "m", "mm": return "objectivec"
        case "cs": return "csharp"
        case "java": return "java"
        case "kt", "kts": return "kotlin"
        case "php": return "php"
        case "dart": return "dart"
        case "lua": return "lua"
        case "r": return "r"
        case "scala", "sc": return "scala"
        case "hs": return "haskell"
        case "ex", "exs": return "elixir"
        case "erl", "hrl": return "erlang"
        case "clj", "cljs", "edn": return "clojure"
        case "pl", "pm": return "perl"
        // JSON family — highlight.js has no jsonc/json5 grammar, so they fold into json. Most
        // `.lock` files (deno.lock, flake.lock, composer.lock, Pipfile.lock) are JSON too.
        case "json", "jsonc", "json5", "lock": return "json"
        case "yml", "yaml": return "yaml"
        case "toml", "ini", "conf", "cfg", "properties": return "ini"
        case "md", "markdown", "mdx": return "markdown"
        case "sh", "bash", "zsh", "fish", "ksh": return "bash"
        case "ps1", "psm1": return "powershell"
        case "bat", "cmd": return "dos"
        case "html", "htm", "xml", "plist", "svg", "xhtml": return "xml"
        case "css": return "css"
        case "scss", "sass": return "scss"
        case "less": return "less"
        case "sql": return "sql"
        case "graphql", "gql": return "graphql"
        case "proto": return "protobuf"
        case "cmake": return "cmake"
        case "mk", "mak": return "makefile"
        case "diff", "patch": return "diff"
        default: return nil
        }
    }
}

/// A soft-wrapped, monospaced `NSTextView` whose backing store is Highlightr's `CodeAttributedString`
/// — so syntax highlighting happens in the text storage as the buffer changes, no manual re-coloring.
/// AppKit's prose conveniences (smart quotes, dashes, replacement, spell-check) are off for code, and
/// long lines wrap rather than scroll horizontally.
private struct HighlightedTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var cursor: EditorCursor?
    let language: String?
    let theme: String
    let font: NSFont
    let backgroundColor: NSColor
    let caretColor: NSColor
    let lineNumberColor: NSColor

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

        let textView = NSTextView(frame: .zero, textContainer: container)
        textView.delegate = context.coordinator
        textView.isEditable = true
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
        guard let textView = scrollView.documentView as? NSTextView else { return }
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

/// An Xcode-style line-number gutter for the editor's text view: right-aligned numbers, one per
/// logical line. A soft-wrapped line keeps a single number on its first visual row (drawn at the
/// first line fragment of each paragraph), and a trailing empty line is numbered like Xcode's.
private final class LineNumberRulerView: NSRulerView {
    private var numberFont: NSFont
    private var numberColor: NSColor
    private var gutterColor: NSColor

    override var isOpaque: Bool { true }

    init(scrollView: NSScrollView, editorFont: NSFont, numberColor: NSColor, gutterColor: NSColor) {
        self.numberFont = Self.gutterFont(for: editorFont)
        self.numberColor = numberColor
        self.gutterColor = gutterColor
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = scrollView.documentView
        ruleThickness = 42
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func restyle(editorFont: NSFont, numberColor: NSColor, gutterColor: NSColor) {
        numberFont = Self.gutterFont(for: editorFont)
        self.numberColor = numberColor
        self.gutterColor = gutterColor
        needsDisplay = true
    }

    /// Slightly smaller than the editor's font, with monospaced digits so the numbers stay aligned.
    private static func gutterFont(for editorFont: NSFont) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: max(9, editorFont.pointSize - 1.5), weight: .regular)
    }

    override func draw(_ dirtyRect: NSRect) {
        gutterColor.setFill()
        bounds.fill()
        drawLineNumbers()
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        // The full ruler is drawn in `draw(_:)` so AppKit never paints its default ruler chrome.
    }

    private func drawLineNumbers() {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        let content = textView.string as NSString
        let inset = textView.textContainerInset.height
        // Maps the text view's y-coordinates into the ruler's (carries the scroll offset).
        let yOffset = convert(NSPoint.zero, from: textView).y
        let attributes: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: numberColor]

        let drawNumber: (Int, CGFloat) -> Void = { number, fragMinY in
            let string = "\(number)" as NSString
            let size = string.size(withAttributes: attributes)
            let x = self.ruleThickness - size.width - 6
            let y = fragMinY + inset + yOffset
            let topClipInset = self.window.map { 1 / $0.backingScaleFactor } ?? 0
            guard y > self.bounds.minY + topClipInset else { return }
            string.draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
        }

        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        let visibleCharRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)

        // Line number of the first visible character: 1 + the newlines before it.
        var lineNumber = 1
        var index = 0
        while index < visibleCharRange.location {
            if content.character(at: index) == 10 { lineNumber += 1 }
            index += 1
        }

        // One number per logical line (paragraph), at its first line fragment.
        content.enumerateSubstrings(
            in: visibleCharRange,
            options: [.byParagraphs, .substringNotRequired]
        ) { _, lineRange, _, _ in
            let glyph = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: lineRange.location, length: 0),
                actualCharacterRange: nil
            )
            let fragRect = layoutManager.lineFragmentRect(forGlyphAt: glyph.location, effectiveRange: nil)
            drawNumber(lineNumber, fragRect.minY)
            lineNumber += 1
        }

        // The trailing empty line (empty document, or one ending in a newline) gets a number too —
        // only drawn when the document's end is actually in view.
        if NSMaxRange(visibleCharRange) >= content.length,
           layoutManager.extraLineFragmentTextContainer != nil {
            drawNumber(lineNumber, layoutManager.extraLineFragmentRect.minY)
        }
    }
}
