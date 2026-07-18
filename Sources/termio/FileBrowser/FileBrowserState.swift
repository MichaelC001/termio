import AppKit
import Combine
import Foundation

/// The current selection in the file tree, shared between the SwiftUI view (which
/// writes it) and the hosting controller (which reads it to feed Quick Look). Held
/// as its own object so the controller can answer `QLPreviewPanel`'s data-source
/// callbacks without reaching into SwiftUI's view state.
@MainActor
final class FileBrowserState: ObservableObject {
    @Published var selection: URL?
    /// The `NSOutlineView` backing the tree, captured by `FileTreeList` so
    /// `FileBrowserView` can expand a folder on the click that selected it. Not
    /// `@Published` — it's an AppKit escape hatch, not view state.
    weak var outlineView: NSOutlineView?
}
