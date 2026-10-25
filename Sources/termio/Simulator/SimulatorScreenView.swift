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
            makeButtons()
            needsLayout = true
            guard let screen else { return }
            SimulatorHost.shared.present(stream: screen.stream, for: self) { [weak self] surface in
                self?.show(surface)
            }
        }
    }

    /// View points per device point, set by the zoom container; nil fits the
    /// whole device, bezel included, to the view.
    var scale: CGFloat? {
        didSet { if scale != oldValue { needsLayout = true } }
    }

    /// The side buttons, in a layer the size of the device held upright and
    /// turned with it, so a button stays on the edge it is on in the hand.
    private let buttonsLayer = CALayer()
    private var buttonLayers: [(button: SimulatorChrome.Button, layer: CALayer)] = []
    private var pressedButton: CALayer?
    /// Select Element's outline round the element under the pointer, or the
    /// one picked: black inside white, so it reads on light and dark screens.
    private let highlightLayer = CALayer()
    private let highlightInner = CALayer()
    private var highlighted: SimulatorElement?
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
        layer?.addSublayer(buttonsLayer)
        layer?.addSublayer(bezelLayer)
        layer?.addSublayer(screenLayer)
        highlightLayer.borderColor = NSColor.white.cgColor
        highlightLayer.borderWidth = 3
        highlightLayer.cornerRadius = 3
        highlightLayer.backgroundColor = NSColor.black.withAlphaComponent(0.08).cgColor
        highlightInner.borderColor = NSColor.black.cgColor
        highlightInner.borderWidth = 1.5
        highlightInner.cornerRadius = 2
        highlightLayer.addSublayer(highlightInner)
        highlightLayer.isHidden = true
        layer?.addSublayer(highlightLayer)
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
        layoutButtons(screen: rect, bezel: bezel, quarter: quarter)
        layoutHighlight()
        CATransaction.commit()
    }

    /// Outlines `element`, or clears the outline when nil.
    func highlight(_ element: SimulatorElement?) {
        guard element != highlighted else { return }
        highlighted = element
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutHighlight()
        CATransaction.commit()
    }

    private func layoutHighlight() {
        guard let element = highlighted, let size = screen?.pointSize, size.width > 0 else {
            highlightLayer.isHidden = true
            return
        }
        let rect = screenRect
        let unit = rect.width / size.width
        // Interface points run from the top; the view's run from the bottom.
        let frame = CGRect(
            x: rect.minX + element.frame.minX * unit,
            y: rect.maxY - element.frame.maxY * unit,
            width: element.frame.width * unit, height: element.frame.height * unit)
            .intersection(rect)
        highlightLayer.isHidden = frame.isNull || frame.isEmpty
        highlightLayer.frame = frame.insetBy(dx: -1.5, dy: -1.5)
        highlightInner.frame = highlightLayer.bounds.insetBy(dx: 2, dy: 2)
    }

    // MARK: Select Element

    private var tracking: NSTrackingArea?
    /// The tree hover picks from, and when it was read. Read again in the
    /// background once a second old, so the outline follows a screen that
    /// changes under it without a read per mouse move.
    private var tree: (document: [String: Any], read: Date)?
    private var readingTree = false
    private var lastHoverPoint: CGPoint?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard SimulatorHost.shared.inspecting else { return }
        guard let point = devicePoint(event) else {
            SimulatorHost.shared.hoveredElement = nil
            highlight(SimulatorHost.shared.selectedElement)
            return
        }
        read(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        guard SimulatorHost.shared.inspecting else { return }
        SimulatorHost.shared.hoveredElement = nil
        highlight(SimulatorHost.shared.selectedElement)
    }

    private func read(at point: CGPoint) {
        lastHoverPoint = point
        // A tree older than a second may be of a screen since changed; the
        // outline waits for the fresh one rather than mark what is gone.
        if let tree, let screen, Date().timeIntervalSince(tree.read) < 1 {
            let element = SimulatorElement.pick(from: tree.document, at: point, interface: screen.pointSize)
            SimulatorHost.shared.hoveredElement = element
            highlight(element ?? SimulatorHost.shared.selectedElement)
            return
        }
        refreshTree()
    }

    private func refreshTree() {
        guard !readingTree, let screen else { return }
        readingTree = true
        Task {
            let host = SimulatorHost.shared
            do {
                tree = (try await host.elementTree(on: screen), Date())
            } catch {
                Log.simulator.error("reading the screen's elements failed: \(error.localizedDescription, privacy: .public)")
                host.notice = error.localizedDescription
            }
            readingTree = false
            // Picks again from the fresh tree where the pointer is now.
            if host.inspecting, let point = lastHoverPoint, let tree {
                let element = SimulatorElement.pick(from: tree.document, at: point, interface: screen.pointSize)
                host.hoveredElement = element
                highlight(element ?? host.selectedElement)
            }
        }
    }

    /// A click while selecting picks the element there instead of touching it.
    private func select(at point: CGPoint) {
        guard let screen else { return }
        Task {
            let host = SimulatorHost.shared
            do {
                let document = try await host.elementTree(on: screen)
                tree = (document, Date())
                guard let element = SimulatorElement.pick(from: document, at: point, interface: screen.pointSize) else {
                    host.notice = localized("No element there.")
                    return
                }
                host.selectedElement = element
                host.inspecting = false
                highlight(element)
            } catch {
                Log.simulator.error("selecting an element failed: \(error.localizedDescription, privacy: .public)")
                host.notice = error.localizedDescription
            }
        }
    }

    private func makeButtons() {
        buttonLayers.forEach { $0.layer.removeFromSuperlayer() }
        buttonLayers = (chrome?.buttons ?? []).map { button in
            let layer = CALayer()
            layer.backgroundColor = NSColor.black.cgColor
            layer.borderColor = NSColor(white: 0.32, alpha: 1).cgColor
            layer.borderWidth = 1
            buttonsLayer.addSublayer(layer)
            return (button, layer)
        }
    }

    /// How far a button stands proud of the bezel, in device points.
    static let buttonRise: CGFloat = 4

    private func layoutButtons(screen rect: CGRect, bezel: CGFloat, quarter: Bool) {
        guard let chrome, chrome.bezel > 0, !rect.isEmpty else {
            buttonsLayer.isHidden = true
            return
        }
        buttonsLayer.isHidden = false
        let unit = bezel / chrome.bezel
        let upright = quarter ? CGSize(width: rect.height, height: rect.width) : rect.size
        let size = CGSize(width: upright.width + 2 * bezel, height: upright.height + 2 * bezel)
        buttonsLayer.setAffineTransform(.identity)
        buttonsLayer.bounds = CGRect(origin: .zero, size: size)
        buttonsLayer.position = CGPoint(x: rect.midX, y: rect.midY)
        buttonsLayer.setAffineTransform(CGAffineTransform(rotationAngle: screen.map(Self.angle) ?? 0))
        let rise = Self.buttonRise * unit
        // Tucked half under the bezel, so only the rise shows.
        let depth = rise + bezel / 2
        for (button, layer) in buttonLayers {
            let length = button.length * unit
            let along = button.offset * unit
            let frame: CGRect = switch button.edge {
            case .left: CGRect(x: -rise, y: size.height - along - length, width: depth, height: length)
            case .right: CGRect(x: size.width - bezel / 2, y: size.height - along - length, width: depth, height: length)
            case .top:
                CGRect(x: button.fromEnd ? size.width - along - length : along,
                       y: size.height - bezel / 2, width: length, height: depth)
            }
            layer.frame = frame
            layer.cornerRadius = min(rise, length / 2)
        }
    }

    /// The button under a click, its hit area grown a little past its art:
    /// the rise is only a few points wide.
    private func button(at point: CGPoint) -> (button: SimulatorChrome.Button, layer: CALayer)? {
        guard let root = layer, !buttonsLayer.isHidden else { return nil }
        return buttonLayers.first { entry in
            buttonsLayer.convert(entry.layer.frame, to: root).insetBy(dx: -4, dy: -4).contains(point)
        }
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
        let realBezel = bezelPoints(for: size)
        let realRadius = chrome?.screenCornerRadius ?? size.width * SimulatorChrome.fallbackCornerRatio
        let scale = self.scale ?? Self.fitScale(device: size, bezel: realBezel, in: bounds.size)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        let rect = CGRect(
            x: (bounds.width - fitted.width) / 2, y: (bounds.height - fitted.height) / 2,
            width: fitted.width, height: fitted.height)
        return (rect, realBezel * scale, realRadius * scale)
    }

    private var screenRect: CGRect { geometry.screen }

    func bezelPoints(for size: CGSize) -> CGFloat {
        chrome?.bezel ?? min(size.width, size.height) * SimulatorChrome.fallbackBezelRatio
    }

    /// Room is left for the side buttons standing proud of the bezel.
    static func fitScale(device size: CGSize, bezel: CGFloat, in space: CGSize) -> CGFloat {
        let edge = 2 * (bezel + buttonRise)
        return min(space.width / (size.width + edge), space.height / (size.height + edge))
    }

    /// The scale at which the screen is as big on this Mac's display as on the
    /// device in a hand: the device's width in inches, from its profile, times
    /// the display's points per inch. Nil when either is unknown.
    var physicalScale: CGFloat? {
        guard let screen, let inches = chrome?.shortSideInches,
              let display = window?.screen,
              let number = display.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        let millimetres = CGDisplayScreenSize(CGDirectDisplayID(number.uint32Value)).width
        guard millimetres > 0 else { return nil }
        let pointsPerInch = display.frame.width / (millimetres / 25.4)
        return inches * pointsPerInch / min(screen.pointSize.width, screen.pointSize.height)
    }

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
        let local = convert(event.locationInWindow, from: nil)
        if !screenRect.contains(local), let (button, layer) = button(at: local), let udid = screen?.udid {
            // Pressed in, the way the hardware gives under a thumb.
            layer.opacity = 0.6
            pressedButton = layer
            send("button", ["udid": udid, "name": button.name])
            return
        }
        // A press on the bezel starts on the screen's edge, as a thumb does:
        // the way to swipe up from the Home indicator or down from the top,
        // which iOS reads as system gestures only from the edge itself.
        let onBezel = geometry.screen.insetBy(dx: -geometry.bezel, dy: -geometry.bezel).contains(local)
        guard let point = devicePoint(event) ?? (onBezel ? devicePoint(event, clamped: true) : nil) else { return }
        if SimulatorHost.shared.inspecting {
            select(at: point)
            return
        }
        // A touch changes the screen the picked element was read from.
        SimulatorHost.shared.selectedElement = nil
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
        if let pressedButton {
            pressedButton.opacity = 1
            self.pressedButton = nil
        }
        guard touching, let point = devicePoint(event, clamped: true) else { return }
        touching = false
        touch("up", at: point)
    }

    // MARK: Scroll

    /// Where the finger a trackpad scroll puts down is now, in device points.
    private var scrollFinger: CGPoint?

    /// A scroll is a finger dragged across the screen, which is how iOS
    /// scrolls. A trackpad's gesture is followed as it happens — down when it
    /// begins, moving with the fingers, up when they lift — and its momentum is
    /// left to iOS, which flings from the release the way it would from a real
    /// finger. A mouse wheel, which has no begin or end, is one short swipe per
    /// notch.
    override func scrollWheel(with event: NSEvent) {
        // ⌥ pans a zoomed-in device in its pane instead of scrolling inside it.
        if event.modifierFlags.contains(.option), let scrollView = enclosingScrollView {
            let clip = scrollView.contentView
            let step: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            let limit = CGSize(width: max(0, frame.width - clip.bounds.width),
                               height: max(0, frame.height - clip.bounds.height))
            clip.scroll(to: CGPoint(
                x: min(max(clip.bounds.origin.x - event.scrollingDeltaX * step, 0), limit.width),
                y: min(max(clip.bounds.origin.y + event.scrollingDeltaY * step, 0), limit.height)))
            scrollView.reflectScrolledClipView(clip)
            return
        }
        guard let screen, event.momentumPhase.isEmpty else { return }
        let rect = screenRect
        guard rect.width > 0 else { return }
        let scale = rect.width / screen.pointSize.width
        let dx = event.scrollingDeltaX / scale
        let dy = event.scrollingDeltaY / scale
        if !event.phase.isEmpty {
            if event.phase.contains(.began) || scrollFinger == nil {
                guard let start = devicePoint(event) else { return }
                let point = insetFromEdges(start, in: screen.pointSize)
                scrollFinger = point
                touch("down", at: point)
            }
            if event.phase.contains(.changed), var finger = scrollFinger {
                finger.x = min(max(finger.x + dx, 0), screen.pointSize.width)
                finger.y = min(max(finger.y + dy, 0), screen.pointSize.height)
                scrollFinger = finger
                touch("down", at: finger)
            }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled), let finger = scrollFinger {
                scrollFinger = nil
                touch("up", at: finger)
            }
            return
        }
        guard let start = devicePoint(event).map({ insetFromEdges($0, in: screen.pointSize) }) else { return }
        // A notch reports lines, not points; a line is about 40 points of travel.
        let step = event.hasPreciseScrollingDeltas ? 1.0 : 40.0
        let end = CGPoint(
            x: min(max(start.x + dx * step, 0), screen.pointSize.width),
            y: min(max(start.y + dy * step, 0), screen.pointSize.height))
        guard abs(end.y - start.y) + abs(end.x - start.x) >= 1 else { return }
        SimulatorHost.shared.fire("swipe", [
            "udid": screen.udid, "x": start.x, "y": start.y, "x2": end.x, "y2": end.y, "duration": 0.08,
        ])
    }

    /// Five points in from any edge: a scroll that starts on the bezel line
    /// would be an edge gesture — back, the notification shade, Home.
    private func insetFromEdges(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: min(max(point.x, 5), size.width - 5), y: min(max(point.y, 5), size.height - 5))
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

    /// Simulator.app's shortcuts — Home, Rotate, Lock, Screenshot and the rest —
    /// while the screen has focus, through a local monitor installed only
    /// then. A monitor rather than `performKeyEquivalent`: AppKit offers a key
    /// equivalent to the window's views in hierarchy order, and a view ahead of
    /// this one (the terminal's) takes ⇧⌘H and ⇧⌘A before it is asked. Focus
    /// elsewhere and the monitor is gone, so ⌘S, ⌘L, ⌘K are termio's again.
    private var shortcutMonitor: Any?

    override func becomeFirstResponder() -> Bool {
        installShortcuts()
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        removeShortcuts()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { removeShortcuts() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func installShortcuts() {
        guard shortcutMonitor == nil else { return }
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, self.window?.firstResponder === self,
                  let screen = self.screen
            else { return event }
            if let command = SimulatorCommand.matching(event) {
                Task { await SimulatorHost.shared.perform(command, on: screen) }
                return nil
            }
            // The Edit menu's keys, for the same reason: the terminal answers
            // ⌘C and ⌘V as key equivalents before the menu is asked.
            guard event.modifierFlags.intersection([.command, .shift, .control, .option]) == .command else {
                return event
            }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": self.copy(nil)
            case "x": self.cut(nil)
            case "v": self.paste(nil)
            case "a": self.selectAll(nil)
            default: return event
            }
            return nil
        }
    }

    private func removeShortcuts() {
        if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor) }
        shortcutMonitor = nil
    }

    // MARK: Edit menu

    /// Edit ▸ Cut, Copy, Paste and Select All act on the device while its screen
    /// has focus, and carry text across between the two pasteboards.
    @objc func copy(_ sender: Any?) { copySelection(cut: false) }

    @objc func cut(_ sender: Any?) { copySelection(cut: true) }

    @objc func paste(_ sender: Any?) {
        guard let udid = screen?.udid else { return }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            SimulatorHost.shared.notice = localized("Only text can be pasted into the simulator.")
            return
        }
        Task { await SimulatorHost.shared.attempt("paste") { try await SimulatorHost.shared.paste(text, on: udid) } }
    }

    @objc override func selectAll(_ sender: Any?) {
        guard let udid = screen?.udid else { return }
        send("key", ["udid": udid, "name": "select-all"])
    }

    private func copySelection(cut: Bool) {
        guard let udid = screen?.udid else { return }
        Task {
            await SimulatorHost.shared.attempt(cut ? "cut" : "copy") {
                try await SimulatorHost.shared.copySelection(on: udid, cut: cut)
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let udid = screen?.udid else { return }
        // Escape leaves Select Element rather than reaching the device.
        if event.keyCode == 53, SimulatorHost.shared.inspecting {
            SimulatorHost.shared.inspecting = false
            highlight(SimulatorHost.shared.selectedElement)
            return
        }
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
    /// The screen's short side in inches: its pixels over its pixels per inch.
    let shortSideInches: CGFloat?
    let buttons: [Button]

    /// A hardware button on the device's edge, where its chrome draws it.
    struct Button {
        enum Edge { case left, right, top }
        /// The helper's name for it.
        let name: String
        let title: String
        let edge: Edge
        /// Device points along the edge from its start — the top of a side,
        /// the left of the top — or from its end when `fromEnd`.
        let offset: CGFloat
        let fromEnd: Bool
        let length: CGFloat
    }

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
        var inches: CGFloat?
        if let pixels = (profile["mainScreenWidth"] as? NSNumber)?.doubleValue,
           let dpi = (profile["mainScreenWidthDPI"] as? NSNumber)?.doubleValue, dpi > 0 {
            inches = pixels / dpi
        }
        let resourcesOfChrome = chrome.deletingLastPathComponent()
        let buttons = (json["inputs"] as? [[String: Any]] ?? []).compactMap {
            Self.button($0, art: resourcesOfChrome)
        }
        return SimulatorChrome(
            mask: mask, bezel: bezel, screenCornerRadius: max(0, outer - bezel), shortSideInches: inches,
            buttons: buttons)
    }

    /// The side buttons the helper can press. The action button and a front
    /// Home button are left out: the first has no HID usage idb sends, and
    /// the second is the header's Home.
    private static func button(_ input: [String: Any], art: URL) -> Button? {
        let pressable = ["volume-up": ("volume-up", localized("Volume Up")),
                         "volume-down": ("volume-down", localized("Volume Down")),
                         "power": ("lock", localized("Side Button"))]
        guard let name = input["name"] as? String, let (helperName, title) = pressable[name],
              let image = (input["image"] as? String).flatMap({
                  NSImage(contentsOf: art.appendingPathComponent("\($0).pdf"))
              }),
              let normal = (input["offsets"] as? [String: Any])?["normal"] as? [String: Any],
              let x = (normal["x"] as? NSNumber)?.doubleValue, let y = (normal["y"] as? NSNumber)?.doubleValue
        else { return nil }
        let edge: Button.Edge
        switch input["anchor"] as? String {
        case "left": edge = .left
        case "right": edge = .right
        case "top": edge = .top
        default: return nil
        }
        let alongTop = edge == .top
        return Button(
            name: helperName, title: title, edge: edge,
            offset: abs(alongTop ? x : y),
            fromEnd: alongTop && input["align"] as? String == "trailing",
            length: alongTop ? image.size.width : image.size.height)
    }
}

/// How big the pane draws the device: fitted to the pane, at its size in a
/// hand, or a step of 1.25× either side of fitted.
enum SimulatorZoom: Equatable {
    case fit
    case physical
    /// A multiple of the fitted size.
    case factor(CGFloat)

    static let step: CGFloat = 1.25
    static let range: ClosedRange<CGFloat> = 0.25 ... 4
}

/// The screen view in a scroll view, so a device zoomed past the pane can be
/// panned with ⌥-scroll or the scroll bars. At Fit the two are the same size and
/// nothing scrolls.
final class SimulatorZoomView: NSScrollView {
    let screenView = SimulatorScreenView(frame: .zero)
    var zoom: SimulatorZoom = .fit {
        didSet { if zoom != oldValue { needsLayout = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        documentView = screenView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        let space = contentView.bounds.size
        guard let screen = screenView.screen, space.width > 0, space.height > 0 else {
            screenView.scale = nil
            screenView.frame = CGRect(origin: .zero, size: space)
            return
        }
        let size = screen.pointSize
        let bezel = screenView.bezelPoints(for: size)
        let fit = SimulatorScreenView.fitScale(device: size, bezel: bezel, in: space)
        let scale: CGFloat? = switch zoom {
        case .fit: nil
        case .physical: screenView.physicalScale
        case .factor(let factor): fit * factor
        }
        screenView.scale = scale
        let edge = 2 * (bezel + SimulatorScreenView.buttonRise)
        let device = CGSize(width: (size.width + edge) * (scale ?? fit), height: (size.height + edge) * (scale ?? fit))
        let document = CGSize(width: max(space.width, device.width), height: max(space.height, device.height))
        let old = screenView.frame.size
        guard old != document else { return }
        // A zoom step keeps the point at the middle of the pane where it is.
        let visible = contentView.bounds
        let centre = CGPoint(x: old.width > 0 ? visible.midX / old.width : 0.5,
                             y: old.height > 0 ? visible.midY / old.height : 0.5)
        screenView.frame = CGRect(origin: .zero, size: document)
        let origin = CGPoint(
            x: min(max(centre.x * document.width - space.width / 2, 0), document.width - space.width),
            y: min(max(centre.y * document.height - space.height / 2, 0), document.height - space.height))
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }
}

struct SimulatorScreenRepresentable: NSViewRepresentable {
    let screen: SimulatorScreen?
    let zoom: SimulatorZoom
    /// The element outlined: the one under the pointer, else the one picked.
    let highlight: SimulatorElement?

    func makeNSView(context: Context) -> SimulatorZoomView {
        let view = SimulatorZoomView(frame: .zero)
        view.screenView.screen = screen
        view.zoom = zoom
        return view
    }

    func updateNSView(_ view: SimulatorZoomView, context: Context) {
        view.screenView.screen = screen
        view.screenView.highlight(highlight)
        view.zoom = zoom
        view.needsLayout = true
    }
}
