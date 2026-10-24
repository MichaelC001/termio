import Foundation

/// One machine on the user's tailnet, as the local Tailscale client reports it.
struct TailnetPeer: Identifiable, Hashable {
    let id: String
    /// The machine's own name, which is also what its MagicDNS name starts with.
    let hostName: String
    /// What to put in `HostName`: the MagicDNS name when this Mac can resolve it,
    /// else the first Tailscale address, which works with or without DNS.
    let address: String
    /// Every name and address that reaches this machine, lowercased, so a config
    /// block written with any one of them is recognised as this machine.
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
        guard let cli = cliPath() else { return [] }
        return await withCheckedContinuation { continuation in
            let run = StatusRun(continuation)
            // The deadline answers for the read rather than waiting on it: a
            // descendant that inherited the pipe keeps the read open after the CLI
            // itself exits, so terminating the CLI alone bounds nothing. A worker
            // left blocked that way ends when the descendant does.
            DispatchQueue.global().asyncAfter(deadline: .now() + statusTimeout) {
                if run.finish(with: []) {
                    Log.app.error("tailscale status did not answer in \(statusTimeout, privacy: .public)s")
                    run.terminate()
                }
            }
            DispatchQueue.global(qos: .userInitiated).async {
                run.finish(with: readStatus(cli: cli, run: run))
            }
        }
    }

    private static func readStatus(cli: String, run: StatusRun) -> [TailnetPeer] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["status", "--json"]
        // The app-bundle binary is the GUI and the CLI in one, and acts as the CLI
        // only when it sees `TERM` or this. An app opened from Finder has no
        // `TERM`, so without it the call starts a second Tailscale GUI.
        var environment = ProcessInfo.processInfo.environment
        environment["TAILSCALE_BE_CLI"] = "1"
        process.environment = environment
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            Log.app.error("tailscale status failed to start: \(error.localizedDescription, privacy: .public)")
            return []
        }
        run.track(process)
        // Both pipes drain before the wait: a child that fills either one blocks
        // forever against a parent waiting on exit.
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr, encoding: .utf8) ?? ""
            Log.app.info("tailscale status exited \(process.terminationStatus, privacy: .public): \(message, privacy: .public)")
            return []
        }
        guard let status = decode(stdout) else { return [] }
        // The tailnet reporting a MagicDNS name is not this Mac resolving it: with
        // `--accept-dns=false` every name is there and none of them works. This
        // Mac's own name stands for all of them, since one resolver serves them all.
        let namesResolve = status.selfNode?.dnsName.map { resolves(trimmingRoot($0)) } ?? false
        return hostPeers(in: status, namesResolve: namesResolve)
    }

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
            let dnsName = node.dnsName.map(trimmingRoot) ?? ""
            let ips = node.tailscaleIPs ?? []
            // IPv4 first: it is the one every resolver-less path accepts as typed.
            let ip = ips.first { !$0.contains(":") } ?? ips.first
            guard let address = namesResolve && !dnsName.isEmpty ? dnsName : ip,
                  !address.isEmpty else { return nil }
            // The bare machine name too: MagicDNS's search domain resolves it, which
            // is how a block with no `HostName` of its own reaches the machine.
            let names = [dnsName, node.hostName ?? ""] + ips
            let identities = Set(names.filter { !$0.isEmpty }.map { $0.lowercased() })
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
        let configured = Set(hostNames.map { trimmingRoot($0).lowercased() })
        return peers.filter { $0.identities.isDisjoint(with: configured) }
    }

    /// `mini.tail1.ts.net.` resolves as written, but the dot would also land in
    /// the alias derived from it and in every row that shows it.
    static func trimmingRoot(_ name: String) -> String {
        name.hasSuffix(".") ? String(name.dropLast()) : name
    }

    private static func decode(_ data: Data) -> Status? {
        do {
            return try JSONDecoder().decode(Status.self, from: data)
        } catch {
            Log.app.error("tailscale status was not readable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func resolves(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(name, nil, &hints, &result)
        if let result { freeaddrinfo(result) }
        return status == 0
    }

    /// One status read's two finishers — the worker and the deadline — of which
    /// only the first is heard.
    private final class StatusRun: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<[TailnetPeer], Never>?
        private var process: Process?

        init(_ continuation: CheckedContinuation<[TailnetPeer], Never>) {
            self.continuation = continuation
        }

        func track(_ process: Process) {
            lock.withLock { self.process = process }
        }

        /// Whether this call was the one that answered.
        @discardableResult
        func finish(with peers: [TailnetPeer]) -> Bool {
            let pending = lock.withLock {
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(returning: peers)
            return pending != nil
        }

        func terminate() {
            let process = lock.withLock { self.process }
            if let process, process.isRunning { process.terminate() }
        }
    }

    private struct Status: Decodable {
        let backendState: String?
        let selfNode: Node?
        let peer: [String: Node]?

        enum CodingKeys: String, CodingKey {
            case backendState = "BackendState"
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
