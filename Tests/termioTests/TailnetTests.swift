import XCTest
@testable import termio

/// Which tailnet machines the Add Host sheet offers, read from the shape
/// `tailscale status --json` prints.
final class TailnetTests: XCTestCase {

    private func status(backend: String = "Running", peers: String) -> Data {
        Data("""
        {
          "BackendState": "\(backend)",
          "MagicDNSSuffix": "tail1.ts.net",
          "Self": {"ID": "self", "HostName": "laptop", "DNSName": "laptop.tail1.ts.net.", "OS": "macOS", "UserID": 1},
          "Peer": {\(peers)}
        }
        """.utf8)
    }

    private let mini = """
        "a": {"ID": "a", "HostName": "mini", "DNSName": "mini.tail1.ts.net.", "OS": "macOS", "Online": true,
              "TailscaleIPs": ["100.64.0.7", "fd7a:115c:a1e0::7"], "UserID": 1}
        """

    func testOffersOnlyMachinesThatCanHostSessions() {
        // A phone is on the tailnet too, but nothing can open a session on it.
        let peers = Tailnet.hostPeers(fromStatus: status(peers: """
            \(mini),
            "b": {"ID": "b", "HostName": "iphone", "DNSName": "iphone.tail1.ts.net.", "OS": "iOS", "Online": true, "UserID": 1},
            "c": {"ID": "c", "HostName": "vps", "DNSName": "vps.tail1.ts.net.", "OS": "linux", "Online": true, "UserID": 1}
            """), namesResolve: true)
        XCTAssertEqual(peers.map(\.hostName), ["mini", "vps"])
    }

    func testAddressIsTheMagicDNSNameWithoutItsRootDot() {
        let peers = Tailnet.hostPeers(fromStatus: status(peers: mini), namesResolve: true)
        XCTAssertEqual(peers.first?.address, "mini.tail1.ts.net")
    }

    func testANameThisMacCannotResolveGivesWayToTheIPv4Address() {
        // `--accept-dns=false`: the status still carries every MagicDNS name, and
        // a `HostName` written from one would not resolve.
        let peers = Tailnet.hostPeers(fromStatus: status(peers: mini), namesResolve: false)
        XCTAssertEqual(peers.first?.address, "100.64.0.7")
    }

    func testWithoutMagicDNSTheAddressIsTheTailnetIP() {
        let peers = Tailnet.hostPeers(fromStatus: status(peers: """
            "a": {"ID": "a", "HostName": "mini", "DNSName": "", "OS": "macOS", "Online": true,
                  "TailscaleIPs": ["fd7a:115c:a1e0::7", "100.64.0.7"], "UserID": 1}
            """), namesResolve: true)
        XCTAssertEqual(peers.first?.address, "100.64.0.7")
    }

    func testOwnOnlineMachinesLead() {
        let peers = Tailnet.hostPeers(fromStatus: status(peers: """
            "a": {"ID": "a", "HostName": "alpha", "DNSName": "alpha.t.ts.net.", "OS": "linux", "Online": true, "UserID": 2},
            "b": {"ID": "b", "HostName": "bravo", "DNSName": "bravo.t.ts.net.", "OS": "linux", "Online": false, "UserID": 1},
            "c": {"ID": "c", "HostName": "charlie", "DNSName": "charlie.t.ts.net.", "OS": "macOS", "Online": true, "UserID": 1}
            """), namesResolve: true)
        XCTAssertEqual(peers.map(\.hostName), ["charlie", "bravo", "alpha"])
        XCTAssertEqual(peers.map(\.isOwn), [true, true, false])
    }

    func testAStoppedClientOffersNothing() {
        // Stopped or signed out, the client still prints its last network map,
        // which would list machines this Mac cannot reach.
        let peers = Tailnet.hostPeers(fromStatus: status(backend: "Stopped", peers: mini), namesResolve: true)
        XCTAssertTrue(peers.isEmpty)
    }

    func testUnreadableOutputOffersNothing() {
        XCTAssertTrue(Tailnet.hostPeers(fromStatus: Data("not json".utf8), namesResolve: true).isEmpty)
    }

    // MARK: This Mac's own address

    func testThisMacIsReachedByItsIPv4EvenWithMagicDNS() {
        // The phone dials plain `ws://`, which App Transport Security allows to an
        // IP address and refuses to a `.ts.net` name.
        let data = Data("""
            {"BackendState": "Running",
             "Self": {"ID": "self", "HostName": "laptop", "DNSName": "laptop.tail1.ts.net.", "OS": "macOS",
                      "TailscaleIPs": ["fd7a:115c:a1e0::1", "100.64.0.1"]}}
            """.utf8)
        XCTAssertEqual(Tailnet.ownAddress(fromStatus: data), "100.64.0.1")
    }

