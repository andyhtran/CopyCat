import XCTest
@testable import CopyCat

final class SecureInputTriageTests: XCTestCase {
    private let targets: Set<String> = ["com.mitchellh.ghostty", "com.apple.Terminal"]

    private func owner(
        pid: pid_t = 500,
        appName: String? = "SomeApp",
        isRunning: Bool = true,
        bundleID: String? = "com.example.someapp"
    ) -> SecureInput.Owner {
        SecureInput.Owner(pid: pid, appName: appName, isRunning: isRunning, bundleID: bundleID)
    }

    // MARK: - Classification

    func testClearStatusIsClear() {
        XCTAssertEqual(
            SecureInputTriage.classify(
                status: .clear, screenLocked: false, frontmostPID: nil, targetBundleIDs: targets),
            .clear)
    }

    func testLoginwindowWhileUnlockedIsStuck() {
        let lw = owner(pid: 179, appName: "loginwindow", bundleID: "com.apple.loginwindow")
        XCTAssertEqual(
            SecureInputTriage.classify(
                status: .blocked(owner: lw), screenLocked: false, frontmostPID: 42, targetBundleIDs: targets),
            .stuckLoginwindow(lw))
    }

    func testLoginwindowWhileLockedIsExpected() {
        let lw = owner(pid: 179, appName: "loginwindow", bundleID: "com.apple.loginwindow")
        XCTAssertEqual(
            SecureInputTriage.classify(
                status: .blocked(owner: lw), screenLocked: true, frontmostPID: 42, targetBundleIDs: targets),
            .expected(lw))
    }

    // Daemon-style resolution can miss the bundle ID; the process name alone
    // must still route loginwindow into the stuck bucket.
    func testLoginwindowRecognizedByNameAlone() {
        let lw = owner(pid: 179, appName: "loginwindow", bundleID: nil)
        XCTAssertEqual(
            SecureInputTriage.classify(
                status: .blocked(owner: lw), screenLocked: false, frontmostPID: nil, targetBundleIDs: targets),
            .stuckLoginwindow(lw))
    }

    func testFrontmostHolderIsExpected() {
        let holder = owner(pid: 900, appName: "Safari", bundleID: "com.apple.Safari")
        XCTAssertEqual(
            SecureInputTriage.classify(
                status: .blocked(owner: holder), screenLocked: false, frontmostPID: 900, targetBundleIDs: targets),
            .expected(holder))
    }

    func testFrontmostTargetTerminalIsTerminalSecureEntry() {
        let ghostty = owner(pid: 900, appName: "Ghostty", bundleID: "com.mitchellh.ghostty")
        XCTAssertEqual(
            SecureInputTriage.classify(
                status: .blocked(owner: ghostty), screenLocked: false, frontmostPID: 900, targetBundleIDs: targets),
            .terminalSecureEntry(ghostty))
    }

    func testSecurityAgentIsExpectedEvenInBackground() {
        let agent = owner(pid: 700, appName: "SecurityAgent", bundleID: "com.apple.SecurityAgent")
        XCTAssertEqual(
            SecureInputTriage.classify(
                status: .blocked(owner: agent), screenLocked: false, frontmostPID: 42, targetBundleIDs: targets),
            .expected(agent))
    }

    func testBackgroundLiveHolder() {
        let holder = owner(pid: 900)
        XCTAssertEqual(
            SecureInputTriage.classify(
                status: .blocked(owner: holder), screenLocked: false, frontmostPID: 42, targetBundleIDs: targets),
            .backgroundHolder(holder))
    }

    func testDeadOwnerIsOrphaned() {
        let dead = owner(pid: 900, appName: nil, isRunning: false, bundleID: nil)
        XCTAssertEqual(
            SecureInputTriage.classify(
                status: .blocked(owner: dead), screenLocked: false, frontmostPID: 42, targetBundleIDs: targets),
            .orphaned(dead))
    }

    func testBlockedWithoutOwnerIsUnknown() {
        XCTAssertEqual(
            SecureInputTriage.classify(
                status: .blocked(owner: nil), screenLocked: false, frontmostPID: 42, targetBundleIDs: targets),
            .unknownHolder)
    }

    // MARK: - Alert policy

    func testPolicyWaitsOutGraceThenAlertsOnce() {
        var policy = SecureInputAlertPolicy()
        XCTAssertEqual(policy.evaluate(key: "stuck:179", grace: 3, now: 0), .none)
        XCTAssertEqual(policy.evaluate(key: "stuck:179", grace: 3, now: 2), .none)
        XCTAssertEqual(policy.evaluate(key: "stuck:179", grace: 3, now: 3.5), .alert)
        XCTAssertEqual(policy.evaluate(key: "stuck:179", grace: 3, now: 10), .none)
        XCTAssertTrue(policy.isAlerting)
    }

