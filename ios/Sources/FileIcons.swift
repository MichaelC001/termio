import TermioShared
import UIKit

/// The icon beside a file in the inspector tree — the iOS counterpart of the
/// Mac's `FileIconView`, driven by the same shared `LangIconCatalog`: the real
/// language/tool logo when termio bundles one (compiled here into
/// `LangIcons.xcassets`), otherwise the tinted SF Symbol from the shared
/// `FileTypeIcon` map, so a `.ts` reads as the TypeScript mark on both
/// platforms.
enum FileIcons {
    /// Image + tint for a file name. Colored logos carry their own colors
    /// (nil tint); monochrome marks are template assets tinted with label ink
    /// so they stay visible in either appearance, matching the Mac's
    /// `monochromeInk` treatment.
    static func icon(forFileName name: String) -> (image: UIImage?, tint: UIColor?) {
        if let resource = LangIconCatalog.resource(forFileName: name),
           let image = UIImage(named: resource.name) {
            return (image, resource.monochrome ? .label : nil)
        }
        let fallback = FileTypeIcon.icon(for: URL(fileURLWithPath: name))
        return (UIImage(systemName: fallback.symbol), UIColor(fallback.color))
    }
}
