import AppKit
import Darwin
import Foundation
import IOSurface
import os

/// One iOS Simulator the helper can see, as `devices` lists it.
struct SimulatorDevice: Identifiable, Hashable, Sendable {
    let udid: String
    let name: String
    let state: String
    let os: String

    var id: String { udid }
    var isBooted: Bool { state == "booted" }
}

/// What `attach` reports about a device's screen: the size touches are measured
/// in (points, top-left origin) and the stream its surfaces arrive tagged with.
struct SimulatorScreen: Equatable, Sendable {
    let udid: String
    let name: String
    let stream: UInt32
    /// The interface's size: turned with the device, so a landscape iPad is
    /// wider than tall. Every point an agent or the pointer sends is in it.
    var pointSize: CGSize
    /// How the interface sits on the panel the framebuffer is drawn for —
    /// `rot0`, `rot90`, `rot180` or `rot270`, as the helper reports it.
    var rotation: String = "rot0"
    /// The device type's `.simdevicetype` bundle, where its bezel and screen
    /// mask are named. Nil when the helper could not say.
    var deviceTypePath: String?
}

enum SimulatorHostError: LocalizedError {
    case unavailable(String)
    case helperExited
    case failed(String)
    case malformedReply

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        case .helperExited: localized("The simulator helper quit. Try again.")
        case .failed(let message): message
        case .malformedReply: localized("The simulator helper sent a reply Termio couldn’t read.")
        }
    }
}

/// The app's side of `termio-sim`, the helper process that holds Apple's private
/// simulator frameworks (simulator-helper/). Those frameworks change with every
/// Xcode and can crash or hang inside the caller; out of process, that costs a
/// respawn instead of the app.
///
/// Two channels, both owned here. Requests and replies are JSON lines over the
/// helper's stdio. Display surfaces arrive as Mach send rights on a receive port
/// this process checks in with launchd, so the pane shows the simulator's own
/// IOSurface with no copy and no video encode.
@MainActor
final class SimulatorHost: ObservableObject {
    static let shared = SimulatorHost()

    @Published private(set) var devices: [SimulatorDevice] = []
    /// The device the Simulator pane shows, and the one `termio sim` drives when
    /// it names none. One for the app: the pane is a view of a device, and two
    /// panes each attached to a different one is a choice nobody has asked for.
    @Published private(set) var screen: SimulatorScreen?
    /// Set while a shut-down device the person picked is booting.
    @Published private(set) var booting: String?
    @Published private(set) var lastError: String?
    /// Why the pane can't work on this Mac, when it can't. Nil means it can.
    @Published private(set) var unavailableReason: String?

    private var process: Process?
    private var input: FileHandle?
    private var nextRequest = 1
    private var pending: [Int: (Result<Data, Error>) -> Void] = [:]
    private var lineBuffer = Data()
    private let receiver = SimulatorSurfaceReceiver()
    private var lastReattach = Date.distantPast

    /// Per stream: the latest surface and the views presenting it. Kept outside
    /// SwiftUI state on purpose — a frame tick arrives up to 60 times a second,
    /// and publishing it would re-render the pane for every one.
    private var surfaces: [UInt32: IOSurface] = [:]
    private var presenters: [UInt32: [ObjectIdentifier: (IOSurface?) -> Void]] = [:]

    private init() {
        unavailableReason = Self.platformRefusal() ?? (Self.helperURL() == nil
            ? localized("This build of Termio doesn’t include the simulator helper.")
            : nil)
        receiver.onSurface = { [weak self] stream, surface in
            Task { @MainActor in self?.receive(surface, stream: stream) }
        }
    }

    // MARK: Requests

