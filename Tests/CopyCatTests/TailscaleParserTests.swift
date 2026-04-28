import XCTest
@testable import CopyCat

final class TailscaleParserTests: XCTestCase {
    func testParsesPeerListAndSortsByHostname() {
        let json = """
        {
          "Peer": {
            "key1": { "HostName": "Zeta", "Online": true,  "OS": "macOS"   },
            "key2": { "HostName": "alpha", "Online": false, "OS": "linux"  },
            "key3": { "HostName": "Mike",  "Online": true,  "OS": "iOS"    }
          }
        }
        """
        let peers = parseTailscalePeers(json: json)
        XCTAssertEqual(peers.map(\.hostname), ["alpha", "Mike", "Zeta"])
        XCTAssertEqual(peers.first { $0.hostname == "Zeta" }?.online, true)
        XCTAssertEqual(peers.first { $0.hostname == "alpha" }?.online, false)
        XCTAssertEqual(peers.first { $0.hostname == "Mike" }?.os, "iOS")
    }

    func testReturnsEmptyOnInvalidJSON() {
        XCTAssertTrue(parseTailscalePeers(json: "not json").isEmpty)
        XCTAssertTrue(parseTailscalePeers(json: "").isEmpty)
        XCTAssertTrue(parseTailscalePeers(json: "[]").isEmpty)
    }

    func testReturnsEmptyWhenPeerKeyMissing() {
        XCTAssertTrue(parseTailscalePeers(json: "{}").isEmpty)
    }

    func testSkipsPeersMissingRequiredFields() {
        let json = """
        {
          "Peer": {
            "ok":   { "HostName": "good", "Online": true },
            "bad1": { "Online": true },
            "bad2": { "HostName": "missing-online" }
          }
        }
        """
        let peers = parseTailscalePeers(json: json)
        XCTAssertEqual(peers.map(\.hostname), ["good"])
    }
}
