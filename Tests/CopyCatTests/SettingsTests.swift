import XCTest
@testable import CopyCat

final class SettingsTests: XCTestCase {
    func testTildeIsExpandedAtReadTime() {
        let url = Settings.resolveCacheDir(rawPath: "~/foo/bar")
        let home = NSHomeDirectory()
        XCTAssertTrue(url.path.hasPrefix(home), "expected expansion against home dir, got \(url.path)")
        XCTAssertTrue(url.path.hasSuffix("/foo/bar"))
    }

    func testAbsolutePathPassesThrough() {
        let url = Settings.resolveCacheDir(rawPath: "/tmp/copycat-test")
        XCTAssertEqual(url.path, "/tmp/copycat-test")
    }

    func testNilFallsBackToDefault() {
        XCTAssertEqual(Settings.resolveCacheDir(rawPath: nil), SettingsDefaults.cacheDir)
    }

    func testEmptyStringFallsBackToDefault() {
        XCTAssertEqual(Settings.resolveCacheDir(rawPath: ""), SettingsDefaults.cacheDir)
    }

    // Regression for the storage bug: the raw path the user typed must
    // round-trip without being eagerly expanded. Otherwise prefs synced
    // across machines / users break.
    func testRawTildeRoundTripsViaUserDefaults() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "copycat.tests.\(UUID().uuidString)"))
        defer { suite.removePersistentDomain(forName: suite.dictionaryRepresentation().keys.first ?? "") }

        suite.set("~/Documents/copycat", forKey: "cacheDirPath")
        let stored = suite.string(forKey: "cacheDirPath")
        XCTAssertEqual(stored, "~/Documents/copycat", "raw tilde should be preserved verbatim")

        let resolved = Settings.resolveCacheDir(rawPath: stored)
        XCTAssertFalse(resolved.path.hasPrefix("~"), "resolved URL should not still contain a tilde")
        XCTAssertTrue(resolved.path.hasSuffix("/Documents/copycat"))
    }
}
