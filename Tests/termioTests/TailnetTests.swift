import XCTest
@testable import termio

/// Which tailnet machines the Add Host sheet offers, read from the shape
/// `tailscale status --json` prints.
final class TailnetTests: XCTestCase {

    private func status(backend: String = "Running", peers: String) -> Data {
        Data("""
        {
          "BackendState": "\(backend)",
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

    func testAnUnrelatedHostIsNoReasonToHideAMachine() {
        // `Host mini` pointing somewhere else shares a name, not a machine.
        XCTAssertEqual(Tailnet.peers(miniPeers, notReachedBy: ["mini.example.com"]).map(\.hostName), ["mini"])
    }
}
