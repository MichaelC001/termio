import Foundation

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
