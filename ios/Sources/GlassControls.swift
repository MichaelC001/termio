import SwiftUI
import TermioShared
import UIKit

extension UIFont {
    /// Telegram's counter type: SF Rounded + tabular digits — every numbered
    /// badge and count label in the app draws from this one recipe.
    static func roundedCounter(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
}

extension UIButton {
    /// iMessage-style floating control: on iOS 26 the symbol rides a circular
    /// Liquid Glass button (the system look for controls floating over
    /// content — back, compose, close); earlier it stays the flat symbol.
    /// Only for free-floating buttons — controls inside pills, rows, or
    /// keyboards keep their plain style, matching Messages.
    func applyGlassSymbol(_ symbol: String, pointSize: CGFloat = 15) {
        if #available(iOS 26.0, *) {
            var config = UIButton.Configuration.glass()
            config.image = UIImage(systemName: symbol)
            config.cornerStyle = .capsule
            config.preferredSymbolConfigurationForImage = .init(pointSize: pointSize, weight: .semibold)
            configuration = config
        } else {
            setImage(UIImage(systemName: symbol), for: .normal)
        }
    }

    /// The Hugeicons twin of `applyGlassSymbol`, for floating buttons whose glyph
    /// should read from the same stroke family as the native tab bar and sidebar
    /// rows. `boxSize` is the glyph's drawn size in points; the stroke is the
    /// shared 1.5px-on-24 recipe.
    func applyGlassIcon(_ icon: HugeIcon, boxSize: CGFloat) {
        let image = icon.strokeImage(boxSize: boxSize)
        if #available(iOS 26.0, *) {
            var config = UIButton.Configuration.glass()
            config.image = image
            config.cornerStyle = .capsule
            configuration = config
        } else {
            setImage(image, for: .normal)
        }
    }
}

extension HugeIcon {
    /// The glyph as a tintable template `UIImage` — a bitmap for UIKit chrome
    /// like the native tab bar, where SwiftUI's `HugeIconView` can't be used
    /// directly. Same stroke recipe (1.5px-on-24 with the hairline floor,
    /// round caps); the path is inset by the stroke's half-width so round
    /// caps at the glyph's edge don't clip against the bitmap bounds.
    func strokeImage(boxSize: CGFloat, strokeWeight: CGFloat = 1.5) -> UIImage {
        let lineWidth = max(1.1, boxSize * strokeWeight / viewBox)
        let bounds = CGRect(x: 0, y: 0, width: boxSize, height: boxSize)
        let path = HugeIconShape(icon: self)
            .path(in: bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
            .cgPath
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        return renderer.image { context in
            let cg = context.cgContext
            cg.setStrokeColor(UIColor.white.cgColor)
            cg.setLineWidth(lineWidth)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            cg.addPath(path)
            cg.strokePath()
        }.withRenderingMode(.alwaysTemplate)
    }
}
