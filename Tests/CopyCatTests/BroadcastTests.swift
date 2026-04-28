import XCTest
@testable import CopyCat

final class BroadcastTests: XCTestCase {
    // The `--` separator is what stops ssh from interpreting a hostname like
    // `-oProxyCommand=...` as an option. Without it, a hostile or typo'd
    // hostname could smuggle ssh client options.
    func testSSHArgsContainSeparatorBeforeHost() {
        let args = sshArgs(host: "example.com", remoteCmd: "echo hi", connectTimeout: 5)
        let dashDash = args.firstIndex(of: "--")
        let host = args.firstIndex(of: "example.com")
        XCTAssertNotNil(dashDash, "ssh argv must include `--`")
        XCTAssertNotNil(host)
        XCTAssertLessThan(dashDash!, host!, "`--` must come before the host argument")
    }

    func testSSHArgsBlockArgumentInjection() {
        let evil = "-oProxyCommand=touch /tmp/pwned"
        let args = sshArgs(host: evil, remoteCmd: "true", connectTimeout: 5)
        let dashDash = args.firstIndex(of: "--")
        // Use lastIndex so a hostname that starts with `-o…` doesn't collide
        // with the `-o BatchMode=yes` flag positions.
        let host = args.lastIndex(of: evil)
        XCTAssertNotNil(dashDash)
        XCTAssertNotNil(host)
        XCTAssertLessThan(dashDash!, host!, "argv ordering must defang `-o…`-style hostnames")
    }

    func testSSHArgsCarriesBatchModeAndTimeout() {
        let args = sshArgs(host: "h", remoteCmd: "cmd", connectTimeout: 7)
        XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertTrue(args.contains("ConnectTimeout=7"))
    }

    func testSSHArgsPlacesRemoteCmdAfterHost() {
        let args = sshArgs(host: "h", remoteCmd: "REMOTE", connectTimeout: 1)
        // Host then remote command — that's the ssh argv contract.
        XCTAssertEqual(args.suffix(2), ["h", "REMOTE"])
    }
}
