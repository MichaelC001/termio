import CoreGraphics
import CoreSimulator
import FBControlCore
import FBSimulatorAX
import FBSimulatorControl
import FBSimulatorServices
import Foundation
import ImageIO
import IOSurface

/// One booted simulator the helper is driving. Built on first use and kept for
/// the helper's lifetime: the HID connection and the accessibility reader are
/// each a few hundred milliseconds to establish, and an agent tapping through a
/// flow pays that once instead of per tap.
final class Device: @unchecked Sendable {
    let simulator: Simulator
    let stream: UInt32
    let pointSize: CGSize
    let scale: CGFloat

    private let logger = ControlCoreGlobalConfiguration.defaultLogger
    private var hid: SimulatorHID?
    private var readers: [AXBridgeFrontmostMethod: any UIAutomation] = [:]
    /// The host-side reader, for the one attribute the in-simulator one cannot
    /// fetch: a text field's placeholder.
    private var hostReader: (any UIAutomation)?
    private var frontmostMethod: AXBridgeFrontmostMethod = .windowServer
    private var framebuffer: Framebuffer?
    private var attachment: FramebufferAttachment?
    private var events: Task<Void, Never>?
    private var port: SurfacePort?
    /// The surface the app was last sent.
    private var surfaceID: IOSurfaceID?
    private var currentSurface: IOSurface?
    private var lastSurfaceCheckFailure: String?
    /// Bumped by `detach` and by a new boot; what was being made before it is
    /// not cached after.
    private var generation = 0
    /// The boot the cached state belongs to, by its marker.
    private var knownBoot: String?
    /// The screen edge the finger now down on the pane went down on, held for
    /// its whole stroke: iOS reads a swipe from an edge as a system gesture
    /// only when every report of it names that edge.
    private var strokeEdge: SimulatorHIDEdge?
    private let lock = NSLock()
    /// The device's orientation as last read or written. Read back from the
    /// simulator's own motion state (`refreshOrientation`), so a turn made in
    /// Simulator.app, or before this helper started, is not missed.
    private var orientation: SimulatorDeviceOrientation = .portrait
    private var orientationWatch: Task<Void, Never>?
    /// Whether idb turns interface points onto the panel itself, which it does
    /// only where CoreDevice reports display geometry. Probed on first input.
    private var idbTurnsPoints: Bool?

    init(simulator: Simulator, stream: UInt32) {
        self.simulator = simulator
        self.stream = stream
        let info = simulator.screenInfo
        let scale = CGFloat(info?.scale ?? 2)
        self.scale = scale > 0 ? scale : 2
        self.pointSize = CGSize(
            width: CGFloat(info?.widthPixels ?? 0) / self.scale,
            height: CGFloat(info?.heightPixels ?? 0) / self.scale)
    }

    /// How the interface sits on the panel — which is not always how the device
    /// is held: an iPhone's home screen and most iPhone apps stay portrait in
    /// a landscape device. Every point is mapped by this.
    var turn: Turn { lock.withLock { interface } }
    private var interface: Turn = .upright

    private var boot: String? { OrientationRecord.boot(dataPath: simulator.device.dataPath()) }

    /// The interface's size in points: the panel's, turned with the device.
    var interfaceSize: CGSize { turn.interfaceSize(panel: pointSize) }

    var summary: [String: Any] {
        let interface = interfaceSize
        var summary: [String: Any] = [
            "udid": simulator.udid,
            "name": simulator.name,
            "stream": stream,
            "pointWidth": interface.width,
            "pointHeight": interface.height,
            "panelWidth": pointSize.width,
            "panelHeight": pointSize.height,
            "rotation": turn.rawValue,
            "scale": scale,
        ]
        // The device type's bundle in the user's Xcode: its profile names the
        // bezel art and the screen's corner mask the app draws around the screen.
        if let path = simulator.device.deviceType?.bundle?.bundlePath {
            summary["deviceTypePath"] = path
        }
        return summary
    }

    // MARK: Display

