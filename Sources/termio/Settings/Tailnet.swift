import Foundation

/// One machine on the user's tailnet, as the local Tailscale client reports it.
struct TailnetPeer: Identifiable, Hashable {
    let id: String
    /// The machine's own name, which is also what its MagicDNS name starts with.
    let hostName: String
    /// What to put in `HostName`: the MagicDNS name when this Mac can resolve it,
    /// else the first Tailscale address, which works with or without DNS.
    let address: String
    /// Every name and address that reaches this machine from here, in
    /// `Tailnet.canonical` form, so a config block written with any one of them
    /// is recognised as this machine.
    let identities: Set<String>
    let os: String
    let isOnline: Bool
    /// Signed in as the same Tailscale user as this Mac. Only these lead the list:
    /// another member's machine is one this user rarely has an account on.
    let isOwn: Bool
}

/// Reads the tailnet from the Tailscale client already on this Mac.
///
/// Read-only, through the client's own CLI: termio never joins a tailnet or holds
/// a Tailscale credential, the same way it never embeds SSH. A Mac without
/// Tailscale, or with it signed out, has no tailnet and the callers show nothing.
enum Tailnet {
    /// Where the CLI lives across Tailscale's macOS builds. Looked up by path
    /// because an app launched from Finder has no shell `PATH` to find it on.
    static let cliCandidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
    ]

    /// Only systems termiod runs on: any other peer is a phone or a Windows box,
    /// which nothing here can open a session on.
    static let hostOperatingSystems: Set<String> = ["macOS", "linux"]

    /// A local status read answers in milliseconds. One that has not answered in
    /// this long is a client in a state nobody can list from, and the sheet must
    /// not wait on it.
    static let statusTimeout: TimeInterval = 5

    static func cliPath() -> String? {
        cliCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The tailnet's machines that can host sessions, this Mac excluded. Empty when
    /// there is no Tailscale, it is not running, or it did not answer in time.
    static func hostPeers() async -> [TailnetPeer] {
        await hostPeers(cli: cliPath())
    }

    static func hostPeers(cli: String?) async -> [TailnetPeer] {
        guard let (status, namesResolve) = await read(cli: cli) else { return [] }
        return hostPeers(in: status, namesResolve: namesResolve)
    }

    /// Where another device on the tailnet reaches this Mac: its Tailscale IP, IPv4
    /// first. Never the MagicDNS name, because the phone dials it over plain `ws://`
    /// and App Transport Security lets that through to an IP address but not to a
    /// `.ts.net` name. nil when this Mac is not on a running tailnet.
    static func ownAddress() async -> String? {
        await ownAddress(cli: cliPath())
    }

    static func ownAddress(cli: String?) async -> String? {
        guard let cli, let output = await StatusRead.run(cli: cli) else { return nil }
        return ownAddress(fromStatus: output)
    }

    static func ownAddress(fromStatus data: Data) -> String? {
        guard let status = decode(data), status.backendState == "Running",
              let node = status.selfNode else { return nil }
        return address(of: node, namesResolve: false)
    }

    private static func read(cli: String?) async -> (Status, Bool)? {
        guard let cli, let output = await StatusRead.run(cli: cli),
              let status = decode(output) else { return nil }
        // The tailnet reporting a MagicDNS name is not this Mac resolving it: with
        // `--accept-dns=false` every name is there and none of them works. This
        // Mac's own name stands for all of them, since one resolver serves them all.
        let ownName = status.selfNode?.dnsName.map(trimmingRoot) ?? ""
        return (status, await resolves(ownName, within: resolveTimeout))
    }

    /// The MagicDNS name where names resolve, else the first Tailscale address.
    /// IPv4 first: it is the one every resolver-less path accepts as typed.
    private static func address(of node: Node, namesResolve: Bool) -> String? {
        let dnsName = node.dnsName.map(trimmingRoot) ?? ""
        if namesResolve, !dnsName.isEmpty { return dnsName }
        let ips = node.tailscaleIPs ?? []
        let ip = ips.first { !$0.contains(":") } ?? ips.first
        return ip.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// MagicDNS answers from this Mac itself, in well under this. A name that takes
    /// longer is going to a resolver that is not MagicDNS, and the IPs are the
    /// answer that works.
    static let resolveTimeout: TimeInterval = 1

    static func hostPeers(fromStatus data: Data, namesResolve: Bool) -> [TailnetPeer] {
        decode(data).map { hostPeers(in: $0, namesResolve: namesResolve) } ?? []
    }

    /// The status reduced to the peers that can host sessions: this user's online
    /// machines first, then this user's offline ones, then everyone else's, each
    /// group by name.
    private static func hostPeers(in status: Status, namesResolve: Bool) -> [TailnetPeer] {
        // A stopped or signed-out client still prints its last network map.
        guard status.backendState == "Running" else { return [] }
        let ownUser = status.selfNode?.userID
        let peers = (status.peer ?? [:]).values.compactMap { node -> TailnetPeer? in
            guard let os = node.os, hostOperatingSystems.contains(os) else { return nil }
            guard let address = address(of: node, namesResolve: namesResolve) else { return nil }
            let dnsName = node.dnsName.map(trimmingRoot) ?? ""
            let ips = node.tailscaleIPs ?? []
            // Names count only where they resolve here. The short name is one too:
            // MagicDNS's search domain resolves it, which is how a block with no
            // `HostName` of its own reaches the machine. It is the DNS name's first
            // label, not `HostName`, which two machines can share (the second is
            // `mini-1`), and only inside this tailnet's suffix, the one searched.
            let names = namesResolve ? [dnsName, shortName(of: dnsName, in: status.magicDNSSuffix)] : []
            let identities = Set((names + ips).filter { !$0.isEmpty }.map(canonical))
            return TailnetPeer(
                id: node.id ?? address,
                hostName: node.hostName ?? address,
                address: address,
                identities: identities,
                os: os,
                isOnline: node.online ?? false,
                isOwn: ownUser != nil && node.userID == ownUser)
        }
        return peers.sorted { left, right in
            if left.isOwn != right.isOwn { return left.isOwn }
            if left.isOnline != right.isOnline { return left.isOnline }
            return left.hostName.localizedStandardCompare(right.hostName) == .orderedAscending
        }
    }

    /// The peers no config `HostName` already reaches, by name or by address.
    static func peers(_ peers: [TailnetPeer], notReachedBy hostNames: [String]) -> [TailnetPeer] {
        let configured = Set(hostNames.map(canonical))
        return peers.filter { $0.identities.isDisjoint(with: configured) }
    }

    private static func shortName(of dnsName: String, in suffix: String?) -> String {
        guard let suffix = suffix.map(trimmingRoot), !suffix.isEmpty,
              dnsName.lowercased().hasSuffix("." + suffix.lowercased()) else { return "" }
        return String(dnsName.dropLast(suffix.count + 1))
    }

    /// `mini.tail1.ts.net.` resolves as written, but the dot would also land in
    /// the alias derived from it and in every row that shows it.
    static func trimmingRoot(_ name: String) -> String {
        name.hasSuffix(".") ? String(name.dropLast()) : name
    }

    /// One spelling per host: lowercased, without the root dot or IPv6 brackets,
    /// and an IPv6 address in its shortest form, since `fd7a:0:0::7` and
    /// `fd7a::7` are one machine however a config happens to write it.
    static func canonical(_ host: String) -> String {
        var value = trimmingRoot(host).lowercased()
        if value.hasPrefix("["), value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        }
        var address = in6_addr()
        guard inet_pton(AF_INET6, value, &address) == 1 else { return value }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { return value }
        return String(cString: buffer)
    }

    private static func decode(_ data: Data) -> Status? {
        do {
            return try JSONDecoder().decode(Status.self, from: data)
        } catch {
            Log.app.error("tailscale status was not readable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Whether `name` resolves, answered by `timeout` at the latest. `getaddrinfo`
    /// cannot be cancelled, so a lookup that outlasts the answer finishes on its own
    /// thread when the system resolver gives up, which bounds it.
    private static func resolves(_ name: String, within timeout: TimeInterval) async -> Bool {
        guard !name.isEmpty else { return false }
        return await withCheckedContinuation { continuation in
            let answer = Once(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                answer.resume(false)
            }
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_socktype = SOCK_STREAM
                var result: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(name, nil, &hints, &result)
                if let result { freeaddrinfo(result) }
                answer.resume(status == 0)
            }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        func resume(_ value: Bool) {
            let pending = lock.withLock {
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(returning: value)
        }
    }

    /// One `tailscale status --json`, read by handlers rather than by a thread
    /// parked on the pipe. A descendant that inherits the pipe can hold it open
    /// after the CLI exits, and a blocked read would then outlive the deadline:
    /// with handlers the deadline drops them and nothing is left waiting.
    private final class StatusRead: @unchecked Sendable {
        private let lock = NSLock()
        private let process = Process()
        private let out = Pipe()
        private let err = Pipe()
        private var stdout = Data()
        private var stderr = Data()
        private var openStreams = 2
        private var exited = false
        private var continuation: CheckedContinuation<Data?, Never>?

        static func run(cli: String) async -> Data? {
            let read = StatusRead(cli: cli)
            return await withCheckedContinuation { read.start($0) }
        }

        private init(cli: String) {
            process.executableURL = URL(fileURLWithPath: cli)
            process.arguments = ["status", "--json"]
            // The app-bundle binary is the GUI and the CLI in one, and acts as the
            // CLI only when it sees `TERM` or this. An app opened from Finder has
            // no `TERM`, so without it the call starts a second Tailscale GUI.
            var environment = ProcessInfo.processInfo.environment
            environment["TAILSCALE_BE_CLI"] = "1"
            process.environment = environment
            process.standardOutput = out
            process.standardError = err
        }

        private func start(_ continuation: CheckedContinuation<Data?, Never>) {
            lock.withLock { self.continuation = continuation }
            out.fileHandleForReading.readabilityHandler = { [self] handle in
                collect(handle.availableData, from: handle, isError: false)
            }
            err.fileHandleForReading.readabilityHandler = { [self] handle in
                collect(handle.availableData, from: handle, isError: true)
            }
            process.terminationHandler = { [self] _ in
                lock.withLock { exited = true }
                finishIfComplete()
            }
            do {
                try process.run()
            } catch {
                Log.app.error("tailscale status failed to start: \(error.localizedDescription, privacy: .public)")
                finish(with: nil)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + Tailnet.statusTimeout) { [self] in
                guard finish(with: nil) else { return }
                Log.app.error("tailscale status did not answer in \(Tailnet.statusTimeout, privacy: .public)s")
                if process.isRunning { process.terminate() }
            }
        }

        private func collect(_ data: Data, from handle: FileHandle, isError: Bool) {
            lock.withLock {
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    openStreams -= 1
                } else if isError {
                    stderr.append(data)
                } else {
                    stdout.append(data)
                }
            }
            finishIfComplete()
        }

        private func finishIfComplete() {
            let output: Data?? = lock.withLock {
                guard openStreams == 0, exited else { return .none }
                guard process.terminationStatus == 0 else {
                    let message = String(data: stderr, encoding: .utf8) ?? ""
                    Log.app.info("tailscale status exited \(self.process.terminationStatus, privacy: .public): \(message, privacy: .public)")
                    return .some(nil)
                }
                return .some(stdout)
            }
            if let output { finish(with: output) }
        }

        /// Answers once; whether this call was the one that did. The handlers go
        /// with the answer, which also releases the cycle they hold on `self`.
        @discardableResult
        private func finish(with output: Data?) -> Bool {
            let pending = lock.withLock {
                defer { continuation = nil }
                return continuation
            }
            guard let pending else { return false }
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            pending.resume(returning: output)
            return true
        }
    }

    private struct Status: Decodable {
        let backendState: String?
        let magicDNSSuffix: String?
        let selfNode: Node?
        let peer: [String: Node]?

        enum CodingKeys: String, CodingKey {
            case backendState = "BackendState"
            case magicDNSSuffix = "MagicDNSSuffix"
            case selfNode = "Self"
            case peer = "Peer"
        }
    }

    private struct Node: Decodable {
        let id: String?
        let hostName: String?
        let dnsName: String?
        let os: String?
        let online: Bool?
        let tailscaleIPs: [String]?
        let userID: Int64?

        enum CodingKeys: String, CodingKey {
            case id = "ID"
            case hostName = "HostName"
            case dnsName = "DNSName"
            case os = "OS"
            case online = "Online"
            case tailscaleIPs = "TailscaleIPs"
            case userID = "UserID"
        }
    }
}

/// This Mac's session host on the tailnet as a device of its own, the way a
/// Linux box joins with `termiod tailscale on`. The daemon owns it: it runs
/// `termio-tailnet` beside itself and keeps it up across restarts, so this only
/// asks it, through the same `termiod tailscale` a terminal would use.
@MainActor
final class BuiltInTailscale: ObservableObject {
    static let shared = BuiltInTailscale()

    /// What `termiod tailscale status --json` last said. nil before the first
    /// answer.
    @Published private(set) var report: Report?
    /// A command is running; the switch waits for it.
    @Published private(set) var busy = false
    /// Why the last command failed, in termiod's own words.
    @Published private(set) var failure: String?

    struct Report: Decodable, Equatable {
        let enabled: Bool
        let hostname: String
        let status: Status?
        let url: String?
        let helper: String?
    }

    /// The settings a report was produced under, so a report about the
    /// previous config does not pass for one about the current.
    struct Applied: Decodable, Equatable {
        let enabled: Bool
        let hostname: String?
    }

    struct Status: Decodable, Equatable {
        let state: String
        let applied: Applied?
        let authURL: String?
        let dnsName: String?
        let ips: [String]?
        let https: Bool?
        let owner: String?
        let tagged: Bool?
        let message: String?

        enum CodingKeys: String, CodingKey {
            case state, applied, ips, https, owner, tagged, message
            case authURL = "auth_url"
            case dnsName = "dns_name"
        }
    }

    var enabled: Bool { report?.enabled ?? false }
    var state: String? { report?.status?.state }
    /// The report was read since the pane last opened. One read before that
    /// may name a node that has since signed out or changed accounts.
    @Published private(set) var fresh = false
    /// Where a phone reaches this Mac's session host on the tailnet: only a
    /// node that is connected, read just now, and owned by someone, because a
    /// tagged node admits nobody.
    var url: String? {
        guard fresh, let report, state == "running", report.status?.tagged != true,
              let applied = report.status?.applied, applied.enabled,
              (applied.hostname ?? "termio") == report.hostname
        else { return nil }
        return report.url
    }
    /// The build carries the helper. A dev build without Go does not.
    var available: Bool { report?.helper != nil }

    private var polling: Task<Void, Never>?
    /// The section and the QR sheet each watch; polling runs while either is
    /// on screen.
    private var watchers = 0
    /// Reads finish out of order, so only the newest one started may publish.
    private var started = 0
    /// Counts reads that landed, changed or not, for whoever acts on each.
    @Published private(set) var reads = 0

    /// Reads the state now. What was read before stops counting until then.
    func refresh() {
        fresh = false
        Task { await read() }
    }

    /// Keeps reading while the node is on its way somewhere: signing in,
    /// waiting for approval, starting.
    func startWatching() {
        watchers += 1
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.read()
                try? await Task.sleep(for: .seconds(self.settled ? 10 : 1.5))
            }
        }
    }

    func stopWatching() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        polling?.cancel()
        polling = nil
    }

    private var settled: Bool {
        guard let report else { return false }
        return !report.enabled || report.status?.state == "running"
    }

    /// The last on or off asked for and not yet read back, so a decision taken
    /// mid-command acts on where the node is going rather than where it was.
    private var requested: Bool?

    /// On, or on its way there.
    var headedOn: Bool { requested ?? enabled }

    /// `naming`: give a node that still has the default name this Mac's own.
    /// A resume passes false, because the rename moves the address a phone
    /// paired to the node has saved.
    func setEnabled(_ on: Bool, naming: Bool = true) {
        requested = on
        var arguments = on ? ["tailscale", "on", "--no-wait"] : ["tailscale", "off"]
        // Named only while the node still has the default name. Renaming one
        // that has its own would move the address a paired phone has saved.
        if on, naming, report?.hostname == nil || report?.hostname == "termio" {
            arguments += ["--hostname", Self.deviceName]
        }
        perform(arguments)
    }

    func signOut() {
        perform(["tailscale", "logout"])
    }

    /// A command asked for while one runs, such as Allow Paired Devices going
    /// off mid-sign-in. It runs next; dropping it left the node on.
    private var pending: [String]?

    private func perform(_ arguments: [String]) {
        guard !busy else {
            pending = arguments
            return
        }
        busy = true
        failure = nil
        Task {
            do {
                let result = try await RemotePairing.runLocally(arguments: arguments)
                if result.status != 0 {
                    failure = RemotePairing.message(from: result)
                }
            } catch let error as RemotePairing.Failure {
                failure = error.message
            } catch {
                failure = error.localizedDescription
            }
            await read()
            busy = false
            if pending == nil { requested = nil }
            if let next = pending {
                pending = nil
                perform(next)
            }
        }
    }

    private func read() async {
        started &+= 1
        let mine = started
        guard let result = try? await RemotePairing.runLocally(arguments: ["tailscale", "status", "--json"]),
              mine == started,
              result.status == 0,
              let data = result.stdout.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Report.self, from: data)
        else { return }
        if decoded != report { report = decoded }
        fresh = true
        reads &+= 1
    }

    /// `termio-` and this Mac's name as a DNS label, so two Macs on one tailnet
    /// do not both come up as `termio`, and the admin console says which is
    /// which.
    static var deviceName: String {
        let raw = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        return deviceName(from: raw)
    }

    nonisolated static func deviceName(from computerName: String) -> String {
        var label = ""
        var lastWasHyphen = false
        for scalar in computerName.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                label.unicodeScalars.append(scalar)
                lastWasHyphen = false
            } else if !lastWasHyphen, !label.isEmpty {
                label.append("-")
                lastWasHyphen = true
            }
        }
        while label.hasSuffix("-") { label.removeLast() }
        guard !label.isEmpty else { return "termio" }
        let name = "termio-" + label
        guard name.count > 63 else { return name }
        var trimmed = String(name.prefix(63))
        while trimmed.hasSuffix("-") { trimmed.removeLast() }
        return trimmed
    }
}
