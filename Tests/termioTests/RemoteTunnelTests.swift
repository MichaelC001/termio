import XCTest
@testable import termio

final class RemoteTunnelTests: XCTestCase {
    func testOriginValueDropsPathFromPublishedAddress() {
        XCTAssertEqual(
            RemoteTunnelService.originValue(of: "https://relay.example.com/termio"),
            "https://relay.example.com")
    }

    func testOriginValueKeepsNonDefaultPort() {
        XCTAssertEqual(
            RemoteTunnelService.originValue(of: "https://relay.example.com:8443/termio"),
            "https://relay.example.com:8443")
    }
}