    /// Starts sending the display's surface to the app, then a `frame` event per
    /// presented frame. CoreSimulator renders every frame into the same surface,
    /// so the app needs the tick to know when to re-present it; the surface
    /// itself only travels again when the display swaps it (a rotation, a
    /// resolution change).
    func attach(to port: SurfacePort) throws {
        lock.lock()
        defer { lock.unlock() }
        guard attachment == nil else {
            // The surface in use now, not the attachment's first: the display
            // may have moved to another since, and the first is a dead frame.
            if let surface = currentSurface ?? attachment?.initialSurface { send(surface, to: port) }
            return
        }
        let framebuffer = try currentFramebuffer()
        let attachment = try framebuffer.attach()
        listen(to: attachment, port: port)
        watchOrientation()
    }

    /// Takes `attachment` as the display's, sends its surface, and relays its
    /// events. Called with the lock held.
    private func listen(to attachment: FramebufferAttachment, port: SurfacePort) {
        self.attachment = attachment
        self.port = port
        if let surface = attachment.initialSurface { send(surface, to: port) }
        let stream = self.stream
        let udid = simulator.udid
        events = Task { [weak self] in
            for await event in attachment.events {
                switch event {
                case .surfaceChanged(let surface):
                    if let surface { self?.deliver(surface, from: attachment, to: port) }
                case .frameRendered:
                    Wire.event("frame", ["stream": stream])
                case .configurationChanged:
                    break
                case .ended(let error):
                    // Not for an attachment already replaced: its end is ours.
                    guard self?.isCurrent(attachment) == true else { return }
                    Wire.event("detached", ["udid": udid, "error": "\(error)"])
                    return
                @unknown default:
                    break
                }
            }
        }
    }

    /// A surface change from `source`, sent only if `source` is still the
    /// attachment in use. Cancelling a replaced attachment's task does not stop
    /// an event it is already handling, and that event's surface is older than
    /// the replacement's.
    private func deliver(_ surface: IOSurface, from source: FramebufferAttachment, to port: SurfacePort) {
        lock.lock()
        defer { lock.unlock() }
        guard attachment === source else { return }
        send(surface, to: port)
    }

    private func isCurrent(_ source: FramebufferAttachment) -> Bool {
        lock.withLock { attachment === source }
    }

    /// Called with the lock held.
    private func send(_ surface: IOSurface, to port: SurfacePort) {
        currentSurface = surface
        surfaceID = IOSurfaceGetID(surface)
        port.send(surface, stream: stream)
    }

    /// When the display sleeps and wakes — the side button pressed on a lock
    /// screen, then again — or a boot settles, CoreSimulator moves it to a new
    /// surface without telling the framebuffer, which goes on holding the last
    /// frame. So after a press that can do that, the display is located afresh,
    /// twice as the wake settles, and attached anew if its surface is not the
    /// one in use; the orientation watch does the same every few seconds.
    func followDisplayAfterPower() async {
        for delay in [0.8, 2.0] {
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            reattachIfSurfaceMoved()
        }
    }

    private func reattachIfSurfaceMoved() {
        lock.lock()
        defer { lock.unlock() }
        guard let port, attachment != nil else { return }
        let fresh: Framebuffer
        let freshAttachment: FramebufferAttachment
        do {
            fresh = try Framebuffer.mainScreenSurface(for: simulator, logger: logger)
            freshAttachment = try fresh.attach()
        } catch {
            // Once per distinct failure: a device shut down while attached
            // fails the same way every few seconds until it detaches.
            let message = "\(error)"
            if message != lastSurfaceCheckFailure {
                Wire.log("locating \(simulator.udid)'s display to check its surface failed: \(message)")
            }
            lastSurfaceCheckFailure = message
            return
        }
        lastSurfaceCheckFailure = nil
        guard let surface = freshAttachment.initialSurface, IOSurfaceGetID(surface) != surfaceID else {
            freshAttachment.cancel()
            return
        }
        Wire.log("\(simulator.udid)'s display moved to surface \(IOSurfaceGetID(surface)); reattached")
        events?.cancel()
        attachment?.cancel()
        framebuffer = fresh
        listen(to: freshAttachment, port: port)
    }