    func testPolicyClearsOncePerEpisode() {
        var policy = SecureInputAlertPolicy()
        _ = policy.evaluate(key: "stuck:179", grace: 0, now: 0)
        XCTAssertEqual(policy.evaluate(key: nil, grace: 0, now: 1), .cleared)
        XCTAssertEqual(policy.evaluate(key: nil, grace: 0, now: 2), .none)
        XCTAssertFalse(policy.isAlerting)
    }

    func testPolicyNoClearWhenNeverAlerted() {
        var policy = SecureInputAlertPolicy()
        XCTAssertEqual(policy.evaluate(key: "background:900", grace: 12, now: 0), .none)
        XCTAssertEqual(policy.evaluate(key: nil, grace: 0, now: 1), .none)
    }

    // A short flap back to clear restarts the grace clock — legitimate
    // transient holds must never accumulate toward an alert.
    func testPolicyFlapRestartsGrace() {
        var policy = SecureInputAlertPolicy()
        XCTAssertEqual(policy.evaluate(key: "background:900", grace: 12, now: 0), .none)
        XCTAssertEqual(policy.evaluate(key: nil, grace: 12, now: 6), .none)
        XCTAssertEqual(policy.evaluate(key: "background:900", grace: 12, now: 8), .none)
        XCTAssertEqual(policy.evaluate(key: "background:900", grace: 12, now: 19), .none)
        XCTAssertEqual(policy.evaluate(key: "background:900", grace: 12, now: 20), .alert)
    }

    func testPolicyHolderChangeAlertsFresh() {
        var policy = SecureInputAlertPolicy()
        XCTAssertEqual(policy.evaluate(key: "background:900", grace: 0, now: 0), .alert)
        XCTAssertEqual(policy.evaluate(key: "background:901", grace: 0, now: 1), .alert)
        XCTAssertEqual(policy.alertedKey, "background:901")
    }

    // MARK: - Presentation

    func testStuckLoginwindowPresentationOffersLockScreen() {
        let lw = owner(pid: 179, appName: "loginwindow", bundleID: "com.apple.loginwindow")
        let p = SecureInputPresentation.make(for: .stuckLoginwindow(lw))
        XCTAssertEqual(p?.kind, .stuckLoginwindow)
        XCTAssertEqual(p?.action, .lockScreen)
        XCTAssertTrue(p?.advice.contains("typing your password") ?? false)
    }

    func testBackgroundHolderPresentationOffersQuit() {
        let holder = owner(pid: 900, appName: "SomeApp")
        let p = SecureInputPresentation.make(for: .backgroundHolder(holder))
        XCTAssertEqual(p?.action, .quitApp(pid: 900, name: "SomeApp"))
    }

    func testBackgroundDaemonHolderHasNoQuitAction() {
        let daemon = owner(pid: 900, appName: nil, bundleID: nil)
        let p = SecureInputPresentation.make(for: .backgroundHolder(daemon))
        XCTAssertNil(p?.action)
    }

    // CLI holders resolve a process name but no bundle — terminate() can't
    // reach them, so no Quit button should be offered.
    func testBackgroundCLIHolderHasNoQuitAction() {
        let cli = owner(pid: 900, appName: "secure-hold", bundleID: nil)
        let p = SecureInputPresentation.make(for: .backgroundHolder(cli))
        XCTAssertNil(p?.action)
        XCTAssertEqual(p?.pillLabel, "secure-hold")
    }

    func testTerminalSecureEntryHasNoAction() {
        let ghostty = owner(pid: 900, appName: "Ghostty", bundleID: "com.mitchellh.ghostty")
        let p = SecureInputPresentation.make(for: .terminalSecureEntry(ghostty))
        XCTAssertNil(p?.action)
        XCTAssertTrue(p?.advice.contains("Secure Keyboard Entry") ?? false)
    }

    func testClearHasNoPresentation() {
        XCTAssertNil(SecureInputPresentation.make(for: .clear))
    }

    func testExpectedNeverAlerts() {
        let holder = owner()
        XCTAssertNil(SecureInputAssessment.expected(holder).alertKey)
        XCTAssertNil(SecureInputAssessment.clear.alertKey)
        XCTAssertNotNil(SecureInputAssessment.stuckLoginwindow(holder).alertKey)
    }
}
