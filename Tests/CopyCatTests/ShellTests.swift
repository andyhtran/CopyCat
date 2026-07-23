import XCTest
@testable import CopyCat

final class ShellTests: XCTestCase {
    func testCapturesStdoutAndStderrSeparately() throws {
        let result = try XCTUnwrap(runShell("/bin/sh", args: ["-c", "echo OUT; echo ERR >&2"]))
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "OUT"
        )
        XCTAssertEqual(
            result.stderr.trimmingCharacters(in: .whitespacesAndNewlines),
            "ERR"
        )
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.exitCode, 0)
    }

    func testPropagatesNonZeroExitCode() throws {
        let result = try XCTUnwrap(runShell("/bin/sh", args: ["-c", "echo bad >&2; exit 42"]))
        XCTAssertEqual(result.exitCode, 42)
        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(
            result.stderr.trimmingCharacters(in: .whitespacesAndNewlines),
            "bad"
        )
    }

    func testReturnsNilWhenSpawnFails() {
        // Path doesn't exist — Process.run() throws, runShell maps to nil.
        let result = runShell("/nonexistent/binary-\(UUID().uuidString)", args: [])
        XCTAssertNil(result)
    }

    // The old runShell discarded stderr entirely. This is the regression
    // pin: stderr must be reachable to the caller.
    func testStderrSurvivesEvenWhenStdoutEmpty() throws {
        let result = try XCTUnwrap(runShell("/bin/sh", args: ["-c", "echo only-stderr >&2"]))
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertTrue(result.stderr.contains("only-stderr"))
    }

    // MARK: - Timeout

    func testTimeoutKillsHungProcess() throws {
        let start = Date()
        let result = try XCTUnwrap(runShell("/bin/sleep", args: ["30"], timeout: 0.3))
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.isSuccess)
        // Well under the sleep duration proves the watchdog, not the child,
        // ended the run. Generous bound so a loaded CI box doesn't flake.
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testFastProcessDoesNotTimeOut() throws {
        let result = try XCTUnwrap(runShell("/bin/echo", args: ["hi"], timeout: 5))
        XCTAssertFalse(result.timedOut)
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hi")
    }

    func testNoTimeoutParameterMeansUnbounded() throws {
        // Pin the default: omitting timeout must not kill even a slow-ish
        // child. 1s keeps the suite fast while still outliving any plausible
        // accidental internal deadline.
        let result = try XCTUnwrap(runShell("/bin/sleep", args: ["1"]))
        XCTAssertFalse(result.timedOut)
        XCTAssertTrue(result.isSuccess)
    }
}
