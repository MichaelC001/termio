import SwiftUI

/// Renders an `AgentPreset`'s glyph: a muted SF Symbol for the plain terminal, or
/// a vendor's real brand mark for the coding agents, painted in that vendor's
/// brand color. The terminal symbol is decorative chrome, so it stays a calm
/// `.secondary` grey while the brand marks keep their full-strength vendor color —
/// that contrast is what makes an agent session read as "branded" at a glance.
/// Callers give a point `size`; both kinds are drawn at a matched optical weight
/// so a row of mixed icons stays visually even.
struct AgentIconView: View {
    let agent: AgentPreset
    var size: CGFloat
    var weight: Font.Weight = .regular

    var body: some View {
        switch agent.icon {
        case .systemSymbol(let name):
            Image(systemName: name)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(.secondary)
        case .hugeIcon(let icon):
            // Decorative chrome like the terminal symbol it replaces, so it keeps
            // the same calm `.secondary` grey rather than a vendor color.
            HugeIconView(icon: icon, size: size, color: .secondary)
        case .brand(let logo):
            // A brand mark fills its whole box, where an SF Symbol's glyph sits
            // inside cap height with breathing room; shrinking the box a touch
            // makes the two read at the same optical size side by side.
            BrandLogoShape(logo: logo)
                .fill(logo.tint, style: FillStyle(eoFill: logo.usesEvenOddFill))
                .frame(width: size * 0.82, height: size * 0.82)
        case .brandImage(let asset):
            BrandImageView(asset: asset, size: size)
        }
    }
}

/// Renders a vendor's real favicon image (bundled under `Resources`) as a small
/// rounded tile. Used for marks whose detail a single-fill `BrandLogo` path can't
/// carry. Falls back to empty space if the resource can't be loaded rather than
/// trapping — a missing icon should never crash the sidebar.
struct BrandImageView: View {
    let asset: BrandImageAsset
    var size: CGFloat

    var body: some View {
        if let image = asset.loadImage() {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                // The favicons carry their own dark backgrounds; clip to a rounded
                // tile so they read like the app icons they are at sidebar sizes.
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }
}

extension BrandImageAsset {
    /// Loads the bundled favicon as an `NSImage`, or `nil` if it is missing.
    /// `NSImage` renders both the SVG (Pi) and PNG (OpenCode) sources natively.
    func loadImage() -> NSImage? {
        guard let url = Bundle.module.url(forResource: resourceName, withExtension: fileExtension)
        else { return nil }
        return NSImage(contentsOf: url)
    }
}

extension BrandLogo {
    /// Each vendor's brand color, so an agent session reads as its real product at
    /// a glance. The fixed tints are mid-tone enough to stay legible on both the
    /// light grey badge and a dark sidebar. Codex's mark is monochrome, so it uses
    /// full-strength ink (pure black on light, pure white on dark) — not `.primary`,
    /// which is the ~85%-opacity label color and reads as a washed-out grey next to
    /// the opaque favicon tiles.
    var tint: Color {
        switch self {
        case .claude: return Color(red: 0.851, green: 0.467, blue: 0.341)   // #D97757
        case .codex: return .monochromeInk
        }
    }
}

extension Color {
    /// Pure black in light mode, pure white in dark mode, at full opacity. Unlike
    /// `.primary` (label color, ~85% opacity) this keeps a monochrome brand mark at
    /// its original strength while still adapting to the system appearance.
    static let monochromeInk = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white : .black
    })
}

/// A `Shape` that draws a `BrandLogo` from its embedded SVG path, scaled to fit
/// the available rect (preserving the source 24×24 aspect, centered).
struct BrandLogoShape: Shape {
    let logo: BrandLogo

    func path(in rect: CGRect) -> Path {
        scaledVectorPath(SVGPath(logo.pathData).cgPath, viewBox: logo.viewBox, in: rect)
    }
}

/// Renders a `HugeIcon` as a rounded stroke (Hugeicons' native line style) in the
/// given color, sized to a square `size`-point box. The stroke width tracks the
/// source's 1.5px-on-24 ratio so the line stays optically right at any size, with
/// a small floor so it never thins to a hairline at sidebar sizes.
struct HugeIconView: View {
    let icon: HugeIcon
    var size: CGFloat
    var color: Color

    var body: some View {
        HugeIconShape(icon: icon)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }

    private var lineWidth: CGFloat {
        max(1.1, size * 1.5 / icon.viewBox)
    }
}

/// A `Shape` that draws a `HugeIcon`'s SVG path scaled to fit the rect, to be
/// stroked (not filled) by `HugeIconView`.
struct HugeIconShape: Shape {
    let icon: HugeIcon

    func path(in rect: CGRect) -> Path {
        scaledVectorPath(SVGPath(icon.pathData).cgPath, viewBox: icon.viewBox, in: rect)
    }
}

