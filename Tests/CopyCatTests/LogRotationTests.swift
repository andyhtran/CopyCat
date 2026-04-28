import XCTest
@testable import CopyCat

final class LogRotationTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("copycat-logtests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testNoOpUnderThreshold() throws {
        let path = tmpDir.appendingPathComponent("small.log")
        let original = Data(repeating: 0x41, count: 1024)  // 1 KB of 'A'
        try original.write(to: path)

        LogFile.truncateIfOversized(at: path, maxBytes: 4096, keepBytes: 1024)

        let after = try Data(contentsOf: path)
        XCTAssertEqual(after, original, "small files must be left alone")
    }

    func testTruncatesOversizedFile() throws {
        let path = tmpDir.appendingPathComponent("big.log")
        let lines = (0..<500).map { "line \($0)\n" }.joined()
        try Data(lines.utf8).write(to: path)
        let originalSize = lines.utf8.count

        LogFile.truncateIfOversized(at: path, maxBytes: 200, keepBytes: 100)

        let after = try Data(contentsOf: path)
        XCTAssertLessThan(after.count, originalSize)
        XCTAssertLessThanOrEqual(after.count, 100)
    }

    func testTruncationAlignsToLineBoundary() throws {
        let path = tmpDir.appendingPathComponent("aligned.log")
        let lines = (0..<200).map { "line-\($0)\n" }.joined()
        try Data(lines.utf8).write(to: path)

        LogFile.truncateIfOversized(at: path, maxBytes: 200, keepBytes: 100)

        let after = try String(contentsOf: path, encoding: .utf8)
        // Should not begin mid-token; every line we keep should start with
        // "line-" because the truncator advances to the next newline.
        for raw in after.split(separator: "\n", omittingEmptySubsequences: true) {
            XCTAssertTrue(
                raw.hasPrefix("line-"),
                "found partial line at top of rotated log: \(raw)"
            )
        }
    }

    func testRetainsTailContent() throws {
        let path = tmpDir.appendingPathComponent("tail.log")
        let lines = (0..<200).map { "line-\($0)\n" }.joined()
        try Data(lines.utf8).write(to: path)

        LogFile.truncateIfOversized(at: path, maxBytes: 200, keepBytes: 100)

        let after = try String(contentsOf: path, encoding: .utf8)
        // The most recent line must survive; older ones should be gone.
        XCTAssertTrue(after.contains("line-199"), "newest line was dropped")
        XCTAssertFalse(after.contains("line-0\n"), "oldest line should have been pruned")
    }

    func testMissingFileIsHarmless() {
        let path = tmpDir.appendingPathComponent("does-not-exist.log")
        // Should not throw or crash.
        LogFile.truncateIfOversized(at: path, maxBytes: 10, keepBytes: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }
}
