import XCTest
@testable import CopyCat

final class PruneTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("copycat-prunetests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func makeScreenshot(name: String, ageSeconds: TimeInterval) throws {
        let url = tmpDir.appendingPathComponent(name)
        try Data().write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-ageSeconds)],
            ofItemAtPath: url.path
        )
    }

    func testKeepsOnlyNewestN() throws {
        // Newest first: 0s, 10s, 20s, 30s, 40s old.
        for i in 0..<5 {
            try makeScreenshot(
                name: "screenshot-\(i).jpg",
                ageSeconds: TimeInterval(i * 10)
            )
        }

        pruneScreenshotCache(dir: tmpDir, keep: 3)

        let remaining = try FileManager.default
            .contentsOfDirectory(atPath: tmpDir.path)
            .sorted()
        XCTAssertEqual(
            remaining,
            ["screenshot-0.jpg", "screenshot-1.jpg", "screenshot-2.jpg"]
        )
    }

    // The prune is intentionally narrow — only files matching the
    // `screenshot-` prefix get touched. The log file lives in the same
    // directory and must survive even when keep=0.
    func testDoesNotTouchNonScreenshotFiles() throws {
        try Data().write(to: tmpDir.appendingPathComponent("copycat.log"))
        try Data().write(to: tmpDir.appendingPathComponent("notes.txt"))
        try makeScreenshot(name: "screenshot-1.jpg", ageSeconds: 0)

        pruneScreenshotCache(dir: tmpDir, keep: 0)

        let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: tmpDir.path))
        XCTAssertTrue(remaining.contains("copycat.log"))
        XCTAssertTrue(remaining.contains("notes.txt"))
        XCTAssertFalse(remaining.contains("screenshot-1.jpg"))
    }

    func testNoOpWhenUnderLimit() throws {
        try makeScreenshot(name: "screenshot-a.jpg", ageSeconds: 0)
        try makeScreenshot(name: "screenshot-b.jpg", ageSeconds: 5)

        pruneScreenshotCache(dir: tmpDir, keep: 10)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: tmpDir.path)
        XCTAssertEqual(remaining.count, 2)
    }
}
