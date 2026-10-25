import AppKit
import IOSurface
import QuartzCore
import SwiftUI

/// The live simulator display: the device's own IOSurface as a layer's contents,
/// in its bezel at the device's real proportion, aspect-fit in the pane, with the mouse as a
/// finger and the keyboard typing into whatever field has focus in the simulator.
///
/// The surface is never turned into an image. CoreAnimation samples it on the
/// GPU, so a frame costs the main thread one contents swap and nothing else.
final class SimulatorScreenView: NSView {
    var screen: SimulatorScreen? {
        didSet {
            guard screen != oldValue else { return }
            // A turn of the same device only moves the layers.
            if let screen, let oldValue, screen.udid == oldValue.udid, screen.stream == oldValue.stream {
                needsLayout = true
                return
            }
            SimulatorHost.shared.stopPresenting(for: self)
            screenLayer.contents = nil
            chrome = screen.flatMap { SimulatorChrome.load(for: $0) }
            applyChrome()
            needsLayout = true
            guard let screen else { return }
            SimulatorHost.shared.present(stream: screen.stream, for: self) { [weak self] surface in
                self?.show(surface)
            }
        }
    }

    private let bezelLayer = CALayer()
    private let screenLayer = CALayer()
    private let maskLayer = CALayer()
    private var chrome: SimulatorChrome?
    private var touching = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        bezelLayer.backgroundColor = NSColor.black.cgColor
        // The band of metal round the glass, as a hairline.
        bezelLayer.borderColor = NSColor(white: 0.32, alpha: 1).cgColor
        bezelLayer.borderWidth = 1
        bezelLayer.cornerCurve = .continuous
        screenLayer.contentsGravity = .resize
        screenLayer.magnificationFilter = .linear
        screenLayer.minificationFilter = .trilinear
        screenLayer.cornerCurve = .continuous
        maskLayer.contentsGravity = .resize
        layer?.addSublayer(bezelLayer)
        layer?.addSublayer(screenLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        MainActor.assumeIsolated { SimulatorHost.shared.stopPresenting(for: self) }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let geometry = self.geometry
        // The surface is the panel; turned about its centre so the interface
        // reads upright inside the interface-shaped rect the bezel surrounds.
        let quarter = screen.map(Self.isQuarter) ?? false
        let rect = geometry.screen
        screenLayer.setAffineTransform(.identity)
        screenLayer.bounds = CGRect(
            origin: .zero,
            size: quarter ? CGSize(width: rect.height, height: rect.width) : rect.size)
        screenLayer.position = CGPoint(x: rect.midX, y: rect.midY)
        screenLayer.setAffineTransform(CGAffineTransform(rotationAngle: screen.map(Self.angle) ?? 0))
        maskLayer.frame = screenLayer.bounds
        let screenRadius = geometry.cornerRadius
        // Without the device's own mask, a plain continuous corner of the same radius.
        screenLayer.cornerRadius = chrome?.mask == nil ? screenRadius : 0
        screenLayer.masksToBounds = chrome?.mask == nil
        let bezel = geometry.bezel
        bezelLayer.isHidden = geometry.screen.isEmpty
        bezelLayer.frame = geometry.screen.insetBy(dx: -bezel, dy: -bezel)
        // Concentric with the screen's corner, so the bezel is one even width all round.
        bezelLayer.cornerRadius = screenRadius + bezel
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        [bezelLayer, screenLayer, maskLayer].forEach { $0.contentsScale = scale }
        applyChrome()
    }

    private func applyChrome() {
        let scale = window?.backingScaleFactor ?? 2
        if let mask = chrome?.mask {
            maskLayer.contents = mask.layerContents(forContentsScale: scale)
            screenLayer.mask = maskLayer
        } else {
            screenLayer.mask = nil
        }
    }

    private static func isQuarter(_ screen: SimulatorScreen) -> Bool {
        screen.rotation == "rot90" || screen.rotation == "rot270"
    }

