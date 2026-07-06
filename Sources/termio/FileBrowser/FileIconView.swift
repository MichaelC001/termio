import AppKit
import SwiftUI
import TermioShared

/// The icon shown beside a file: its real language/tool logo when termio bundles one
/// (a Devicon SVG, keyed by extension or exact name via `LangIconCatalog`), otherwise
/// the tinted SF Symbol from `FileTypeIcon`. Both the file tree and the editor header
/// draw through this so a `.ts` reads as the TypeScript mark in either place.
///
/// Monochrome marks — the ones whose SVG is a single near-black silhouette (Rust, Deno,
/// Markdown, YAML, …) — are drawn as an adaptive template tinted with the label ink, so
/// they stay visible on a dark terminal background rather than disappearing into it.
struct FileIconView: View {
    let url: URL
    /// Point size of the square logo box.
    var size: CGFloat = 16
    /// Font size of the SF Symbol fallback (sized independently — a glyph sits inside
    /// its cap height, so it usually wants to run a touch larger than the logo box).
    var symbolSize: CGFloat = 13

    var body: some View {
        if let resource = LangIconCatalog.resource(forFileName: url.lastPathComponent),
           let image = LangIconLoader.shared.image(named: resource.name) {
            if resource.monochrome {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .renderingMode(.template)
                    .foregroundStyle(Color.monochromeInk)
                    .frame(width: size, height: size)
            } else {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
            }
        } else {
            let icon = FileTypeIcon.icon(for: url)
            Image(systemName: icon.symbol)
                .font(.system(size: symbolSize))
                .foregroundStyle(icon.color)
                .frame(width: size)
        }
    }
}

/// Loads and caches the bundled Devicon SVGs as `NSImage`s. `NSImage` rasterizes SVG
/// natively, so each logo stays crisp at any size; the cache keeps a folder of ~100
/// marks from re-decoding on every list-row realization.
@MainActor
final class LangIconLoader {
    static let shared = LangIconLoader()
    private var cache: [String: NSImage] = [:]

    func image(named name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        guard let url = Bundle.termioResources.url(
            forResource: name, withExtension: "svg", subdirectory: "LangIcons"
        ), let image = NSImage(contentsOf: url) else { return nil }
        cache[name] = image
        return image
    }
}
