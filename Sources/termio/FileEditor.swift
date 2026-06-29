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

    init(url: URL, settings: AppSettings, onClose: @escaping () -> Void) {
        self.url = url
        self.settings = settings
        self.onClose = onClose
        let contents = try? String(contentsOf: url, encoding: .utf8)
        _text = State(initialValue: contents ?? "")
        _savedText = State(initialValue: contents ?? "")
        _loadFailed = State(initialValue: contents == nil)
        self.language = Self.highlightLanguage(for: url)
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

    var body: some View {
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
                        caretColor: caretColor
                    )
                    Divider()
                    statusBar
                }
            }
        }
        // Opaque terminal-colored fill so the overlay fully covers the terminal, running up under
        // the toolbar like the terminal itself.
        .background(Color(nsColor: settings.terminalBackgroundColor).ignoresSafeArea())
        // Auto-save: debounce a write after each edit; Escape closes (flushing first).
        .onChange(of: text) { scheduleSave() }
        .onExitCommand { close() }
        // A safety flush if the overlay goes away without the close button (file switch, app quit).
        .onDisappear { saveTask?.cancel(); writeIfNeeded() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            // A file-type glyph, tinted by kind — a quick visual anchor for what's open.
            Image(systemName: fileIcon.symbol)
                .font(.system(size: 13))
                .foregroundStyle(fileIcon.color)
                .frame(width: 16)
            Text(url.lastPathComponent)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
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

    /// An SF Symbol + tint for the open file's kind — purely cosmetic, falls back to a plain doc.
    private var fileIcon: (symbol: String, color: Color) {
        switch url.pathExtension.lowercased() {
        case "swift": return ("swift", .orange)
        case "js", "jsx", "mjs", "cjs", "ts", "tsx": return ("curlybraces", .yellow)
        case "py": return ("chevron.left.forwardslash.chevron.right", .blue)
        case "rb": return ("diamond", .red)
        case "go": return ("g.circle", .cyan)
        case "rs": return ("gearshape.2", .orange)
        case "c", "h", "cpp", "cc", "hpp", "m", "mm": return ("c.circle", .indigo)
        case "json": return ("curlybraces.square", .green)
        case "yml", "yaml", "toml", "ini", "conf", "cfg": return ("slider.horizontal.3", .gray)
        case "md", "markdown", "txt", "rst": return ("text.alignleft", .secondary)
        case "sh", "bash", "zsh", "fish": return ("apple.terminal", .green)
        case "html", "htm", "xml": return ("chevron.left.slash.chevron.right", .orange)
        case "css", "scss", "sass", "less": return ("paintbrush", .pink)
        default: return ("doc.text", .secondary)
        }
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

    /// Maps a file extension to a highlight.js language id. Unknown extensions return `nil`, which
    /// lets highlight.js auto-detect (or render plainly if it can't tell).
    private static func highlightLanguage(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "swift": return "swift"
        case "js", "mjs", "cjs", "jsx": return "javascript"
        case "ts", "tsx": return "typescript"
        case "py": return "python"
        case "rb": return "ruby"
        case "go": return "go"
        case "rs": return "rust"
        case "c", "h": return "c"
        case "cpp", "cc", "cxx", "hpp", "hh": return "cpp"
        case "m", "mm": return "objectivec"
        case "cs": return "csharp"
        case "java": return "java"
        case "kt", "kts": return "kotlin"
        case "php": return "php"
        case "json": return "json"
        case "yml", "yaml": return "yaml"
        case "toml", "ini", "conf", "cfg": return "ini"
        case "md", "markdown": return "markdown"
        case "sh", "bash", "zsh", "fish": return "bash"
        case "html", "htm", "xml", "plist": return "xml"
        case "css": return "css"
        case "scss", "sass": return "scss"
        case "less": return "less"
        case "sql": return "sql"
        case "lua": return "lua"
        case "r": return "r"
        case "scala": return "scala"
        case "hs": return "haskell"
        case "ex", "exs": return "elixir"
        case "diff", "patch": return "diff"
        case "dockerfile": return "dockerfile"
        default:
            return url.lastPathComponent.lowercased() == "dockerfile" ? "dockerfile" : nil
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

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, cursor: $cursor) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = context.coordinator.textStorage
        storage.language = language
        _ = storage.highlightr.setTheme(to: theme)
        storage.highlightr.theme.setCodeFont(font)

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
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let storage = context.coordinator.textStorage
        // Re-theme/refont live (e.g. the user switches appearance) — setting the language re-runs
        // the highlight so the new theme colors take effect on the existing text.
        if storage.highlightr.theme.codeFont != font {
            storage.highlightr.theme.setCodeFont(font)
        }
        _ = storage.highlightr.setTheme(to: theme)
        storage.highlightr.theme.setCodeFont(font)
        storage.language = language
        // Only overwrite on a genuine external change — writing on every keystroke would stomp the
        // insertion point. In practice text only changes from inside this view.
        if textView.string != text { textView.string = text }
        apply(to: textView)
        scrollView.backgroundColor = backgroundColor
    }

    private func apply(to textView: NSTextView) {
        textView.font = font
        textView.backgroundColor = backgroundColor
        textView.insertionPointColor = caretColor
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let textStorage = CodeAttributedString()
        private let text: Binding<String>
        private let cursor: Binding<EditorCursor?>

        init(text: Binding<String>, cursor: Binding<EditorCursor?>) {
            self.text = text
            self.cursor = cursor
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
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