    /// The panel's turn back to upright, counterclockwise-positive as a
    /// layer measures it — the same angles the helper turns its screenshots by.
    private static func angle(_ screen: SimulatorScreen) -> CGFloat {
        switch screen.rotation {
        case "rot90": -.pi / 2
        case "rot180": .pi
        case "rot270": .pi / 2
        default: 0
        }
    }

    /// The simulator renders every frame into the same surface, and
    /// CoreAnimation will not re-sample contents it believes it already holds —
    /// so each frame clears and re-sets them, in one transaction so no frame is
    /// ever committed blank.
    private func show(_ surface: IOSurface?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        screenLayer.contents = nil
        screenLayer.contents = surface
        CATransaction.commit()
    }

    // MARK: Coordinates

    /// Where the screen sits in the view, how thick its bezel is drawn, and the
    /// screen's corner radius, all in view points. The whole device, bezel
    /// included, is fitted to the view, so the bezel keeps the device's own
    /// proportion at every pane size.
    private var geometry: (screen: CGRect, bezel: CGFloat, cornerRadius: CGFloat) {
        guard let size = screen?.pointSize, size.width > 0, size.height > 0,
              bounds.width > 0, bounds.height > 0
        else { return (.zero, 0, 0) }
        let realBezel = chrome?.bezel ?? size.width * SimulatorChrome.fallbackBezelRatio
        let realRadius = chrome?.screenCornerRadius ?? size.width * SimulatorChrome.fallbackCornerRatio
        let scale = min(bounds.width / (size.width + 2 * realBezel),
                        bounds.height / (size.height + 2 * realBezel))
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        let rect = CGRect(
            x: (bounds.width - fitted.width) / 2, y: (bounds.height - fitted.height) / 2,
            width: fitted.width, height: fitted.height)
        return (rect, realBezel * scale, realRadius * scale)
    }

    private var screenRect: CGRect { geometry.screen }

    /// A view point as a device point (top-left origin), or nil in the letterbox.
    /// `clamped` pins a drag that leaves the screen to its edge instead, so a
    /// finger that slides off still lifts where the screen ends.
    private func devicePoint(_ event: NSEvent, clamped: Bool = false) -> CGPoint? {
        guard let size = screen?.pointSize else { return nil }
        let rect = screenRect
        guard rect.width > 0 else { return nil }
        var point = convert(event.locationInWindow, from: nil)
        if clamped {
            point.x = min(max(point.x, rect.minX), rect.maxX)
            point.y = min(max(point.y, rect.minY), rect.maxY)
        } else if !rect.contains(point) {
            return nil
        }
        return CGPoint(
            x: (point.x - rect.minX) / rect.width * size.width,
            y: (rect.maxY - point.y) / rect.height * size.height)
    }

    // MARK: Touch

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let point = devicePoint(event) else { return }
        touching = true
        touch("down", at: point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard touching, let point = devicePoint(event, clamped: true) else { return }
        // iOS reads the finger's position while it is down, so a move is
        // another "down" at the new point.
        touch("down", at: point)
    }

    override func mouseUp(with event: NSEvent) {
        guard touching, let point = devicePoint(event, clamped: true) else { return }
        touching = false
        touch("up", at: point)
    }

    private func touch(_ phase: String, at point: CGPoint) {
        guard let udid = screen?.udid else { return }
        // Memory-only unless streamed: the record of where a click landed on the
        // device, for when the pointer and the finger disagree.
        Log.simulator.info("touch \(phase, privacy: .public) \(Int(point.x), privacy: .public),\(Int(point.y), privacy: .public)")
        send("touch", ["udid": udid, "phase": phase, "x": point.x, "y": point.y])
    }

