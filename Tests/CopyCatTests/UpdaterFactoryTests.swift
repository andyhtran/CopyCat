import SwiftUI
import XCTest
@testable import CopyCat

@MainActor
final class UpdaterFactoryTests: XCTestCase {
    func testDisabledUpdaterReportsUnavailable() {
        let updater = DisabledUpdaterController(unavailableReason: "test reason")
        XCTAssertFalse(updater.isAvailable)
        XCTAssertEqual(updater.unavailableReason, "test reason")
        XCTAssertTrue(updater.updateViewModel.state.isIdle)
    }

    func testDisabledUpdaterCheckIsNoop() {
        let updater = DisabledUpdaterController()
        updater.checkForUpdates(nil)
        XCTAssertTrue(updater.updateViewModel.state.isIdle)
    }

    func testUpdaterEnvironmentStoresInjectedController() throws {
        let updater = DisabledUpdaterController()
        var values = EnvironmentValues()
        values.updaterController = updater

        let stored = try XCTUnwrap(values.updaterController)
        XCTAssertTrue(stored === updater)
    }

    func testAutoUpdateDefaultsToEnabledWhenNoPreferenceExists() throws {
        try withIsolatedDefaults { defaults in
            XCTAssertTrue(UpdaterDefaults.savedAutoUpdateEnabled(in: defaults))
        }
    }

    func testAutoUpdatePreferenceUsesSparkleKeyWhenLegacyKeyIsMissing() throws {
        try withIsolatedDefaults { defaults in
            defaults.set(false, forKey: UpdaterDefaults.sparkleEnableAutomaticChecksKey)

            XCTAssertFalse(UpdaterDefaults.savedAutoUpdateEnabled(in: defaults))
        }
    }

    func testAutoUpdatePreferenceWritesLegacyAndSparkleKeys() throws {
        try withIsolatedDefaults { defaults in
            UpdaterDefaults.setAutoUpdateEnabled(false, in: defaults)

            XCTAssertFalse(defaults.bool(forKey: UpdaterDefaults.appAutomaticUpdateChecksEnabledKey))
            XCTAssertFalse(defaults.bool(forKey: UpdaterDefaults.sparkleEnableAutomaticChecksKey))
        }
    }

    func testAutomaticDownloadsMigrationPreservesChecksAndDisablesDownloads() throws {
        try withIsolatedDefaults { defaults in
            UpdaterDefaults.setAutoUpdateEnabled(true, in: defaults)
            defaults.set(true, forKey: UpdaterDefaults.sparkleAutomaticallyUpdateKey)

            UpdaterDefaults.disableAutomaticDownloads(in: defaults)

            XCTAssertTrue(UpdaterDefaults.savedAutoUpdateEnabled(in: defaults))
            XCTAssertFalse(defaults.bool(forKey: UpdaterDefaults.sparkleAutomaticallyUpdateKey))
        }
    }

    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "CopyCatTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}