    func detach() {
        lock.lock()
        defer { lock.unlock() }
        events?.cancel()
        events = nil
        orientationWatch?.cancel()
        orientationWatch = nil
        attachment?.cancel()
        attachment = nil
        port = nil
        surfaceID = nil
        currentSurface = nil
        // Detached is how a device leaves the pane to shut down or restart, and
        // each of these is bound to the boot it was made in: the display, the
        // HID connection, the accessibility readers. The next use makes fresh ones.
        framebuffer = nil
        hid = nil
        readers.removeAll()
        hostReader = nil
        strokeEdge = nil
        // A connection or reader still being made belongs to the boot left
        // behind; this makes it be thrown away when it arrives.
        generation += 1
    }

    /// The edge for one report of a pane stroke: decided where it goes down,
    /// kept until it lifts.
    func edge(forStrokeAt point: CGPoint, lifting: Bool) -> SimulatorHIDEdge {
        lock.lock()
        defer { lock.unlock() }
        let edge = strokeEdge ?? gestureEdge(at: point, interface: interface.interfaceSize(panel: pointSize))
        strokeEdge = lifting ? nil : edge
        return edge
    }

    private func currentFramebuffer() throws -> Framebuffer {
        if let framebuffer { return framebuffer }
        let created = try Framebuffer.mainScreenSurface(for: simulator, logger: logger)
        framebuffer = created
        return created
    }

    /// Writes the current frame as a PNG. Pixels and points both go back: a 3x
    /// device renders three pixels per point, and a caller measuring in the
    /// image then tapping that number would land three times too far.
    func screenshot(to path: String) async throws -> [String: Any] {
        // Under the lock, as attach and detach write the same cache.
        let framebuffer = try lock.withLock { try currentFramebuffer() }
        let panelImage = try await SimulatorImage(framebuffer: framebuffer, logger: nil).image()
        // The framebuffer is the panel; a rotated interface is turned upright so
        // the image matches the points `inspect` and `tap` speak.
        let image = panelImage.flatMap { upright($0, turn: turn) }
        guard let image,
              let destination = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
        else { throw HelperError.screenshotFailed(path) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw HelperError.screenshotFailed(path) }
        return [
            "path": path,
            "pixelWidth": image.width,
            "pixelHeight": image.height,
            "pointWidth": interfaceSize.width,
            "pointHeight": interfaceSize.height,
        ]
    }

    // MARK: Input

    /// Sends `event`, whose points are interface points, turning them onto the
    /// panel where idb will not.
    func send(_ event: SimulatorHIDEvent) async throws {
        let hid = try await connectedHID()
        let turn = self.turn
        var panelEvent = event
        if turn != .upright, await !turnsPointsItself() { panelEvent = onPanel(event, turn: turn) }
        try await hid.send(event: panelEvent, logger: logger)
    }

    /// A gesture's edge, found in interface points from where it starts.
    func edge(startingAt point: CGPoint) -> SimulatorHIDEdge {
        gestureEdge(at: point, interface: interfaceSize)
    }

    /// Turns the device a quarter, or to `target`, and returns how the
    /// interface settled — which for an app that does not rotate is upright.
    func rotate(clockwise: Bool? = nil, to target: SimulatorDeviceOrientation? = nil) async throws -> Turn {
        let current = await refreshOrientation()
        let next = target ?? Turn.next(after: current, clockwise: clockwise ?? true)
        try await simulator.orientation.set(next)
        lock.withLock { orientation = next }
        OrientationRecord.write(next, udid: simulator.udid, boot: boot)
        // The interface animates for about half a second before it reports
        // its new frame.
        try await Task.sleep(for: .milliseconds(700))
        await refreshOrientation()
        return turn
    }

    /// Forgets what belongs to a boot when the device has booted again since
    /// it was last asked — including a reboot made outside Termio, which no
    /// detach announces. A boot starts portrait, with a new HID service and
    /// accessibility bridge; the old connection would send input nowhere.
    private func noteBoot() {
        let current = boot
        let wasTurned = lock.withLock { () -> Bool in
            guard current != knownBoot else { return false }
            defer { knownBoot = current }
            guard knownBoot != nil else { return false }
            let turned = interface != .upright
            orientation = .portrait
            interface = .upright
            hid = nil
            readers.removeAll()
            hostReader = nil
            strokeEdge = nil
            generation += 1
            // An attached display is checked every few seconds and rebinds on
            // its own; one only screenshots read would keep the old boot's.
            if attachment == nil { framebuffer = nil }
            return turned
        }
        // The pane draws and maps touches by the last turn it was told of;
        // a reset it isn't told of would leave it landscape on a portrait boot.
        if wasTurned {
            let size = Turn.upright.interfaceSize(panel: pointSize)
            Wire.event("rotated", [
                "stream": stream, "rotation": Turn.upright.rawValue,
                "pointWidth": size.width, "pointHeight": size.height,
            ])
        }
    }