    // MARK: Keyboard

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let udid = screen?.udid else { return }
        // Command shortcuts stay the app's; only plain typing reaches the device.
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        if let name = Self.keyName(event.keyCode) {
            send("key", ["udid": udid, "name": name])
        } else if let characters = event.characters, !characters.isEmpty {
            send("text", ["udid": udid, "text": characters])
        }
    }

    private static func keyName(_ keyCode: UInt16) -> String? {
        switch keyCode {
        case 36, 76: "return"
        case 48: "tab"
        case 51: "delete"
        case 117: "forward-delete"
        case 53: "escape"
        case 123: "left"
        case 124: "right"
        case 125: "down"
        case 126: "up"
        default: nil
        }
    }

    private func send(_ op: String, _ parameters: [String: Any]) {
        SimulatorHost.shared.fire(op, parameters)
    }
}

/// A device's screen shape and bezel, as the user's Xcode describes them for
/// Simulator.app: the device type's profile names a mask PDF for the screen and a
/// DeviceKit chrome bundle, whose `chrome.json` gives the bezel's width and the
/// device's outer corner radius. Read at runtime and never shipped: the mask is
/// Apple's, and it is already on every Mac that can run a simulator. The bezel
/// itself is drawn rather than Apple's art: a black band with a hairline rim,
/// at the device's real width, in proportion to the screen.
struct SimulatorChrome {
    let mask: NSImage?
    /// The real bezel width, in device points.
    let bezel: CGFloat
    /// The screen's corner radius, in device points: the outer radius less the bezel.
    let screenCornerRadius: CGFloat

    /// For a device with no chrome: an iPhone-like bezel and corner, as a share of width.
    static let fallbackBezelRatio: CGFloat = 0.04
    static let fallbackCornerRatio: CGFloat = 0.137

    private static let chromeRoot = "/Library/Developer/DeviceKit/Chrome"

    @MainActor private static var cache: [String: SimulatorChrome?] = [:]

    @MainActor
    static func load(for screen: SimulatorScreen) -> SimulatorChrome? {
        guard let path = screen.deviceTypePath else { return nil }
        if let cached = cache[path] { return cached }
        let loaded = read(deviceTypePath: path)
        if loaded == nil { Log.simulator.info("no chrome for \(path, privacy: .public)") }
        cache[path] = loaded
        return loaded
    }

    private static func read(deviceTypePath: String) -> SimulatorChrome? {
        let resources = URL(fileURLWithPath: deviceTypePath).appendingPathComponent("Contents/Resources")
        guard let profile = NSDictionary(contentsOf: resources.appendingPathComponent("profile.plist")),
              let identifier = profile["chromeIdentifier"] as? String,
              let name = identifier.split(separator: ".").last
        else { return nil }
        let mask = (profile["framebufferMask"] as? String).flatMap {
            NSImage(contentsOf: resources.appendingPathComponent("\($0).pdf"))
        }
        let chrome = URL(fileURLWithPath: chromeRoot)
            .appendingPathComponent("\(name).devicechrome/Contents/Resources/chrome.json")
        guard let data = try? Data(contentsOf: chrome),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sizing = (json["images"] as? [String: Any])?["sizing"] as? [String: Any],
              let bezel = (sizing["leftWidth"] as? NSNumber)?.doubleValue,
              let border = (json["paths"] as? [String: Any])?["simpleOutsideBorder"] as? [String: Any],
              let outer = (border["cornerRadiusX"] as? NSNumber)?.doubleValue
        else { return nil }
        return SimulatorChrome(mask: mask, bezel: bezel, screenCornerRadius: max(0, outer - bezel))
    }
}

struct SimulatorScreenRepresentable: NSViewRepresentable {
    let screen: SimulatorScreen?

    func makeNSView(context: Context) -> SimulatorScreenView {
        let view = SimulatorScreenView(frame: .zero)
        view.screen = screen
        return view
    }

    func updateNSView(_ view: SimulatorScreenView, context: Context) {
        view.screen = screen
    }
}
