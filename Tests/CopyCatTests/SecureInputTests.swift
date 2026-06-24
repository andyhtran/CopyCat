import XCTest
@testable import CopyCat

final class SecureInputTests: XCTestCase {
    func testReturnsPIDWhenSessionHoldsSecureInput() {
        let sessions: [[String: Any]] = [["kCGSSessionSecureInputPID": 92893]]
        XCTAssertEqual(SecureInput.secureInputPID(in: sessions), 92893)
    }

    func testReturnsNilWhenKeyAbsent() {
        let sessions: [[String: Any]] = [["kCGSSessionUserNameKey": "andy"]]
        XCTAssertNil(SecureInput.secureInputPID(in: sessions))
    }

    // The key is absent (not zero) when off; a zero value is treated inactive.
    func testTreatsZeroPIDAsInactive() {
        let sessions: [[String: Any]] = [["kCGSSessionSecureInputPID": 0]]
        XCTAssertNil(SecureInput.secureInputPID(in: sessions))
    }

    func testFindsPIDAcrossMultipleSessions() {
        let sessions: [[String: Any]] = [
            ["kCGSSessionUserNameKey": "andy"],
            ["kCGSSessionSecureInputPID": 501],
        ]
        XCTAssertEqual(SecureInput.secureInputPID(in: sessions), 501)
    }

    func testReturnsNilForEmptySessions() {
        XCTAssertNil(SecureInput.secureInputPID(in: []))
    }

    func testLiveGUIOwnerDescribesByName() {
        let owner = SecureInput.Owner(pid: 123, appName: "Ghostty", isRunning: true)
        XCTAssertEqual(owner.description, "Ghostty")
        XCTAssertFalse(owner.isOrphaned)
    }

    func testLiveDaemonOwnerDescribesByPID() {
        let owner = SecureInput.Owner(pid: 456, appName: nil, isRunning: true)
        XCTAssertEqual(owner.description, "pid 456")
        XCTAssertFalse(owner.isOrphaned)
    }

    func testDeadOwnerIsFlaggedOrphaned() {
        let owner = SecureInput.Owner(pid: 789, appName: nil, isRunning: false)
        XCTAssertEqual(owner.description, "pid 789, no longer running")
        XCTAssertTrue(owner.isOrphaned)
    }
}
