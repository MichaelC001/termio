import CoreGraphics
import Foundation
import FBSimulatorControl

/// How the interface sits on the panel. The framebuffer is always the panel —
/// portrait for a phone or iPad — and a rotated interface is drawn turned
/// inside it, so everything that speaks interface coordinates (accessibility
/// frames, an agent's taps, the pane's pointer) needs this to reach the panel.
///
/// The cases and their point maps mirror idb's `SimulatorDisplayRotation`.
/// idb applies that map itself on toolchains whose CoreDevice reports display
/// geometry (Xcode 27); on Xcode 26 it reports none, sends points unturned,
/// and the helper applies the map instead from the orientation it last wrote.
enum Turn: String, Sendable {
    case upright = "rot0"
    case clockwise = "rot90"
    case upsideDown = "rot180"
    case counterclockwise = "rot270"

    init(_ orientation: SimulatorDeviceOrientation) {
        switch orientation {
        // Measured, not derived: in landscape right a tap at the interface's
        // Year button lands only through the clockwise map.
        case .landscapeRight: self = .clockwise
        case .landscapeLeft: self = .counterclockwise
        case .portraitUpsideDown: self = .upsideDown
        default: self = .upright
        }
    }

    var isQuarter: Bool { self == .clockwise || self == .counterclockwise }

    /// The interface's size for a panel of `panel` points.
    func interfaceSize(panel: CGSize) -> CGSize {
        isQuarter ? CGSize(width: panel.height, height: panel.width) : panel
    }

    /// An interface point as a panel point — idb's `unrotatedPoint(from:)`.
    func panelPoint(_ point: CGPoint, panel: CGSize) -> CGPoint {
        switch self {
        case .upright: point
        case .clockwise: CGPoint(x: point.y, y: panel.height - point.x)
        case .upsideDown: CGPoint(x: panel.width - point.x, y: panel.height - point.y)
        case .counterclockwise: CGPoint(x: panel.width - point.y, y: point.x)
        }
    }

    /// An interface edge as the panel edge it lies on — idb's `unrotatedEdge`.
    func panelEdge(_ edge: SimulatorHIDEdge) -> SimulatorHIDEdge {
        guard edge != .none else { return .none }
        let edges: [SimulatorHIDEdge] = [.top, .right, .bottom, .left]
        let turns = switch self {
        case .upright: 0
        case .clockwise: 3
        case .upsideDown: 2
        case .counterclockwise: 1
        }
        guard let index = edges.firstIndex(of: edge) else { return .none }
        return edges[(index + turns) % edges.count]
    }

    /// The orientation one quarter turn on, the way the device itself turns
    /// when Simulator.app's Rotate Left or Rotate Right is chosen.
    static func next(after orientation: SimulatorDeviceOrientation, clockwise: Bool) -> SimulatorDeviceOrientation {
        let cycle: [SimulatorDeviceOrientation] = [.portrait, .landscapeRight, .portraitUpsideDown, .landscapeLeft]
        let index = cycle.firstIndex(of: orientation) ?? 0
        return cycle[(index + (clockwise ? 1 : cycle.count - 1)) % cycle.count]
    }
}

/// The edge a gesture starting at `point` is an edge gesture from: within 4
/// points of the interface's edge, as a finger on the bezel would be. Back,
/// the notification shade, Home and Control Center all start there.
func gestureEdge(at point: CGPoint, interface size: CGSize) -> SimulatorHIDEdge {
    let reach: CGFloat = 4
    guard point.x >= 0, point.y >= 0, point.x <= size.width, point.y <= size.height else { return .none }
    if point.y <= reach { return .top }
    if point.y >= size.height - reach { return .bottom }
    if point.x <= reach { return .left }
    if point.x >= size.width - reach { return .right }
    return .none
}

/// The orientation the helper last wrote, per device and boot, on disk. Where
/// the simulator cannot report its orientation (Xcode 26 and the runtimes it
/// ships), this is all there is, and it has to outlive the helper process: the
/// app respawns it, and a respawn that forgot a turn would map every touch to
/// the wrong place. A boot resets the device to portrait, so a record is only
/// believed for the boot that wrote it — `launchd_bootstrap.plist` is rewritten
/// at every boot, and its date names the boot.
enum OrientationRecord {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/termio/simulator-orientation.json")
    private static let lock = NSLock()

    static func boot(dataPath: String) -> String? {
        let marker = URL(fileURLWithPath: dataPath).appendingPathComponent("var/run/launchd_bootstrap.plist")
        guard let date = (try? FileManager.default.attributesOfItem(atPath: marker.path))?[.modificationDate] as? Date
        else { return nil }
        return String(Int(date.timeIntervalSince1970))
    }

    static func read(udid: String, boot: String?) -> SimulatorDeviceOrientation? {
        lock.withLock {
            guard let boot, let entry = load()[udid], entry["boot"] == boot,
                  let raw = entry["orientation"] else { return nil }
            return SimulatorDeviceOrientation(rawValue: raw)
        }
    }

    static func write(_ orientation: SimulatorDeviceOrientation, udid: String, boot: String?) {
        lock.withLock {
            guard let boot else { return }
            var records = load()
            records[udid] = ["boot": boot, "orientation": orientation.rawValue]
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: records).write(to: url, options: .atomic)
            } catch {
                Wire.log("could not record \(udid)'s orientation: \(error)")
            }
        }
    }

    private static func load() -> [String: [String: String]] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]]) ?? [:]
    }
}