    /// Reads the device's orientation — from the simulator where it can report
    /// it, else from the record of this helper's own last turn — then works out
    /// the interface's turn, and reports a change as a `rotated` event.
    @discardableResult
    func refreshOrientation() async -> SimulatorDeviceOrientation {
        noteBoot()
        var read: SimulatorDeviceOrientation?
        if Self.coreDeviceReportsDisplays {
            read = try? await simulator.orientation.current()
        }
        if read == nil {
            read = OrientationRecord.read(udid: simulator.udid, boot: boot)
        }
        let device: SimulatorDeviceOrientation
        if let read, read != .faceUp, read != .faceDown, read != .unknown {
            device = read
            lock.withLock { orientation = read }
        } else {
            device = lock.withLock { orientation }
        }
        let resolved = await interfaceTurn(for: device)
        let changed = lock.withLock {
            defer { interface = resolved }
            return interface != resolved
        }
        if changed {
            let size = interfaceSize
            Wire.event("rotated", [
                "stream": stream, "rotation": resolved.rawValue,
                "pointWidth": size.width, "pointHeight": size.height,
            ])
        }
        return device
    }

    /// The interface's turn for a device held at `device`. Nothing on Xcode 26
    /// reports it, so it is read off the frontmost window: a landscape device
    /// whose window is still taller than wide has an interface that did not
    /// turn. Upside down, only an iPad turns — no iPhone home screen does, and
    /// iPhone apps almost never do.
    private func interfaceTurn(for device: SimulatorDeviceOrientation) async -> Turn {
        let held = Turn(device)
        switch held {
        case .upright:
            return .upright
        case .upsideDown:
            return min(pointSize.width, pointSize.height) >= 600 ? .upsideDown : .upright
        case .clockwise, .counterclockwise:
            // Wider than the panel is wide means turned. Not "wider than tall":
            // iPad apps report a square window, as wide as the panel is tall.
            guard let window = await frontmostWindowSize() else { return held }
            return window.width > pointSize.width + 1 ? held : .upright
        }
    }

    private func frontmostWindowSize() async -> CGSize? {
        let options = AccessibilityRequestOptions(format: .complete, keys: [.frameDict, .frame])
        // One attempt: a guess at the turn is not worth waiting out an app's start.
        guard let document = try? await frontmostOnce({ try await $0.describe(.frontmost, options: options).document }),
              let data = try? JSONEncoder().encode(document),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let root = (object["elements"] as? [[String: Any]])?.first,
              let frame = root["frame"] as? [String: Any],
              let width = (frame["width"] as? NSNumber)?.doubleValue,
              let height = (frame["height"] as? NSNumber)?.doubleValue
        else { return nil }
        return CGSize(width: width, height: height)
    }