/// Scales a parsed glyph from its square `viewBox` to fit `rect`, centered,
/// preserving aspect. Shared by the filled brand marks and the stroked Hugeicons.
private func scaledVectorPath(_ glyph: CGPath, viewBox: CGFloat, in rect: CGRect) -> Path {
    let scale = min(rect.width, rect.height) / viewBox
    var transform = CGAffineTransform(
        translationX: rect.midX - viewBox * scale / 2,
        y: rect.midY - viewBox * scale / 2
    )
    .scaledBy(x: scale, y: scale)
    let scaled = glyph.copy(using: &transform) ?? glyph
    return Path(scaled)
}

/// A small parser for the subset of SVG path syntax used by the embedded brand
/// marks — moveto/lineto/horizontal/vertical, cubic and quadratic curves (with
/// their smooth variants), elliptical arcs, and close. The SVG and Core
/// Graphics coordinate spaces both run y-downward, so no axis flip is needed.
private struct SVGPath {
    let pathData: String

    init(_ pathData: String) { self.pathData = pathData }

    var cgPath: CGPath {
        let path = CGMutablePath()
        var scanner = Scanner(pathData)

        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastCubicControl: CGPoint?
        var lastQuadControl: CGPoint?
        var previousCommand: Character = " "

        func reflectedCubic() -> CGPoint {
            guard let last = lastCubicControl, "CcSs".contains(previousCommand) else { return current }
            return CGPoint(x: 2 * current.x - last.x, y: 2 * current.y - last.y)
        }
        func reflectedQuad() -> CGPoint {
            guard let last = lastQuadControl, "QqTt".contains(previousCommand) else { return current }
            return CGPoint(x: 2 * current.x - last.x, y: 2 * current.y - last.y)
        }

        while !scanner.isAtEnd {
            // A bare number means "repeat the previous command"; after a moveto
            // the implicit repeat is a lineto, per the SVG spec.
            var command: Character
            if let explicit = scanner.readCommand() {
                command = explicit
            } else if previousCommand != " " {
                command = previousCommand
                if command == "M" { command = "L" }
                if command == "m" { command = "l" }
            } else {
                break
            }

            let relative = command.isLowercase
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }

            switch command.uppercased() {
            case "M":
                current = point(scanner.readNumber(), scanner.readNumber())
                path.move(to: current)
                subpathStart = current
            case "L":
                current = point(scanner.readNumber(), scanner.readNumber())
                path.addLine(to: current)
            case "H":
                let x = scanner.readNumber()
                current = relative ? CGPoint(x: current.x + x, y: current.y) : CGPoint(x: x, y: current.y)
                path.addLine(to: current)
            case "V":
                let y = scanner.readNumber()
                current = relative ? CGPoint(x: current.x, y: current.y + y) : CGPoint(x: current.x, y: y)
                path.addLine(to: current)
            case "C":
                let c1 = point(scanner.readNumber(), scanner.readNumber())
                let c2 = point(scanner.readNumber(), scanner.readNumber())
                current = point(scanner.readNumber(), scanner.readNumber())
                path.addCurve(to: current, control1: c1, control2: c2)
                lastCubicControl = c2
            case "S":
                let c1 = reflectedCubic()
                let c2 = point(scanner.readNumber(), scanner.readNumber())
                current = point(scanner.readNumber(), scanner.readNumber())
                path.addCurve(to: current, control1: c1, control2: c2)
                lastCubicControl = c2
            case "Q":
                let c = point(scanner.readNumber(), scanner.readNumber())
                current = point(scanner.readNumber(), scanner.readNumber())
                path.addQuadCurve(to: current, control: c)
                lastQuadControl = c
            case "T":
                let c = reflectedQuad()
                current = point(scanner.readNumber(), scanner.readNumber())
                path.addQuadCurve(to: current, control: c)
                lastQuadControl = c
            case "A":
                let rx = scanner.readNumber()
                let ry = scanner.readNumber()
                let rotation = scanner.readNumber()
                let largeArc = scanner.readFlag()
                let sweep = scanner.readFlag()
                let end = point(scanner.readNumber(), scanner.readNumber())
                addArc(to: path, from: current, to: end, rx: rx, ry: ry,
                       rotationDegrees: rotation, largeArc: largeArc, sweep: sweep)
                current = end
            case "Z":
                path.closeSubpath()
                current = subpathStart
            default:
                break
            }

            if command.uppercased() != "C" && command.uppercased() != "S" { lastCubicControl = nil }
            if command.uppercased() != "Q" && command.uppercased() != "T" { lastQuadControl = nil }
            previousCommand = command
        }
        return path
    }

    /// Appends an SVG elliptical arc to `path` as a sequence of cubic Béziers,
    /// using the endpoint-to-center conversion from the SVG implementation notes.
    private func addArc(
        to path: CGMutablePath, from start: CGPoint, to end: CGPoint,
        rx rxIn: CGFloat, ry ryIn: CGFloat, rotationDegrees: CGFloat,
        largeArc: Bool, sweep: Bool
    ) {
        var rx = abs(rxIn), ry = abs(ryIn)
        if rx == 0 || ry == 0 { path.addLine(to: end); return }
        if start == end { return }

        let phi = rotationDegrees * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)

        let dx = (start.x - end.x) / 2, dy = (start.y - end.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy

        let radiiCheck = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if radiiCheck > 1 {
            let scale = sqrt(radiiCheck)
            rx *= scale
            ry *= scale
        }

        let rx2 = rx * rx, ry2 = ry * ry, x1Sq = x1 * x1, y1Sq = y1 * y1
        let numerator = max(0, rx2 * ry2 - rx2 * y1Sq - ry2 * x1Sq)
        let denominator = rx2 * y1Sq + ry2 * x1Sq
        var coefficient = denominator == 0 ? 0 : sqrt(numerator / denominator)
        if largeArc == sweep { coefficient = -coefficient }

        let cxPrime = coefficient * (rx * y1 / ry)
        let cyPrime = coefficient * (-ry * x1 / rx)
        let centerX = cosPhi * cxPrime - sinPhi * cyPrime + (start.x + end.x) / 2
        let centerY = sinPhi * cxPrime + cosPhi * cyPrime + (start.y + end.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let length = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
            let clamped = max(-1, min(1, length == 0 ? 0 : dot / length))
            let result = acos(clamped)
            return ux * vy - uy * vx < 0 ? -result : result
        }

        let ux = (x1 - cxPrime) / rx, uy = (y1 - cyPrime) / ry
        let vx = (-x1 - cxPrime) / rx, vy = (-y1 - cyPrime) / ry
        let startAngle = angle(1, 0, ux, uy)
        var sweepAngle = angle(ux, uy, vx, vy)
        if !sweep && sweepAngle > 0 { sweepAngle -= 2 * .pi }
        if sweep && sweepAngle < 0 { sweepAngle += 2 * .pi }

        let segments = max(1, Int(ceil(abs(sweepAngle) / (.pi / 2))))
        let delta = sweepAngle / CGFloat(segments)
        let controlScale = 4.0 / 3.0 * tan(delta / 4)

        func onEllipse(_ cosA: CGFloat, _ sinA: CGFloat) -> CGPoint {
            let ex = rx * cosA, ey = ry * sinA
            return CGPoint(x: cosPhi * ex - sinPhi * ey + centerX,
                           y: sinPhi * ex + cosPhi * ey + centerY)
        }
        func tangent(_ cosA: CGFloat, _ sinA: CGFloat) -> CGPoint {
            let ex = -rx * sinA, ey = ry * cosA
            return CGPoint(x: cosPhi * ex - sinPhi * ey,
                           y: sinPhi * ex + cosPhi * ey)
        }

        var a = startAngle
        for _ in 0..<segments {
            let cosA = cos(a), sinA = sin(a)
            let cosB = cos(a + delta), sinB = sin(a + delta)
            let p1 = onEllipse(cosA, sinA)
            let p2 = onEllipse(cosB, sinB)
            let t1 = tangent(cosA, sinA)
            let t2 = tangent(cosB, sinB)
            path.addCurve(
                to: p2,
                control1: CGPoint(x: p1.x + controlScale * t1.x, y: p1.y + controlScale * t1.y),
                control2: CGPoint(x: p2.x - controlScale * t2.x, y: p2.y - controlScale * t2.y)
            )
            a += delta
        }
    }
}

