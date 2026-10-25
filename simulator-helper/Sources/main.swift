import CoreGraphics
import FBControlCore
import FBSimulatorAX
import FBSimulatorControl
import Foundation

/// termio-sim: the process that holds Apple's private simulator frameworks, so a
/// crash or a hang inside them takes this process down and never the app. The app
/// spawns one, talks to it over stdio (see `Wire`), and respawns it on exit.
///
/// Arguments:
///   --service <name>    the Mach service the app checked in to receive surfaces
///   --resources <dir>   where SimulatorFrameworkBridge-iOS lives (the in-simulator
///                       half of the accessibility reader)

let arguments = CommandLine.arguments
func argument(_ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

if let resources = argument("--resources") {
    // Absolute, always: the guest is spawned by the simulator's launchd, which
    // rejects a relative program path ("Invalid or missing Program").
    BundledResources.hostDirectoryPath = URL(fileURLWithPath: resources).standardizedFileURL.path
}
let surfacePort = argument("--service").flatMap { SurfacePort(serviceName: $0) }

let control: SimulatorControlBootstrap
do {
    control = try SimulatorControlBootstrap(
        configuration: SimulatorControlConfiguration(deviceSetPath: nil, logger: nil))
} catch {
    // Reported as an event rather than a crash: the usual cause is a missing or
    // half-installed Xcode, which the app shows the person instead of a respawn loop.
    Wire.event("unavailable", ["error": error.localizedDescription])
    exit(2)
}

final class Registry: @unchecked Sendable {
    private var devices: [String: Device] = [:]
    private var nextStream: UInt32 = 1
    private let lock = NSLock()

    func device(_ udid: String) throws -> Device {
        try lock.withLock {
            if let device = devices[udid] { return device }
            guard let simulator = control.set.simulator(withUDID: udid) else {
                throw HelperError.noSuchDevice(udid)
            }
            guard simulator.state == .booted else {
                throw HelperError.notBooted(udid, stateWord(simulator.state))
            }
            let device = Device(simulator: simulator, stream: nextStream)
            nextStream += 1
            devices[udid] = device
            return device
        }
    }
}

func stateWord(_ state: TargetState) -> String {
    switch state {
    case .creating: "creating"
    case .shutdown: "shutdown"
    case .booting: "booting"
    case .booted: "booted"
    case .shuttingDown: "shutting-down"
    default: "unknown"
    }
}

let registry = Registry()

func listDevices() -> [String: Any] {
    let devices = control.set.allSimulators.map { simulator -> [String: Any] in
        [
            "udid": simulator.udid,
            "name": simulator.name,
            "state": stateWord(simulator.state),
            "os": "\(simulator.osVersion)",
        ]
    }
    return ["devices": devices]
}

func point(_ request: Request, x: String = "x", y: String = "y") throws -> (Double, Double) {
    (try request.number(x), try request.number(y))
}

func button(named name: String) throws -> SimulatorHIDButton {
    switch name.lowercased() {
    case "home": .homeButton
    case "lock": .lock
    case "side": .sideButton
    case "siri": .siri
    case "volume-up": .volumeUp
    case "volume-down": .volumeDown
    case "apple-pay": .applePay
    default: throw HelperError.unknownButton(name)
    }
}

func handle(_ request: Request) async throws {
    switch request.op {
    case "devices":
        Wire.reply(request.id, result: listDevices())
    case "describe":
        let device = try registry.device(try request.string("udid"))
        await device.refreshOrientation()
        Wire.reply(request.id, result: device.summary)
    case "attach":
        let device = try registry.device(try request.string("udid"))
        await device.refreshOrientation()
        guard let surfacePort else { throw HelperError.missing("--service") }
        try device.attach(to: surfacePort)
        Wire.reply(request.id, result: device.summary)
    case "detach":
        try registry.device(try request.string("udid")).detach()
        Wire.reply(request.id, result: [:])
    case "tap":
        let device = try registry.device(try request.string("udid"))
        if let label = request.optionalString("label") {
            let center = try await device.tap(label: label)
            Wire.reply(request.id, result: ["x": center.x, "y": center.y])
            return
        } else {
            let (x, y) = try point(request)
            if let duration = request.optionalNumber("duration"), duration > 0 {
                try await device.send(.tapAt(x: x, y: y, duration: duration))
            } else {
                try await device.send(.tapAt(x: x, y: y))
            }
        }
        Wire.reply(request.id, result: [:])
    case "touch":
        // One digitizer report. iOS reads the position while the finger is down,
        // so a move is another down at the new point; only `up` lifts it.
        let device = try registry.device(try request.string("udid"))
        let (x, y) = try point(request)
        let direction: SimulatorHIDDirection = try request.string("phase") == "up" ? .up : .down
        try await device.send(.touch(direction: direction, x: x, y: y))
        Wire.reply(request.id, result: [:])
    case "swipe":
        let device = try registry.device(try request.string("udid"))
        let (x, y) = try point(request)
        let (x2, y2) = try point(request, x: "x2", y: "y2")
        try await device.send(.swipe(
            x, yStart: y, xEnd: x2, yEnd: y2, delta: SimulatorHIDEvent.defaultSwipeDelta,
            duration: request.optionalNumber("duration") ?? 0.3,
            edge: device.edge(startingAt: CGPoint(x: x, y: y))))
        Wire.reply(request.id, result: [:])
    case "touchPath":
        // A finger along an arbitrary path: down at the first sample, up at the
        // last, `dt_ms` before each. What a scroll that eases out, a long press
        // that then drags, or a signature is made of.
        let device = try registry.device(try request.string("udid"))
        let samples = try pathSamples(request, key: "points")
        guard let first = samples.first, let last = samples.last else { throw HelperError.missing("points") }
        let edge = device.edge(startingAt: CGPoint(x: first.x, y: first.y))
        var events: [SimulatorHIDEvent] = []
        for sample in samples {
            if sample.delay > 0 { events.append(.delay(sample.delay)) }
            events.append(.touch(direction: .down, x: sample.x, y: sample.y, edge: edge))
        }
        events.append(.touch(direction: .up, x: last.x, y: last.y, edge: edge))
        try await device.send(.composite(events))
        Wire.reply(request.id, result: ["samples": samples.count])
    case "touch2Path":
        // Two fingers, for pinch and rotate.
        let device = try registry.device(try request.string("udid"))
        guard let raw = request.parameters["points2"] as? [[String: Any]], raw.count >= 2 else {
            throw HelperError.missing("points2")
        }
        var events: [SimulatorHIDEvent] = []
        var total = 0.0
        var lastPair: (CGPoint, CGPoint)?
        for sample in raw {
            guard let x1 = (sample["x1"] as? NSNumber)?.doubleValue, let y1 = (sample["y1"] as? NSNumber)?.doubleValue,
                  let x2 = (sample["x2"] as? NSNumber)?.doubleValue, let y2 = (sample["y2"] as? NSNumber)?.doubleValue
            else { throw HelperError.missing("points2[].x1/y1/x2/y2") }
            let delay = min(1, max(0, ((sample["dt_ms"] as? NSNumber)?.doubleValue ?? 16) / 1000))
            total += delay
            guard total <= pathLimit else { throw HelperError.pathTooLong }
            if delay > 0 { events.append(.delay(delay)) }
            let pair = (CGPoint(x: x1, y: y1), CGPoint(x: x2, y: y2))
            events.append(.twoFingerTouch(direction: .down, finger1: pair.0, finger2: pair.1))
            lastPair = pair
        }
        if let lastPair {
            events.append(.twoFingerTouch(direction: .up, finger1: lastPair.0, finger2: lastPair.1))
        }
        try await device.send(.composite(events))
        Wire.reply(request.id, result: ["samples": raw.count])
    case "button":
        let device = try registry.device(try request.string("udid"))
        let name = try request.string("name")
        try await device.send(.shortButtonPress(try button(named: name)))
        Wire.reply(request.id, result: [:])
        if ["lock", "side"].contains(name.lowercased()) {
            Task { await device.followDisplayAfterPower() }
        }
    case "text":
        let device = try registry.device(try request.string("udid"))
        let (event, skipped) = Keymap.events(typing: try request.string("text"))
        try await device.send(event)
        Wire.reply(request.id, result: ["skipped": skipped])
    case "key":
        let device = try registry.device(try request.string("udid"))
        let name = try request.string("name")
        guard let press = Keymap.press(named: name) else { throw HelperError.unknownKey(name) }
        let count = max(1, min(20, Int(request.optionalNumber("count") ?? 1)))
        try await device.send(.composite(Array(repeating: press, count: count).flatMap { $0 }))
        Wire.reply(request.id, result: ["count": count])
    case "rotate":
        let device = try registry.device(try request.string("udid"))
        let target = request.optionalString("orientation").flatMap(SimulatorDeviceOrientation.init(rawValue:))
        _ = try await device.rotate(
            clockwise: request.optionalString("direction").map { $0 != "left" }, to: target)
        Wire.reply(request.id, result: device.summary)
    case "setKeyboard":
        // The on-screen keyboard shows only while no hardware keyboard is
        // connected, so "show" disconnects the Mac's.
        let device = try registry.device(try request.string("udid"))
        let show = try request.string("state") == "show"
        try await device.setHardwareKeyboard(!show)
        Wire.reply(request.id, result: ["onScreenKeyboard": show])
    case "screenshot":
        let device = try registry.device(try request.string("udid"))
        await device.refreshOrientation()
        Wire.reply(request.id, result: try await device.screenshot(to: try request.string("path")))
    case "inspect":
        let device = try registry.device(try request.string("udid"))
        await device.refreshOrientation()
        var at: CGPoint?
        if let x = request.optionalNumber("x"), let y = request.optionalNumber("y") {
            at = CGPoint(x: x, y: y)
        }
        // `match` is what `marker` is compared with: the label by default, or the
        // value, the element type, or its accessibility identifier.
        let key: AXSearchableKey = switch request.optionalString("match") {
        case "value": .value
        case "role", "type": .role
        case "id", "identifier": .uniqueID
        default: .label
        }
        Wire.reply(request.id, rawResult: try await device.inspect(
            at: at, marker: request.optionalString("marker"), matchKey: key))
    default:
        throw HelperError.unknownOperation(request.op)
    }
}

/// Input runs in arrival order, inline in the read loop: a drag is a stream of
/// touch reports, and two of them swapping in flight is a finger that jumps back.
/// Everything else runs beside it, so a slow accessibility read never holds up a tap.
let orderedOperations: Set<String> = [
    "tap", "touch", "swipe", "touchPath", "touch2Path", "button", "text", "key", "rotate",
]

/// The longest a scripted path may take, as Simulator.app's own limit on a
/// recorded gesture: long enough for any real gesture, short enough that a
/// mistaken `dt_ms` cannot hold the device for minutes.
let pathLimit = 30.0

struct PathSample {
    let x: Double
    let y: Double
    let delay: Double
}

func pathSamples(_ request: Request, key: String) throws -> [PathSample] {
    guard let raw = request.parameters[key] as? [[String: Any]], !raw.isEmpty else { throw HelperError.missing(key) }
    var total = 0.0
    return try raw.map { sample in
        guard let x = (sample["x"] as? NSNumber)?.doubleValue, let y = (sample["y"] as? NSNumber)?.doubleValue else {
            throw HelperError.missing("\(key)[].x/y")
        }
        let delay = min(1, max(0, ((sample["dt_ms"] as? NSNumber)?.doubleValue ?? 16) / 1000))
        total += delay
        guard total <= pathLimit else { throw HelperError.pathTooLong }
        return PathSample(x: x, y: y, delay: delay)
    }
}

func run(_ request: Request) async {
    do {
        try await handle(request)
    } catch {
        Wire.fail(request.id, error.localizedDescription)
    }
}

let input = FileHandle.standardInput
Task.detached {
    for try await line in input.bytes.lines {
        guard let request = Request(line: Data(line.utf8)) else {
            Wire.log("ignored a malformed request line")
            continue
        }
        if orderedOperations.contains(request.op) {
            await run(request)
        } else {
            Task { await run(request) }
        }
    }
    // The app closed our stdin: it quit or replaced us. Nothing is left to serve.
    exit(0)
}
Wire.event("ready", ["pid": getpid()])
dispatchMain()
