import AppKit
import PDFKit
import SwiftUI
import WebKit

/// Read-only preview that covers the terminal pane for previewable files (image, PDF, HTML) — the
/// visual counterpart of `FileEditorView`. Double-clicking such a file opens it in place over the
/// terminal (the surface keeps running underneath) instead of a detached Quick Look window, so a
/// previewed image/PDF/page reads as part of the same workspace as the editor. Escape or the close
/// button dismisses it back to the terminal.
struct FilePreviewView: View {
    let url: URL
    @ObservedObject var settings: AppSettings
    let displayName: String?
    /// False for content copied from an SSH host. A failed raster decode must
    /// stay inert instead of handing attacker-controlled bytes to WebKit.
    let allowsWebFallback: Bool
    /// Dismisses the overlay (clears `store.openFileURL`) and hands focus back to the terminal.
    let onClose: () -> Void

    private enum Kind { case image, pdf, web }

    init(
        url: URL,
        settings: AppSettings,
        displayName: String? = nil,
        allowsWebFallback: Bool = true,
        onClose: @escaping () -> Void
    ) {
        self.url = url
        self.settings = settings
        self.displayName = displayName
        self.allowsWebFallback = allowsWebFallback
        self.onClose = onClose
    }

    private var fileName: String { displayName ?? url.lastPathComponent }

    private var kind: Kind {
        switch url.pathExtension.lowercased() {
        case "pdf": return .pdf
        case "html", "htm": return .web
        default: return .image
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        // Opaque terminal-colored fill so the overlay fully covers the terminal, running up under
        // the toolbar like the terminal itself.
        .background(Color(nsColor: settings.terminalBackgroundColor).ignoresSafeArea())
        .onExitCommand(perform: onClose)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: kind == .pdf ? "doc.richtext" : (kind == .web ? "globe" : "photo"))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(fileName)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            // Close moved to the toolbar (a bordered, Liquid Glass button on the terminal
            // column's trailing edge); this trailing spacer keeps the file name left-aligned.
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: settings.terminalBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .pdf:
            PDFPreview(url: url)
        case .web:
            WebPreview(url: url)
        case .image:
            // NSImage decodes the raster formats; anything it can't (e.g. some SVGs) falls back to
            // the web view, which renders vector art reliably. The image fits the pane by default —
            // large images scale down to fit rather than overflow, small ones center.
            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if Self.usesWebFallback(
                imageDecoded: false, allowsWebFallback: allowsWebFallback
            ) {
                WebPreview(url: url)
            } else {
                ContentUnavailableView(
                    "Can't Preview",
                    huge: .fileQuestion,
                    description: Text("“\(fileName)” isn't a supported image.")
                )
            }
        }
    }

    /// Internal so the security boundary has a direct regression test.
    static func usesWebFallback(
        imageDecoded: Bool,
        allowsWebFallback: Bool
    ) -> Bool {
        !imageDecoded && allowsWebFallback
    }
}

/// A `PDFView` over a file URL, scaled to fit on the terminal background.
private struct PDFPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = PDFDocument(url: url)
        view.autoScales = true
        view.backgroundColor = .clear
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
    }
}

/// A `WKWebView` rendering a local file (HTML pages, and SVGs that `NSImage` can't decode).
private struct WebPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.setValue(false, forKey: "drawsBackground")
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if view.url != url {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }
}
