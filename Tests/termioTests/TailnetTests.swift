import XCTest
@testable import termio

/// Which tailnet machines the Add Host sheet offers, read from the shape
/// `tailscale status --json` prints.
final class TailnetTests: XCTestCase {

    private func status(backend: String = "Running", peers: String) -> Data {
        Data("""
        {
          "BackendState": "\(backend)",
          "Self": {"ID": "self", "HostName": "laptop", "OS": "macOS", "UserID": 1},
          "Peer": {\(peers)}
        }
        """.utf8)
    }

    func testOffersOnlyMachinesThatCanHostSessions() {
        // A phone is on the tailnet too, but nothing can open a session on it.
        let peers = Tailnet.hostPeers(fromStatus: status(peers: """
            "a": {"ID": "a", "HostName": "mini", "DNSName": "mini.tail1.ts.net.", "OS": "macOS", "Online": true, "UserID": 1},
            "b": {"ID": "b", "HostName": "iphone", "DNSName": "iphone.tail1.ts.net.", "OS": "iOS", "Online": true, "UserID": 1},
            "c": {"ID": "c", "HostName": "vps", "DNSName": "vps.tail1.ts.net.", "OS": "linux", "Online": true, "UserID": 1}
            """))
        XCTAssertEqual(peers.map(\.hostName), ["mini", "vps"])
    }

    func testAddressIsTheMagicDNSNameWithoutItsRootDot() {
        // `HostName mini.tail1.ts.net.` resolves, but the trailing dot would also
        // be what the sheet derives the alias from and what the row shows.
        let peers = Tailnet.hostPeers(fromStatus: status(peers: """
            "a": {"ID": "a", "HostName": "mini", "DNSName": "mini.tail1.ts.net.", "OS": "macOS", "Online": true, "UserID": 1}
            """))
        XCTAssertEqual(peers.first?.address, "mini.tail1.ts.net")
    }

    func testWithoutMagicDNSTheAddressIsTheTailnetIP() {
        let peers = Tailnet.hostPeers(fromStatus: status(peers: """
            "a": {"ID": "a", "HostName": "mini", "DNSName": "", "OS": "macOS", "Online": true,
                  "TailscaleIPs": ["100.64.0.7", "fd7a:115c:a1e0::7"], "UserID": 1}
            """))
        XCTAssertEqual(peers.first?.address, "100.64.0.7")
    }

    func testOwnOnlineMachinesLead() {
        let peers = Tailnet.hostPeers(fromStatus: status(peers: """
            "a": {"ID": "a", "HostName": "alpha", "DNSName": "alpha.t.ts.net.", "OS": "linux", "Online": true, "UserID": 2},
            "b": {"ID": "b", "HostName": "bravo", "DNSName": "bravo.t.ts.net.", "OS": "linux", "Online": false, "UserID": 1},
            "c": {"ID": "c", "HostName": "charlie", "DNSName": "charlie.t.ts.net.", "OS": "macOS", "Online": true, "UserID": 1}
            """))
        XCTAssertEqual(peers.map(\.hostName), ["charlie", "bravo", "alpha"])
        XCTAssertEqual(peers.map(\.isOwn), [true, true, false])
    }

    func testAStoppedClientOffersNothing() {
        // Stopped or signed out, the client still prints its last network map,
        // which would list machines this Mac cannot reach.
        let peers = Tailnet.hostPeers(fromStatus: status(backend: "Stopped", peers: """
            "a": {"ID": "a", "HostName": "mini", "DNSName": "mini.t.ts.net.", "OS": "macOS", "Online": true, "UserID": 1}
            """))
        XCTAssertTrue(peers.isEmpty)
    }

    func testUnreadableOutputOffersNothing() {
        XCTAssertTrue(Tailnet.hostPeers(fromStatus: Data("not json".utf8)).isEmpty)
    }
}
