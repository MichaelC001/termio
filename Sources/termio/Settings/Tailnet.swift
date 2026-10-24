import Foundation

/// One machine on the user's tailnet, as the local Tailscale client reports it.
struct TailnetPeer: Identifiable, Hashable {
    let id: String
    /// The machine's own name, which is also what its MagicDNS name starts with.
    let hostName: String
    /// What to put in `HostName`: the MagicDNS name when the tailnet has MagicDNS,
    /// else the first Tailscale address, which works with or without it.
    let address: String
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

    static let statusTimeout: TimeInterval = 5

    static func cliPath() -> String? {
        cliCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The tailnet's machines that can host sessions, this Mac excluded. Empty when
    /// there is no Tailscale, it is not running, or it answered with nothing usable.
    static func hostPeers() async -> [TailnetPeer] {
        guard let cli = cliPath() else { return [] }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: cli)
                process.arguments = ["status", "--json"]
                // The app-bundle binary is the GUI and the CLI in one, and acts as
                // the CLI only when it sees `TERM` or this. An app opened from
                // Finder has no `TERM`, so without it the call starts a second
                // Tailscale GUI and never returns.
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
                    continuation.resume(returning: [])
                    return
                }
                // A local status read answers in milliseconds; one that has not
                // answered in seconds is a client in a state nobody can list from,
                // and the sheet must not wait on it.
                DispatchQueue.global().asyncAfter(deadline: .now() + statusTimeout) {
                    if process.isRunning {
                        Log.app.error("tailscale status did not answer in \(statusTimeout, privacy: .public)s")
                        process.terminate()
                    }
                }
                // Both pipes drain before the wait: a child that fills either one
                // blocks forever against a parent waiting on exit.
                let stdout = out.fileHandleForReading.readDataToEndOfFile()
                let stderr = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    let message = String(data: stderr, encoding: .utf8) ?? ""
                    Log.app.info("tailscale status exited \(process.terminationStatus, privacy: .public): \(message, privacy: .public)")
                    continuation.resume(returning: [])
                    return
                }
                continuation.resume(returning: hostPeers(fromStatus: stdout))
            }
        }
    }

    /// `tailscale status --json`, reduced to the peers that can host sessions:
    /// this user's online machines first, then this user's offline ones, then
    /// everyone else's, each group by name.
    static func hostPeers(fromStatus data: Data) -> [TailnetPeer] {
        let status: Status
        do {
            status = try JSONDecoder().decode(Status.self, from: data)
        } catch {
            Log.app.error("tailscale status was not readable: \(error.localizedDescription, privacy: .public)")
            return []
        }
        // A stopped or signed-out client still prints its last network map.
        guard status.backendState == "Running" else { return [] }
        let ownUser = status.selfNode?.userID
        let peers = (status.peer ?? [:]).values.compactMap { node -> TailnetPeer? in
            guard let os = node.os, hostOperatingSystems.contains(os) else { return nil }
            let dnsName = node.dnsName.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 } ?? ""
            guard let address = dnsName.isEmpty ? node.tailscaleIPs?.first : dnsName,
                  !address.isEmpty else { return nil }
            return TailnetPeer(
                id: node.id ?? address,
                hostName: node.hostName ?? address,
                address: address,
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