    func testAStoppedClientGivesThisMacNoAddress() {
        XCTAssertNil(Tailnet.ownAddress(fromStatus: status(backend: "Stopped", peers: mini)))
    }

    // MARK: Running the CLI

    private func fakeCLI(_ script: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tailscale-\(UUID().uuidString)")
        try "#!/bin/sh\n\(script)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    func testReadsTheCLIsAnswer() async throws {
        let json = String(decoding: status(peers: mini), as: UTF8.self)
        let cli = try fakeCLI("cat <<'EOF'\n\(json)\nEOF")
        let peers = await Tailnet.hostPeers(cli: cli)
        XCTAssertEqual(peers.map(\.hostName), ["mini"])
    }

    func testADescendantHoldingThePipeCannotOutlastTheDeadline() async throws {
        // The CLI exits at once, but a child it left behind keeps stdout open, so
        // end-of-file never comes. The read must still answer at the deadline.
        let cli = try fakeCLI("sleep 10 &\nexit 0")
        let start = Date()
        let peers = await Tailnet.hostPeers(cli: cli)
        XCTAssertTrue(peers.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(start), Tailnet.statusTimeout + 2)
    }

    func testAFailingCLIOffersNothing() async throws {
        let cli = try fakeCLI("echo 'failed to connect to local tailscaled' >&2\nexit 1")
        let peers = await Tailnet.hostPeers(cli: cli)
        XCTAssertTrue(peers.isEmpty)
    }

    // MARK: Already in ~/.ssh/config

    private var miniPeers: [TailnetPeer] {
        Tailnet.hostPeers(fromStatus: status(peers: mini), namesResolve: true)
    }

    func testAMachineConfiguredByItsIPIsLeftOut() {
        XCTAssertTrue(Tailnet.peers(miniPeers, notReachedBy: ["100.64.0.7"]).isEmpty)
    }

    func testAMachineConfiguredByItsNameIsLeftOutWhateverTheCaseAndRootDot() {
        XCTAssertTrue(Tailnet.peers(miniPeers, notReachedBy: ["MINI.tail1.ts.net."]).isEmpty)
    }

    func testABlockReachingTheBareMachineNameIsLeftOut() {
        // `Host mini` with no `HostName`: ssh resolves `mini` through MagicDNS's
        // search domain, so it is this machine already.
        XCTAssertTrue(Tailnet.peers(miniPeers, notReachedBy: ["mini"]).isEmpty)
    }

    func testTwoMachinesSharingAHostNameAreToldApartByTheirDNSNames() {
        // Tailscale gives the second `mini` the DNS name `mini-1`, so `Host mini`
        // reaches only the first.
        let peers = Tailnet.hostPeers(fromStatus: status(peers: """
            \(mini),
            "b": {"ID": "b", "HostName": "mini", "DNSName": "mini-1.tail1.ts.net.", "OS": "macOS", "Online": true,
                  "TailscaleIPs": ["100.64.0.8"], "UserID": 1}
            """), namesResolve: true)
        XCTAssertEqual(Tailnet.peers(peers, notReachedBy: ["mini"]).map(\.address), ["mini-1.tail1.ts.net"])
    }

    func testAShortNameOutsideThisTailnetIsNoIdentity() {
        // A machine shared in from another tailnet is not under the suffix this
        // Mac searches, so its short name reaches something else.
        let peers = Tailnet.hostPeers(fromStatus: status(peers: """
            "a": {"ID": "a", "HostName": "mini", "DNSName": "mini.other.ts.net.", "OS": "macOS", "Online": true,
                  "TailscaleIPs": ["100.64.0.9"], "UserID": 2}
            """), namesResolve: true)
        XCTAssertEqual(Tailnet.peers(peers, notReachedBy: ["mini"]).map(\.hostName), ["mini"])
    }

    func testABareNameIsNoIdentityWhereMagicDNSDoesNotResolve() {
        // Without MagicDNS here, `mini` reaches whatever the LAN calls mini.
        let peers = Tailnet.hostPeers(fromStatus: status(peers: mini), namesResolve: false)
        XCTAssertEqual(Tailnet.peers(peers, notReachedBy: ["mini"]).map(\.hostName), ["mini"])
    }

    func testAnIPv6AddressMatchesHoweverTheConfigSpellsIt() {
        XCTAssertTrue(Tailnet.peers(miniPeers, notReachedBy: ["fd7a:115c:a1e0:0:0:0:0:7"]).isEmpty)
        XCTAssertTrue(Tailnet.peers(miniPeers, notReachedBy: ["[FD7A:115C:A1E0::7]"]).isEmpty)
    }

    func testAnUnrelatedHostIsNoReasonToHideAMachine() {
        // `Host mini` pointing somewhere else shares a name, not a machine.
        XCTAssertEqual(Tailnet.peers(miniPeers, notReachedBy: ["mini.example.com"]).map(\.hostName), ["mini"])
    }
}
