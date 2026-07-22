import AppKit
import CoreGraphics

// Owns Secure Input detection and every user-facing surface for it: menu
// model, menu-bar icon badge, HUD toast, and notification banner. PasteHandler
// keeps only tap health — it can't own alerting because a blocked tap receives
// nothing, so it can't even see the state change promptly.
//
// Detection is layered:
//  - a 2s poll (1s while blocked, to announce recovery fast),
//  - probes at the moments a block is born or becomes relevant: screen
//    unlock (the stuck-loginwindow bug appears exactly there), wake,
//    screensaver stop, and app activation,
//  - optionally the IOHID paste-attempt sensor while blocked (the event tap
//    is blind then, but IOHID still sees ⌘V), so the toast can fire at the
//    exact moment the user tries to paste.
@MainActor
final class SecureInputWatcher {
    static let shared = SecureInputWatcher()

    /// Lets one poll publish both halves of the menu header; the watcher has
    /// no other reason to know about the tap.
    var tapEnabledProvider: (@MainActor () -> Bool)?

    private var pollTimer: Timer?
    private var pollingWhileBlocked = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []

    private var screenLocked = false
    private var screensaverActive = false

    private var policy = SecureInputAlertPolicy()
    private var currentPresentation: SecureInputPresentation?
    /// True while the assessment is an alertable kind — including the grace
    /// window before an alert fires. The sensor arms on this, not on
    /// policy.isAlerting, so a paste attempt in the first blocked seconds
    /// still gets caught.
    private var currentAlertable = false
    /// alertKey the HUD/notification were actually shown for. Distinct from
    /// policy.alertedKey: an alert that fires while the user is outside a
    /// target app stays undisplayed until they enter one.
    private var displayedKey: String?

    private var sensor: PasteAttemptSensor?
    private var lastDegradedPasteAt: TimeInterval = 0
    /// Physical double-taps aside, one ⌘V should produce one typed path.
    private static let degradedPasteCooldown: TimeInterval = 1

    private static let idleInterval: TimeInterval = 2
    private static let blockedInterval: TimeInterval = 1

    func start() {
        seedScreenLockState()
        installObservers()
        reschedulePoll(blocked: false)
        evaluate(reason: "startup")
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers = []
        distributedObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        distributedObservers = []
        disarmSensor()
        SecureInputHUD.shared.hide()
    }

    // MARK: - Signals

    // The lock-screen distributed notifications only fire on transitions, so
    // seed the flag from the session dictionary in case we launch while locked
    // (login item starting before first unlock completes).
    private func seedScreenLockState() {
        if let dict = CGSessionCopyCurrentDictionary() as? [String: Any] {
            screenLocked = (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
        }
    }

    private func installObservers() {
        let dnc = DistributedNotificationCenter.default()
        func distributed(_ name: String, _ handler: @escaping @MainActor (SecureInputWatcher) -> Void) {
            let token = dnc.addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    handler(self)
                }
            }
            distributedObservers.append(token)
        }

        distributed("com.apple.screenIsLocked") { watcher in
            watcher.screenLocked = true
            watcher.evaluate(reason: "screen locked")
        }
        distributed("com.apple.screenIsUnlocked") { watcher in
            watcher.screenLocked = false
            watcher.evaluate(reason: "screen unlocked")
            // The stuck-loginwindow state is born at unlock: loginwindow holds
            // Secure Input legitimately during the handoff, then either
            // releases within a couple seconds or never does. Probe on both
            // sides of the alert grace so a stuck hold alerts within ~5s.
            watcher.scheduleProbe(after: 2, reason: "post-unlock probe")
            watcher.scheduleProbe(after: 6, reason: "post-unlock probe")
        }
        distributed("com.apple.screensaver.didstart") { watcher in
            watcher.screensaverActive = true
            watcher.evaluate(reason: "screensaver started")
        }
        distributed("com.apple.screensaver.didstop") { watcher in
            watcher.screensaverActive = false
            watcher.evaluate(reason: "screensaver stopped")
            watcher.scheduleProbe(after: 2, reason: "post-screensaver probe")
        }