    /// Sends one request and waits for its reply's `result`, as raw JSON.
    func call(_ op: String, _ parameters: [String: Any] = [:]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            send(op, parameters) { continuation.resume(with: $0) }
        }
    }

    /// Sends one request now, on the caller's turn of the main actor, and logs
    /// a failure instead of returning it. For input from the pane: a drag is a
    /// run of touch reports whose order is the gesture, and writing each one
    /// before returning is what keeps that order on the wire.
    func fire(_ op: String, _ parameters: [String: Any]) {
        send(op, parameters) { result in
            if case .failure(let error) = result {
                Log.simulator.error("\(op, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func send(_ op: String, _ parameters: [String: Any],
                      reply: @escaping (Result<Data, Error>) -> Void) {
        if let unavailableReason {
            reply(.failure(SimulatorHostError.unavailable(unavailableReason)))
            return
        }
        do {
            try startIfNeeded()
        } catch {
            reply(.failure(error))
            return
        }
        guard let input else {
            reply(.failure(SimulatorHostError.helperExited))
            return
        }
        let id = nextRequest
        nextRequest += 1
        var object = parameters
        object["id"] = id
        object["op"] = op
        do {
            var line = try JSONSerialization.data(withJSONObject: object)
            line.append(0x0A)
            pending[id] = reply
            try input.write(contentsOf: line)
        } catch {
            pending[id] = nil
            reply(.failure(SimulatorHostError.helperExited))
        }
    }

    /// `call` with the result decoded to a dictionary.
    func callObject(_ op: String, _ parameters: [String: Any] = [:]) async throws -> [String: Any] {
        let data = try await call(op, parameters)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SimulatorHostError.malformedReply
        }
        return object
    }

    @discardableResult
    func refreshDevices() async -> [SimulatorDevice] {
        guard unavailableReason == nil,
              let result = try? await callObject("devices"),
              let rows = result["devices"] as? [[String: Any]]
        else { return devices }
        let listed = rows.compactMap { row -> SimulatorDevice? in
            guard let udid = row["udid"] as? String, let name = row["name"] as? String else { return nil }
            return SimulatorDevice(
                udid: udid, name: name,
                state: row["state"] as? String ?? "unknown",
                os: (row["os"] as? String).map(Self.osLabel) ?? "")
        }
        // Booted first, then by name: the device someone is about to use is
        // almost always one already running.
        devices = listed.sorted { ($0.isBooted ? 0 : 1, $0.name) < ($1.isBooted ? 0 : 1, $1.name) }
        return devices
    }

    func attach(_ udid: String) async throws -> SimulatorScreen {
        let result = try await callObject("attach", ["udid": udid])
        guard let stream = (result["stream"] as? NSNumber)?.uint32Value,
              let width = (result["pointWidth"] as? NSNumber)?.doubleValue,
              let height = (result["pointHeight"] as? NSNumber)?.doubleValue
        else { throw SimulatorHostError.malformedReply }
        return SimulatorScreen(
            udid: udid, name: result["name"] as? String ?? udid, stream: stream,
            pointSize: CGSize(width: width, height: height),
            rotation: result["rotation"] as? String ?? "rot0",
            deviceTypePath: result["deviceTypePath"] as? String)
    }

    private static let lastDeviceKey = "simulator.lastDevice"

    /// The device the pane last showed, across launches: the one opening the
    /// pane starts, booting it if it has been shut down since.
    var lastDevice: String? { UserDefaults.standard.string(forKey: Self.lastDeviceKey) }

    /// Devices whose boot has finished, by UDID — `bootstatus` answered for
    /// them in this run. A device that is drawing may still be booting; input
    /// and reads wait for this, the display does not.
    private var readyDevices: Set<String> = []

    /// Waits until `udid` has finished booting — a first boot's setup
    /// included — before an agent's input or read runs on it. A tenth of a
    /// second for a device that already has; asked once per device per run.
    func waitUntilReady(_ udid: String) async throws {
        guard !readyDevices.contains(udid) else { return }
        try await boot(udid, untilReady: true)
        readyDevices.insert(udid)
    }

    /// Makes `udid` the pane's device: boots it first when it is shut down, then
    /// attaches its display. Errors land in `lastError` for the pane to show.
    func show(_ udid: String) async {
        lastError = nil
        UserDefaults.standard.set(udid, forKey: Self.lastDeviceKey)
        do {
            if devices.first(where: { $0.udid == udid })?.isBooted == false {
                booting = udid
                defer { booting = nil }
                // Shown from the first frame, as Simulator.app shows a boot: the
                // Apple logo and a first boot's setup are the device working,
                // not a wait to hide behind a spinner.
                try await boot(udid, untilReady: false)
                readyDevices.remove(udid)
                screen = try await attachWhenDisplayed(udid)
                return
            }
            screen = try await attach(udid)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// The pane's device if there is one, else the first booted device, attached.
    /// What `termio sim` acts on when the caller names no device.
    func currentOrFirstBooted() async throws -> SimulatorScreen {
        if let screen { return screen }
        await refreshDevices()
        guard let booted = devices.first(where: \.isBooted) else {
            throw SimulatorHostError.failed(localized(
                "No simulator is booted. Boot one with `xcrun simctl boot <device>`, or pick one in the Simulator pane."))
        }
        let attached = try await attach(booted.udid)
        screen = attached
        return attached
    }

    // MARK: Consent

    private static let consentKey = "simulator.agentConsent"

    /// Devices the person has allowed agents to drive, by UDID. Asked once per
    /// device, as Claude's simulator asks: an agent at the controls of a phone
    /// sees everything on its screen, and a person should know which phone.
    func agentsMayUse(_ udid: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: Self.consentKey) ?? []).contains(udid)
    }

    func allowAgents(on udid: String) {
        var allowed = UserDefaults.standard.stringArray(forKey: Self.consentKey) ?? []
        guard !allowed.contains(udid) else { return }
        allowed.append(udid)
        UserDefaults.standard.set(allowed, forKey: Self.consentKey)
    }

    /// The question in flight per device, so a burst of commands asks once.
    private var consentQuestions: [String: Task<Bool, Never>] = [:]

    /// Asks the person, in a sheet on the main window, whether agents may drive
    /// `screen`'s device. Waits at most `patience`; the sheet stays up past that,
    /// and its answer still counts for the next command.
    func askConsent(for screen: SimulatorScreen, patience: Duration = .seconds(12)) async -> Bool? {
        if agentsMayUse(screen.udid) { return true }
        let question = consentQuestions[screen.udid] ?? Task { @MainActor [weak self] in
            let allowed = await Self.presentConsent(deviceName: screen.name)
            if allowed { self?.allowAgents(on: screen.udid) }
            self?.consentQuestions[screen.udid] = nil
            return allowed
        }
        consentQuestions[screen.udid] = question
        return await withTaskGroup(of: Bool?.self) { group in
            group.addTask { await question.value }
            group.addTask {
                do {
                    try await Task.sleep(for: patience)
                } catch {
                    return nil
                }
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func presentConsent(deviceName: String) async -> Bool {
        let alert = NSAlert()
        alert.messageText = localized("Allow agents to use \(deviceName)?")
        alert.informativeText = localized("""
            Agents in Termio will control this simulator and take screenshots of its \
            entire screen. Don’t sign in to real accounts on it.
            """)
        alert.addButton(withTitle: localized("Allow"))
        alert.addButton(withTitle: localized("Don’t Allow"))
        NSApp.activate(ignoringOtherApps: true)
        guard let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else {
            return alert.runModal() == .alertFirstButtonReturn
        }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }

    // MARK: Sessions

    /// Which device each agent session drives, by `TERMIO_SESSION`. Kept for the
    /// app's lifetime: an agent that comes back to its device finds it again.
    private var bindings: [String: String] = [:]
    /// The app `launch` last started on each device: what `logs` and
    /// `crash-report` read when the caller names none.
    private(set) var lastLaunched: [String: String] = [:]

    func bind(session: String, to udid: String) { bindings[session] = udid }
    func binding(for session: String) -> String? { bindings[session] }

    /// Devices other sessions drive, so a session with no device of its own is
    /// handed one nobody else is tapping on.
    func boundElsewhere(than session: String?) -> Set<String> {
        Set(bindings.filter { $0.key != session }.values)
    }

    /// Stops showing `udid` in the pane and stops its frame stream. The device
    /// keeps running.
    func detachPane(_ udid: String) {
        fire("detach", ["udid": udid])
        if screen?.udid == udid { screen = nil }
    }

    // MARK: Apps

    /// Installs `appPath` and launches it, replacing a running copy. The bundle
    /// id comes from the app's Info.plist when the caller names none.
    func launch(appPath: String, bundleID: String?, on udid: String) async throws -> (bundleID: String, pid: Int?) {
        let app = URL(fileURLWithPath: appPath)
        guard app.pathExtension == "app", FileManager.default.fileExists(atPath: app.path) else {
            throw SimulatorHostError.failed(localized("\(appPath) isn’t an .app bundle."))
        }
        let identifier = bundleID
            ?? (NSDictionary(contentsOf: app.appendingPathComponent("Info.plist"))?["CFBundleIdentifier"] as? String)
        guard let identifier, !identifier.isEmpty else {
            throw SimulatorHostError.failed(localized("Couldn’t read the bundle identifier from \(app.lastPathComponent)."))
        }
        try await simctl(["install", udid, app.path])
        let output = try await simctl(["launch", "--terminate-running-process", udid, identifier])
        lastLaunched[udid] = identifier
        // simctl answers "<bundle id>: <pid>".
        let pid = output.split(separator: ":").last.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return (identifier, pid)
    }

    /// Opens a URL or deep link the way tapping a link would. Schemes that read
    /// or run local content are refused, as Claude's open_url refuses them.
    func openURL(_ url: String, on udid: String) async throws {
        let scheme = url.split(separator: ":", maxSplits: 1).first.map { $0.lowercased() } ?? ""
        guard !["file", "javascript", "data", "vbscript", "blob"].contains(scheme) else {
            throw SimulatorHostError.failed(localized("open-url doesn’t open \(scheme): URLs."))
        }
        try await simctl(["openurl", udid, url])
    }

    /// Types `text` into the focused field. Plain US-layout text goes as key
    /// presses; anything else — Chinese, emoji, accents — goes through the
    /// simulator's pasteboard and ⌘V, the only way such text reaches a field.
    func type(_ text: String, on udid: String) async throws {
        if text.unicodeScalars.allSatisfy({ (0x20 ... 0x7E).contains($0.value) || $0 == "\n" }) {
            _ = try await call("text", ["udid": udid, "text": text])
            return
        }
        try await simctl(["pbcopy", udid], input: Data(text.utf8))
        _ = try await call("key", ["udid": udid, "name": "paste"])
    }

    /// Boots a shut-down device through `simctl`, the public tool, and waits
    /// until it reports booted. The helper attaches only to booted devices.
    ///
    /// `untilReady` waits out the whole boot, a first boot's setup included —
    /// a minute or more, which an agent needs before its taps can land. Without
    /// it this returns once the device is up and drawing, in seconds.
    func boot(_ udid: String, untilReady: Bool = true) async throws {
        let arguments = untilReady ? ["simctl", "bootstatus", udid, "-b"] : ["simctl", "boot", udid]
        let status = try await Self.run("/usr/bin/xcrun", arguments)
        // `simctl boot` on a device that is already booting exits 149; that is
        // the state asked for.
        guard status == 0 || (!untilReady && status == 149) else {
            throw SimulatorHostError.failed(localized("The simulator didn’t finish booting."))
        }
        await refreshDevices()
    }

    /// Attaches a device that has only just booted: its display appears a
    /// moment after `simctl boot` returns, so attaching is retried until it does.
    private func attachWhenDisplayed(_ udid: String) async throws -> SimulatorScreen {
        var lastError: Error?
        for _ in 0 ..< 40 {
            do {
                return try await attach(udid)
            } catch {
                lastError = error
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        throw lastError ?? SimulatorHostError.helperExited
    }

    // MARK: Surfaces

    /// Registers `present` to receive stream `stream`'s surface: called at once
    /// with the current one, again on every frame, and with nil if the helper
    /// goes away. The registration lives as long as `owner`.
    func present(stream: UInt32, for owner: AnyObject, _ present: @escaping (IOSurface?) -> Void) {
        presenters[stream, default: [:]][ObjectIdentifier(owner)] = present
        present(surfaces[stream])
    }

    func stopPresenting(for owner: AnyObject) {
        for stream in presenters.keys {
            presenters[stream]?[ObjectIdentifier(owner)] = nil
        }
    }

    private func receive(_ surface: IOSurface, stream: UInt32) {
        surfaces[stream] = surface
        presenters[stream]?.values.forEach { $0(surface) }
    }

    private func frame(stream: UInt32) {
        guard let presenters = presenters[stream], !presenters.isEmpty else { return }
        let surface = surfaces[stream]
        presenters.values.forEach { $0(surface) }
    }

    // MARK: Process

    private func startIfNeeded() throws {
        if process?.isRunning == true { return }
        guard let helper = Self.helperURL() else {
            throw SimulatorHostError.unavailable(
                localized("This build of Termio doesn’t include the simulator helper."))
        }
        guard let serviceName = receiver.serviceName else {
            throw SimulatorHostError.failed(localized("Termio couldn’t open a channel for the simulator’s screen."))
        }
        let process = Process()
        process.executableURL = helper
        process.arguments = [
            "--service", serviceName,
            "--resources", helper.deletingLastPathComponent().appendingPathComponent("Simulator").path,
        ]
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.consume(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Log.simulator.info("helper: \(text, privacy: .public)")
        }
        process.terminationHandler = { [weak self] exited in
            let status = exited.terminationStatus
            Task { @MainActor in self?.helperExited(status: status) }
        }
        try process.run()
        self.process = process
        self.input = stdin.fileHandleForWriting
        Log.simulator.info("started termio-sim pid \(process.processIdentifier, privacy: .public)")
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        lineBuffer.append(data)
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            let line = lineBuffer[lineBuffer.startIndex..<newline]
            lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
            handle(line: Data(line))
        }
    }

    private func handle(line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            Log.simulator.error("unreadable helper line (\(line.count, privacy: .public) bytes)")
            return
        }
        if let event = object["event"] as? String {
            switch event {
            case "frame":
                if let stream = (object["stream"] as? NSNumber)?.uint32Value { frame(stream: stream) }
            case "unavailable":
                unavailableReason = object["error"] as? String
                    ?? localized("The iOS Simulator isn’t available on this Mac.")
            case "rotated":
                guard let stream = (object["stream"] as? NSNumber)?.uint32Value,
                      var turned = screen, turned.stream == stream,
                      let rotation = object["rotation"] as? String,
                      let width = (object["pointWidth"] as? NSNumber)?.doubleValue,
                      let height = (object["pointHeight"] as? NSNumber)?.doubleValue
                else { break }
                turned.rotation = rotation
                turned.pointSize = CGSize(width: width, height: height)
                screen = turned
            case "detached":
                Log.simulator.info("display detached: \(String(describing: object["error"]), privacy: .public)")
            default:
                break
            }
            return
        }
        guard let id = object["id"] as? Int, let reply = pending.removeValue(forKey: id) else { return }
        if object["ok"] as? Bool == true {
            let result = object["result"] ?? [String: Any]()
            reply(.success((try? JSONSerialization.data(withJSONObject: result)) ?? Data("{}".utf8)))
        } else {
            reply(.failure(SimulatorHostError.failed(
                object["error"] as? String ?? localized("The simulator helper reported an error."))))
        }
    }

    private func helperExited(status: Int32) {
        Log.simulator.info("termio-sim exited with status \(status, privacy: .public)")
        process = nil
        input = nil
        lineBuffer.removeAll()
        let waiting = pending
        pending.removeAll()
        waiting.values.forEach { $0(.failure(SimulatorHostError.helperExited)) }
        // Surfaces die with the process that sent them; the views go blank
        // until they attach again through a fresh helper.
        surfaces.removeAll()
        for stream in presenters.keys { presenters[stream]?.values.forEach { $0(nil) } }
        presenters.removeAll()
        // Reattach on our own: the person was looking at that device. Spaced out
        // so a helper that dies on launch does not become a respawn loop.
        guard let udid = screen?.udid else { return }
        screen = nil
        let now = Date()
        guard now.timeIntervalSince(lastReattach) > 10 else {
            lastError = localized("The simulator helper keeps quitting. Pick the device again to retry.")
            return
        }
        lastReattach = now
        Task { await show(udid) }
    }

    // MARK: Environment

    /// Where the helper lives: beside the daemon in the bundle's Resources, or
    /// `TERMIO_SIM_HELPER` for a bare `swift run`.
    private static func helperURL() -> URL? {
        if let explicit = ProcessInfo.processInfo.environment["TERMIO_SIM_HELPER"], !explicit.isEmpty {
            return URL(fileURLWithPath: explicit)
        }
        guard let bundled = Bundle.main.url(forResource: "termio-sim", withExtension: nil),
              FileManager.default.isExecutableFile(atPath: bundled.path)
        else { return nil }
        return bundled
    }

    /// idb builds for Apple silicon and macOS 15 only, so the helper exists for
    /// nothing older; saying so beats a helper that dies on launch.
    private static func platformRefusal() -> String? {
        #if arch(arm64)
        if ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)) {
            return nil
        }
        return localized("The Simulator pane needs macOS 15 or later.")
        #else
        return localized("The Simulator pane needs a Mac with Apple silicon.")
        #endif
    }

    /// "OS 'iOS 18.3'" → "iOS 18.3".
    private static func osLabel(_ raw: String) -> String {
        raw.replacingOccurrences(of: "OS '", with: "").replacingOccurrences(of: "'", with: "")
    }

    private static func run(_ executable: String, _ arguments: [String]) async throws -> Int32 {
        try await simctlProcess(executable, arguments, input: nil).status
    }

    /// `xcrun simctl <arguments>`, failing with simctl's own words when it exits
    /// non-zero. The public tool, for everything it covers: installing,
    /// launching, URLs, the pasteboard, appearance, the status bar.
    @discardableResult
    func simctl(_ arguments: [String], input: Data? = nil) async throws -> String {
        let result = try await Self.simctlProcess("/usr/bin/xcrun", ["simctl"] + arguments, input: input)
        guard result.status == 0 else {
            let reason = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SimulatorHostError.failed(reason.isEmpty ? "simctl \(arguments.first ?? "") failed" : reason)
        }
        return result.output
    }

    private static func simctlProcess(
        _ executable: String, _ arguments: [String], input: Data?
    ) async throws -> (status: Int32, output: String, error: String) {
        try await withCheckedThrowingContinuation { continuation in
            // Off the main actor and read while it runs: output past a pipe's
            // 64 KB buffer would otherwise stall simctl before it could exit.
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let output = Pipe()
                let error = Pipe()
                process.standardOutput = output
                process.standardError = error
                let stdin = input.map { _ in Pipe() }
                if let stdin { process.standardInput = stdin }
                do {
                    try process.run()
                    if let stdin, let input {
                        try stdin.fileHandleForWriting.write(contentsOf: input)
                        try stdin.fileHandleForWriting.close()
                    }
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let errorData = ReadBuffer()
                let errorRead = DispatchGroup()
                errorRead.enter()
                DispatchQueue.global().async {
                    errorData.data = error.fileHandleForReading.readDataToEndOfFile()
                    errorRead.leave()
                }
                let outputData = output.fileHandleForReading.readDataToEndOfFile()
                errorRead.wait()
                process.waitUntilExit()
                continuation.resume(returning: (
                    process.terminationStatus,
                    String(data: outputData, encoding: .utf8) ?? "",
                    String(data: errorData.data, encoding: .utf8) ?? ""))
            }
        }
    }
}

/// One pipe's bytes, filled on the thread that drains it and read once that
/// thread has signalled the group it leaves.
private final class ReadBuffer: @unchecked Sendable {
    var data = Data()
}

/// The receive end of the helper's surface channel: a Mach port checked in with
/// launchd under a name unique to this process, and a thread blocked on it. Each
/// message carries one IOSurface send right plus the stream it belongs to — the
/// layout of `SurfaceMessage` in simulator-helper/Sources/SurfacePort.swift.
final class SimulatorSurfaceReceiver: @unchecked Sendable {
    let serviceName: String?
    /// Called on the receive thread.
    var onSurface: (@Sendable (UInt32, IOSurface) -> Void)?

    private struct Message {
        var header = mach_msg_header_t()
        var body = mach_msg_body_t()
        var surface = mach_msg_port_descriptor_t()
        var stream: UInt32 = 0
        var trailer = mach_msg_trailer_t()
    }

    init() {
        let name = "\(Bundle.main.bundleIdentifier ?? "sh.termio.app").simulator.\(getpid())"
        var bootstrap = mach_port_t(MACH_PORT_NULL)
        var port = mach_port_t(MACH_PORT_NULL)
        // 4 is TASK_BOOTSTRAP_PORT, a macro Swift does not import.
        guard task_get_special_port(mach_task_self_, 4, &bootstrap) == KERN_SUCCESS,
              bootstrapCheckIn(bootstrap, name, &port) == KERN_SUCCESS
        else {
            Log.simulator.error("bootstrap_check_in(\(name, privacy: .public)) failed")
            serviceName = nil
            return
        }
        serviceName = name
        let receivePort = port
        let thread = Thread { [weak self] in self?.receive(on: receivePort) }
        thread.name = "termio.simulator-surfaces"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func receive(on port: mach_port_t) {
        while true {
            var message = Message()
            let result = withUnsafeMutablePointer(to: &message) { pointer in
                pointer.withMemoryRebound(to: mach_msg_header_t.self, capacity: 1) {
                    mach_msg($0, MACH_RCV_MSG, 0, mach_msg_size_t(MemoryLayout<Message>.size),
                             port, MACH_MSG_TIMEOUT_NONE, mach_port_t(MACH_PORT_NULL))
                }
            }
            guard result == MACH_MSG_SUCCESS else {
                Log.simulator.error("surface receive failed: \(result, privacy: .public)")
                continue
            }
            let right = message.surface.name
            defer { mach_port_deallocate(mach_task_self_, right) }
            guard message.header.msgh_bits & MACH_MSGH_BITS_COMPLEX != 0,
                  let surface = IOSurfaceLookupFromMachPort(right)
            else { continue }
            // IOSurfaceRef and IOSurface are one toll-free-bridged object; Swift
            // only lacks the implicit conversion.
            onSurface?(message.stream, unsafeBitCast(surface, to: IOSurface.self))
        }
    }
}

// `servers/bootstrap.h` is not part of the Darwin module Swift imports.
@_silgen_name("bootstrap_check_in")
private func bootstrapCheckIn(
    _ bootstrap: mach_port_t, _ name: UnsafePointer<CChar>, _ port: UnsafeMutablePointer<mach_port_t>
) -> kern_return_t