    /// While the pane shows the device, follow turns made elsewhere. Each read
    /// spawns a short-lived guest in the simulator, so a few seconds apart.
    private func watchOrientation() {
        orientationWatch?.cancel()
        orientationWatch = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshOrientation()
                // The display can move to a new surface with no callback — on
                // waking from sleep, and as a boot settles — and the pane would
                // hold the last frame of the old one for good. Checked here too,
                // not only after a power press, since a boot needs no press.
                self?.reattachIfSurfaceMoved()
                do {
                    try await Task.sleep(for: .seconds(3))
                } catch {
                    return  // Cancelled by `detach`.
                }
            }
        }
    }

    func setHardwareKeyboard(_ connected: Bool) async throws {
        try await simulator.preferences.apply(.hardwareKeyboard(connected))
    }

    /// Whether CoreDevice can report display geometry and orientation, which
    /// came with CoreSimulator 1155.4 (Xcode 27) — the version idb itself keys
    /// its input transport on. Asked of an older CoreSimulator, the lookup does
    /// not fail: it blocks a synchronous XPC call for tens of seconds, and every
    /// tap queued behind it with it.
    static let coreDeviceReportsDisplays: Bool = {
        guard let simDevice = NSClassFromString("SimDevice"),
              let version = Bundle(for: simDevice).infoDictionary?["CFBundleVersion"] as? String
        else { return false }
        return version.compare("1155.4", options: .numeric) != .orderedAscending
    }()

    private func turnsPointsItself() async -> Bool {
        if let known = lock.withLock({ idbTurnsPoints }) { return known }
        guard Self.coreDeviceReportsDisplays else {
            lock.withLock { idbTurnsPoints = false }
            return false
        }
        let reports = (try? await simulator.displays.configuration()) != nil
        lock.withLock { idbTurnsPoints = reports }
        return reports
    }

    private func onPanel(_ event: SimulatorHIDEvent, turn: Turn) -> SimulatorHIDEvent {
        let panel = pointSize
        func move(_ x: Double, _ y: Double) -> CGPoint {
            turn.panelPoint(CGPoint(x: x, y: y), panel: panel)
        }
        switch event {
        case let .touch(direction, x, y, edge):
            let point = move(x, y)
            return .touch(direction: direction, x: point.x, y: point.y, edge: turn.panelEdge(edge))
        case let .twoFingerTouch(direction, finger1, finger2):
            return .twoFingerTouch(
                direction: direction,
                finger1: turn.panelPoint(finger1, panel: panel),
                finger2: turn.panelPoint(finger2, panel: panel))
        case let .composite(events):
            return .composite(events.map { onPanel($0, turn: turn) })
        default:
            return event
        }
    }

    private func connectedHID() async throws -> SimulatorHID {
        noteBoot()
        let (cached, started) = lock.withLock { (self.hid, generation) }
        if let cached { return cached }
        let connected = try await simulator.hid.connect()
        // Made across a detach: it reaches the boot left behind, where input
        // is lost, so the call fails where it can be retried.
        guard lock.withLock({ () -> Bool in
            guard generation == started else { return false }
            self.hid = connected
            return true
        }) else { throw HelperError.restarted(simulator.udid) }
        return connected
    }

    // MARK: Accessibility

    /// The frontmost app's accessibility tree, or the element under a point, as
    /// idb's own JSON document. The reader is the exclusive in-simulator bridge:
    /// warm reads are tens of milliseconds, where a cold one spawns the guest.
    func inspect(at point: CGPoint?, marker: String? = nil, matchKey: AXSearchableKey = .label) async throws -> Data {
        let options = AccessibilityRequestOptions(format: .complete)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let point {
            guard let response = try await whileStarting({ try await automation().hitTest(at: point, options: options) })
            else { return Data("{\"elements\":[]}".utf8) }
            return await notingPlaceholders(try encoder.encode(response.document))
        }
        let query: AccessibilityElementQuery = marker.map { .marker(value: $0, key: matchKey, depth: .max) } ?? .frontmost
        let document = try await withFrontmost { try await $0.describe(query, options: options).document }
        return await notingPlaceholders(try encoder.encode(document))
    }

    /// iOS reports an empty text field's placeholder as its value, and the
    /// in-simulator reader cannot fetch the placeholder to tell the two apart:
    /// an agent read `ws://mac-hostname:8787` as text to delete
    /// (termio-sh/termio#774). The host's reader can, though it is slower, so
    /// only each text field that has a value is read again there. One whose
    /// value is its placeholder has its value dropped; the placeholder is added
    /// either way. Text typed to match the placeholder exactly reads as empty,
    /// which nothing in the tree can tell apart.
    private func notingPlaceholders(_ data: Data) async -> Data {
        guard var document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var elements = document["elements"] as? [[String: Any]]
        else { return data }
        var changed = false
        // One failed host read gives up on the rest: an app too busy to answer
        // one field will not answer the next, and each wait is seconds long.
        var failed = false
        func note(_ elements: inout [[String: Any]]) async {
            for index in elements.indices {
                if !failed, Self.textTypes.contains(elements[index]["type"] as? String ?? ""),
                   let value = elements[index]["value"] as? String, !value.isEmpty,
                   let frame = Self.rect(elements[index]["frame"]) {
                    do {
                        if let placeholder = try await placeholder(of: frame) {
                            elements[index]["placeholder"] = placeholder
                            if value == placeholder { elements[index]["value"] = NSNull() }
                            changed = true
                        }
                    } catch {
                        Wire.log("reading a placeholder at \(frame) failed: \(error.localizedDescription)")
                        failed = true
                    }
                }
                if var children = elements[index]["children"] as? [[String: Any]], !children.isEmpty {
                    await note(&children)
                    elements[index]["children"] = children
                }
            }
        }
        await note(&elements)
        guard changed else { return data }
        document["elements"] = elements
        return (try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])) ?? data
    }

    /// The fields UIKit gives a placeholder. A text view has none.
    private static let textTypes: Set<String> = ["TextField", "SecureTextField", "SearchField"]

    /// The placeholder of the text field at `frame`, read by the host's reader
    /// at its centre; nil when that lands on anything but the same field.
    private func placeholder(of frame: CGRect) async throws -> String? {
        let reader = try lock.withLock { () throws -> any UIAutomation in
            if let hostReader { return hostReader }
            let created = try simulator.uiAutomation(backend: .accessibility)
            hostReader = created
            return created
        }
        let options = AccessibilityRequestOptions(format: .complete, keys: [.frame, .frameDict, .type, .placeholder])
        guard let response = try await reader.hitTest(at: CGPoint(x: frame.midX, y: frame.midY), options: options),
              let data = try? JSONEncoder().encode(response.document),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let element = (object["elements"] as? [[String: Any]])?.first,
              let found = Self.rect(element["frame"]),
              abs(found.minX - frame.minX) <= 1, abs(found.minY - frame.minY) <= 1,
              abs(found.width - frame.width) <= 1, abs(found.height - frame.height) <= 1,
              let placeholder = element["placeholder"] as? String, !placeholder.isEmpty
        else { return nil }
        return placeholder
    }

    /// Taps the centre of the element whose label contains `label`, and returns
    /// where. A real touch rather than the accessibility "press" action:
    /// SpringBoard's icons ignore the press, so it reported success on a home
    /// screen that never opened the app.
    ///
    /// The first match in tree order is not trusted. After a rotation the tree
    /// still holds the old layout — the same buttons, a hand's width from where
    /// they are now drawn, inside containers the size of the old orientation.
    /// A container larger than the screen marks a layout no longer shown, and
    /// everything inside it is passed over. (The root is exempt: an iPad app's
    /// root reports a square as wide as the panel is tall.)
    func tap(label: String) async throws -> CGPoint {
        let options = AccessibilityRequestOptions(format: .complete)
        let document = try await withFrontmost { try await $0.describe(.frontmost, options: options).document }
        let data = try JSONEncoder().encode(document)
        let screen = CGRect(origin: .zero, size: interfaceSize)
        let bounds = screen.insetBy(dx: -1, dy: -1)
        var candidates: [CGRect] = []
        func walk(_ elements: [[String: Any]], depth: Int) {
            for element in elements {
                let frame = Self.rect(element["frame"])
                if depth > 0, let frame, !bounds.contains(frame), frame.width > screen.width + 1 || frame.height > screen.height + 1 {
                    continue
                }
                // An empty frame is an element not laid out on screen — an icon on
                // a home screen page not shown — and its "centre" is the corner.
                if let text = element["label"] as? String, text.contains(label), let frame,
                   frame.width > 0, frame.height > 0,
                   screen.contains(CGPoint(x: frame.midX, y: frame.midY)) {
                    candidates.append(frame)
                }
                walk(element["children"] as? [[String: Any]] ?? [], depth: depth + 1)
            }
        }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        walk(object?["elements"] as? [[String: Any]] ?? [], depth: 0)
        guard let chosen = candidates.first else {
            throw HelperError.noElement(label)
        }
        let center = CGPoint(x: chosen.midX, y: chosen.midY)
        try await send(.tapAt(x: Double(center.x), y: Double(center.y)))
        return center
    }

    private static func rect(_ value: Any?) -> CGRect? {
        guard let frame = value as? [String: Any],
              let x = (frame["x"] as? NSNumber)?.doubleValue, let y = (frame["y"] as? NSNumber)?.doubleValue,
              let width = (frame["width"] as? NSNumber)?.doubleValue,
              let height = (frame["height"] as? NSNumber)?.doubleValue
        else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Runs `body` against a reader that can name the frontmost app. No one way
    /// of finding it works everywhere: the window server answers nothing on the
    /// home screen, and a centre-point hit-test misses a screen whose middle is
    /// empty. The first method that answers is kept for the next read.
    private func withFrontmost<T>(_ body: (any UIAutomation) async throws -> T) async throws -> T {
        try await whileStarting { try await frontmostOnce(body) }
    }

    private func frontmostOnce<T>(_ body: (any UIAutomation) async throws -> T) async throws -> T {
        let preferred = lock.withLock { frontmostMethod }
        let methods = [preferred] + AXBridgeFrontmostMethod.ordered.filter { $0 != preferred }
        var lastError: (any Error)?
        for method in methods {
            do {
                let result = try await body(try automation(method))
                lock.withLock { frontmostMethod = method }
                return result
            } catch let error as AXBridgeError {
                guard case .frontmostUnresolved = error else { throw error }
                lastError = error
            }
        }
        throw lastError ?? HelperError.notAttached(simulator.udid)
    }


    /// How long a just-launched app is given to start answering. Short,
    /// because a `tap --label` waits inline: touches from the pane queue behind
    /// it, and one failed attempt alone can take five seconds.
    private static let startupGrace: TimeInterval = 6

    /// Runs a read again while the app it lands on is still starting. An app
    /// launched a moment ago can miss its first accessibility request, or have
    /// no accessibility server yet, and answers a second or two later; an agent
    /// that taps right after `launch` met that as a failed tap
    /// (termio-sh/termio#773). Only reads are repeated, and these failures
    /// wrote nothing to the app, so a tap still lands once.
    private func whileStarting<T>(_ body: () async throws -> T) async throws -> T {
        let deadline = Date().addingTimeInterval(Self.startupGrace)
        var pause: UInt64 = 300_000_000
        while true {
            do {
                return try await body()
            } catch where Self.isStarting(error)
                && Date().addingTimeInterval(Double(pause) / 1_000_000_000) < deadline {
                Wire.log("retrying a read while the app starts: \(error.localizedDescription)")
                try await Task.sleep(nanoseconds: pause)
                pause = min(pause * 2, 1_000_000_000)
            }
        }
    }

    private static func isStarting(_ error: any Error) -> Bool {
        switch error {
        case let error as UIAutomationError:
            switch error {
            case .applicationNotResponding, .applicationUnavailable: return true
            default: return false
            }
        case let error as AXBridgeError:
            switch error {
            case .applicationNotResponding, .applicationUnavailable: return true
            default: return false
            }
        default:
            return false
        }
    }

    private func automation(_ method: AXBridgeFrontmostMethod? = nil) throws -> any UIAutomation {
        let method = method ?? lock.withLock { frontmostMethod }
        noteBoot()
        let (cached, started) = lock.withLock { (readers[method], generation) }
        if let cached { return cached }
        let created = try simulator.uiAutomation(
            backend: UIAutomationBackend(resolvedName: .axBridgeExclusive, frontmostMethod: method))
        guard lock.withLock({ () -> Bool in
            guard generation == started else { return false }
            readers[method] = created
            return true
        }) else { throw HelperError.restarted(simulator.udid) }
        return created
    }
}

extension AXBridgeFrontmostMethod {
    static let ordered: [AXBridgeFrontmostMethod] = [.windowServer, .runningBoard, .centerPoint]
}

/// `image` turned so the interface reads upright: the panel rotated against
/// the interface's turn.
private func upright(_ image: CGImage, turn: Turn) -> CGImage? {
    guard turn != .upright else { return image }
    let width = turn.isQuarter ? image.height : image.width
    let height = turn.isQuarter ? image.width : image.height
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return image }
    context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
    let angle: CGFloat = switch turn {
    case .clockwise: -.pi / 2
    case .counterclockwise: .pi / 2
    case .upsideDown: .pi
    case .upright: 0
    }
    context.rotate(by: angle)
    context.draw(image, in: CGRect(
        x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
        width: CGFloat(image.width), height: CGFloat(image.height)))
    return context.makeImage()
}