/// A forgiving number/command scanner for SVG path data. Handles the quirks the
/// brand marks rely on: implicit separators, signs that start a new number, a
/// second decimal point that ends one (`.686.0608` is two numbers), and arc
/// flags packed as single digits.
private struct Scanner {
    private let characters: [Character]
    private var index = 0

    init(_ string: String) { characters = Array(string) }

    var isAtEnd: Bool {
        var probe = index
        while probe < characters.count, isSeparator(characters[probe]) { probe += 1 }
        return probe >= characters.count
    }

    private func isSeparator(_ c: Character) -> Bool {
        c == " " || c == "," || c == "\n" || c == "\t" || c == "\r"
    }

    private mutating func skipSeparators() {
        while index < characters.count, isSeparator(characters[index]) { index += 1 }
    }

    mutating func readCommand() -> Character? {
        skipSeparators()
        guard index < characters.count, characters[index].isLetter else { return nil }
        defer { index += 1 }
        return characters[index]
    }

    mutating func readNumber() -> CGFloat {
        skipSeparators()
        var text = ""
        if index < characters.count, characters[index] == "+" || characters[index] == "-" {
            text.append(characters[index])
            index += 1
        }
        var seenDot = false
        var seenExponent = false
        while index < characters.count {
            let c = characters[index]
            if c.isNumber {
                text.append(c)
                index += 1
            } else if c == "." && !seenDot && !seenExponent {
                seenDot = true
                text.append(c)
                index += 1
            } else if (c == "e" || c == "E") && !seenExponent {
                seenExponent = true
                text.append(c)
                index += 1
                if index < characters.count, characters[index] == "+" || characters[index] == "-" {
                    text.append(characters[index])
                    index += 1
                }
            } else {
                break
            }
        }
        return CGFloat(Double(text) ?? 0)
    }

    mutating func readFlag() -> Bool {
        skipSeparators()
        guard index < characters.count else { return false }
        let c = characters[index]
        if c == "0" || c == "1" {
            index += 1
            return c == "1"
        }
        return readNumber() != 0
    }
}