        let wnc = NSWorkspace.shared.notificationCenter
        func workspace(_ name: Notification.Name, _ handler: @escaping @MainActor (SecureInputWatcher) -> Void) {
            let token = wnc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    handler(self)
                }
            }
            workspaceObservers.append(token)
        }

        // App activation matters twice over: the frontmost app is an input to
        // classification, and entering a target terminal is when a deferred
        // alert becomes worth displaying.
        workspace(NSWorkspace.didActivateApplicationNotification) { watcher in
            watcher.evaluate(reason: "app activated")
        }
        workspace(NSWorkspace.didWakeNotification) { watcher in
            watcher.evaluate(reason: "wake")
            watcher.scheduleProbe(after: 3, reason: "post-wake probe")
        }
    }

    private func scheduleProbe(after seconds: TimeInterval, reason: String) {
        Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.evaluate(reason: reason)
            }
        }
    }

    private func reschedulePoll(blocked: Bool) {
        guard pollTimer == nil || blocked != pollingWhileBlocked else { return }
        pollingWhileBlocked = blocked
        pollTimer?.invalidate()
        let interval = blocked ? Self.blockedInterval : Self.idleInterval
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.evaluate(reason: "poll")
            }
        }
    }

    // MARK: - Core evaluation

    private func evaluate(reason: String) {
        let status = SecureInput.status()
        let frontmost = NSWorkspace.shared.frontmostApplication
        let assessment = SecureInputTriage.classify(
            status: status,
            screenLocked: screenLocked || screensaverActive,
            frontmostPID: frontmost?.processIdentifier,
            targetBundleIDs: Settings.targetBundleIDs)

        let presentation = SecureInputPresentation.make(for: assessment)
        currentPresentation = presentation
        currentAlertable = assessment.alertKey != nil
        publishModel(presentation)

        let action = policy.evaluate(
            key: assessment.alertKey,
            grace: assessment.alertGrace,
            now: Date().timeIntervalSinceReferenceDate)

        switch action {
        case .alert:
            guard let presentation, let key = assessment.alertKey else { break }
            Log.secure.error("Secure Input alert (\(reason)): \(presentation.title) — \(presentation.detail) \(presentation.advice)")
            if isTargetFrontmost(frontmost) {
                display(presentation, key: key)
            } else {
                // Not noise-worthy where the user is right now; the app
                // activation probe displays it the moment they enter a
                // terminal. The menu badge shows regardless via publishModel.
                Log.secure.info("alert display deferred — frontmost is not a target app")
            }

        case .cleared:
            Log.secure.info("Secure Input cleared (\(reason)) — \(HotkeyBinding.localPaste.displayString) interception restored")
            Notifier.secureInputCleared()
            if displayedKey != nil {
                SecureInputHUD.shared.showRestored()
            } else {
                SecureInputHUD.shared.hide()
            }
            displayedKey = nil

        case .none:
            // Deferred display: alerted earlier while the user was elsewhere,
            // and they've now entered a target app with the episode still live.
            if let alerted = policy.alertedKey,
               displayedKey != alerted,
               assessment.alertKey == alerted,
               let presentation,
               isTargetFrontmost(frontmost) {
                display(presentation, key: alerted)
            }
        }

        updateSensor(armed: currentAlertable)
        reschedulePoll(blocked: assessment != .clear)
    }

    private func display(_ presentation: SecureInputPresentation, key: String) {
        displayedKey = key
        SecureInputHUD.shared.showBlocked(presentation)
        Notifier.secureInputBlocked(presentation)
    }

    private func publishModel(_ presentation: SecureInputPresentation?) {
        let tapEnabled = tapEnabledProvider?()
        let alerting = policy.isAlerting
        let model = StatusModel.shared
        if let tapEnabled, model.tapEnabled != tapEnabled { model.tapEnabled = tapEnabled }
        if model.secureInput != presentation { model.secureInput = presentation }
        if model.secureInputAlerting != alerting { model.secureInputAlerting = alerting }
    }

    private func isTargetFrontmost(_ app: NSRunningApplication?) -> Bool {
        guard let id = app?.bundleIdentifier else { return false }
        return Settings.targetBundleIDs.contains(id)
    }

    // MARK: - Paste-attempt sensor

    // Armed only while a blockage episode is live (alertable kind, including
    // its grace window): the sensor exists to catch "user pressed paste while
    // blocked", and keeping HID monitoring off the rest of the time is both
    // cheaper and the right privacy posture.
    private func updateSensor(armed: Bool) {
        if armed {
            armSensor()
        } else {
            disarmSensor()
        }
    }

    private func armSensor() {
        guard sensor == nil else { return }
        guard PasteAttemptSensor.accessGranted else {
            Log.secure.info("paste-attempt sensor unavailable — Input Monitoring not granted")
            return
        }
        let sensor = PasteAttemptSensor { [weak self] flags in
            self?.notePasteAttempt(flags: flags)
        }
        sensor.start()
        self.sensor = sensor
    }

    private func disarmSensor() {
        sensor?.stop()
        sensor = nil
    }

    private func notePasteAttempt(flags: CGEventFlags) {
        guard currentAlertable, let presentation = currentPresentation else { return }
        guard isTargetFrontmost(NSWorkspace.shared.frontmostApplication) else { return }
        let pasteboard = NSPasteboard.general
        // If the clipboard has no image, CopyCat wouldn't have acted anyway —
        // the failed paste the user is seeing isn't ours to explain.
        guard pasteboard.hasImageType else { return }

        if degradedPasteAllowed(presentation: presentation, flags: flags, pasteboard: pasteboard) {
            let now = Date().timeIntervalSinceReferenceDate
            guard now - lastDegradedPasteAt > Self.degradedPasteCooldown else { return }
            lastDegradedPasteAt = now
            Log.secure.info("degraded paste: \(HotkeyBinding.localPaste.displayString) seen via HID while blocked — typing image path despite Secure Input (experimental)")
            SecureInputHUD.shared.showDegradedAttempt(presentation)
            DispatchQueue.global(qos: .userInitiated).async {
                ImagePaste.handleLocal()
            }
            return
        }

        Log.secure.info("paste attempt while blocked — surfacing HUD")
        displayedKey = policy.alertedKey ?? displayedKey
        SecureInputHUD.shared.showBlocked(presentation)
        Notifier.secureInputBlocked(presentation)
    }

    // The degraded path can't swallow the original ⌘V (that needs a seizing
    // virtual HID device), so it runs only when the raw keystroke is a no-op
    // for the terminal: exact local-paste chord, image-only clipboard (no
    // text flavor the terminal would paste itself). Terminal-SKE blocks are
    // excluded — that state usually means a password prompt is active in the
    // very terminal we'd type into.
    private func degradedPasteAllowed(
        presentation: SecureInputPresentation,
        flags: CGEventFlags,
        pasteboard: NSPasteboard
    ) -> Bool {
        guard Settings.enableLocalPaste else { return false }
        guard HotkeyBinding.localPaste.matchesModifiers(flags) else { return false }
        guard presentation.kind != .terminalSecureEntry, presentation.kind != .expected else { return false }
        return !pasteboard.hasTextLikeType
    }

    /// Menu action: request Input Monitoring for the sensor. The OS shows its
    /// consent prompt at most once; afterwards the toggle lives in System
    /// Settings, so open the pane when the request doesn't grant immediately.
    func requestSensorAccess() {
        guard !PasteAttemptSensor.accessGranted else { return }
        if !PasteAttemptSensor.requestAccess() {
            let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
            if let url = URL(string: pane) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    var sensorAccessGranted: Bool { PasteAttemptSensor.accessGranted }
}
