import XCTest
@testable import CopyCat

@MainActor
final class UpdateStateTests: XCTestCase {
    func testViewModelDefaultsToIdle() {
        let model = UpdateViewModel()
        XCTAssertTrue(model.state.isIdle)
        XCTAssertEqual(model.state.phase, .idle)
    }

    func testPhaseMatchesCase() {
        XCTAssertEqual(UpdateState.idle.phase, .idle)
        XCTAssertEqual(UpdateState.checking(.init(cancel: {})).phase, .checking)
        XCTAssertEqual(
            UpdateState.updateAvailable(
                .init(version: "1.0", byteCount: nil, install: {}, dismiss: {})
            ).phase,
            .updateAvailable)
        XCTAssertEqual(
            UpdateState.downloading(
                .init(cancel: {}, expectedLength: nil, receivedLength: 0)
            ).phase,
            .downloading)
        XCTAssertEqual(UpdateState.extracting(.init(progress: 0)).phase, .extracting)
        XCTAssertEqual(UpdateState.installing.phase, .installing)
        XCTAssertEqual(UpdateState.notFound(.init(acknowledge: {})).phase, .notFound)
        XCTAssertEqual(
            UpdateState.failed(.init(message: "boom", dismiss: {})).phase,
            .failed)
    }

    func testManualChecksOnlyStartFromIdleOrTerminalStates() {
        XCTAssertTrue(UpdateState.idle.allowsManualCheck)
        XCTAssertFalse(UpdateState.checking(.init(cancel: {})).allowsManualCheck)
        XCTAssertFalse(
            UpdateState.updateAvailable(
                .init(version: "1.0", byteCount: nil, install: {}, dismiss: {})
            ).allowsManualCheck)
        XCTAssertFalse(
            UpdateState.downloading(
                .init(cancel: {}, expectedLength: nil, receivedLength: 0)
            ).allowsManualCheck)
        XCTAssertFalse(UpdateState.extracting(.init(progress: 0)).allowsManualCheck)
        XCTAssertFalse(UpdateState.installing.allowsManualCheck)
        XCTAssertTrue(UpdateState.notFound(.init(acknowledge: {})).allowsManualCheck)
        XCTAssertTrue(UpdateState.failed(.init(message: "boom", dismiss: {})).allowsManualCheck)
    }

    func testCancelInvokesCheckingCancellation() {
        var canceled = false
        UpdateState.checking(.init(cancel: { canceled = true })).cancel()
        XCTAssertTrue(canceled)
    }

    func testCancelDismissesAvailableUpdate() {
        var installed = false
        var dismissed = false
        UpdateState.updateAvailable(.init(
            version: "1.0", byteCount: nil,
            install: { installed = true },
            dismiss: { dismissed = true }
        )).cancel()
        XCTAssertTrue(dismissed)
        XCTAssertFalse(installed)
    }

    func testCancelStopsDownload() {
        var canceled = false
        UpdateState.downloading(.init(
            cancel: { canceled = true }, expectedLength: 100, receivedLength: 10
        )).cancel()
        XCTAssertTrue(canceled)
    }

    func testCancelAcknowledgesNotFound() {
        var acknowledged = false
        UpdateState.notFound(.init(acknowledge: { acknowledged = true })).cancel()
        XCTAssertTrue(acknowledged)
    }

    func testCancelDismissesFailure() {
        var dismissed = false
        UpdateState.failed(.init(message: "boom", dismiss: { dismissed = true }))
            .cancel()
        XCTAssertTrue(dismissed)
    }

    func testDownloadFractionRequiresExpectedLength() {
        let unknown = UpdateState.Downloading(
            cancel: {}, expectedLength: nil, receivedLength: 500)
        XCTAssertNil(unknown.fraction)

        let zero = UpdateState.Downloading(
            cancel: {}, expectedLength: 0, receivedLength: 500)
        XCTAssertNil(zero.fraction)
    }

    func testDownloadFractionIsRatioCappedAtOne() throws {
        let half = UpdateState.Downloading(
            cancel: {}, expectedLength: 200, receivedLength: 100)
        XCTAssertEqual(try XCTUnwrap(half.fraction), 0.5)

        // Sparkle documents that the expected length can undershoot the
        // actual download size.
        let over = UpdateState.Downloading(
            cancel: {}, expectedLength: 200, receivedLength: 300)
        XCTAssertEqual(try XCTUnwrap(over.fraction), 1.0)
    }
}
