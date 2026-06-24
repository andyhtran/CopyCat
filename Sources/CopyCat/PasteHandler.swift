import AppKit
import CoreGraphics

// All mutation happens on the main thread (eventtap callback + watchdog
// timer fire there). We mark Sendable for the [weak self] capture in
// the watchdog closure; concurrent access isn't actually possible.
final class PasteHandler: @unchecked Sendable {
    private var tap: CFMachPort?
    private var runloopSource: CFRunLoopSource?
    private var watchdog: Timer?
    private var uiTimer: Timer?
    private var lastEventTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    // Dedup flag so the blocked→restored transition is logged/notified once
    // each, not every 30s tick. Menu state is pushed separately via publishStatus.
    private var secureInputWarned = false

    func start() {
        installTap()
        startWatchdog()
        startUIRefresh()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Log.tap.info("wake detected — reinstalling tap")
            self?.teardownTap()
            self?.installTap()
        }
    }

    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        watchdog?.invalidate()
        watchdog = nil
        uiTimer?.invalidate()
        uiTimer = nil
        teardownTap()
    }

    // Public probe so the menu bar status header can reflect tap state.
    var isTapEnabled: Bool {
        guard let tap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    // Push current tap + Secure Input state into the observable menu model.
    // The menu can't read these live (the reads aren't observable, so SwiftUI
    // froze them at launch — the old "Tap off" bug), so we publish on every
    // state change and once per watchdog tick. Callers are always on the main
    // thread (start / wake observer / main-runloop timer), so assumeIsolated is
    // safe and avoids an async hop. Assigns only on change to skip churn.
    private func publishStatus() {
        let enabled = isTapEnabled
        // Gate the menu warning on the same allowlist as the alert, so the two
        // surfaces stay consistent: no "blocked by <browser>" while you're just
        // on a login page.
        let blocker: String?
        if case .blocked(let owner) = SecureInput.status(), frontmostIsTarget() {
            blocker = owner?.description ?? "unknown source"
        } else {
            blocker = nil
        }
        MainActor.assumeIsolated {
            let model = StatusModel.shared
            if model.tapEnabled != enabled { model.tapEnabled = enabled }
            if model.secureInputBlocker != blocker { model.secureInputBlocker = blocker }
        }
    }

    private func teardownTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let src = runloopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            }
            CFMachPortInvalidate(tap)
        }
        tap = nil
        runloopSource = nil
        publishStatus()
    }

    private func installTap() {
        // Publish on every exit path so a failed install (no Accessibility,
        // nil tap) shows "Tap off" rather than a stale value.
        defer { publishStatus() }
        guard ensureAccessibility(prompt: true) else {
            Log.tap.error("Accessibility not granted — tap NOT installed. Grant in System Settings → Privacy & Security → Accessibility, then relaunch.")
            return
        }

        // Subscribe to keyDown plus the two "OS killed your tap" events so we
        // can re-enable inline without losing keystrokes.
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.tapDisabledByTimeout.rawValue) |
            (1 << CGEventType.tapDisabledByUserInput.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let handler = Unmanaged<PasteHandler>.fromOpaque(refcon).takeUnretainedValue()
                return handler.handle(type: type, event: event)
            },
            userInfo: userInfo
        )

        guard let tap else {
            Log.tap.error("CGEvent.tapCreate returned nil — Accessibility may have been revoked")
            return
        }

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runloopSource = src
        Log.tap.info("installed (enabled=\(CGEvent.tapIsEnabled(tap: tap)))")
    }

    private func frontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    // The same allowlist gate CopyCat uses to decide whether to act on ⌘V.
    // The watchdog reuses it so Secure Input alerts fire only when the user is
    // in an app CopyCat handles: a focused password field in some other app
    // (a browser, say) blocks the tap session-wide too, but isn't the user's
    // concern at that moment, so alerting would just be noise.
    private func frontmostIsTarget() -> Bool {
        guard let id = frontmostBundleID() else { return false }
        return Settings.targetBundleIDs.contains(id)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        lastEventTime = CFAbsoluteTimeGetCurrent()

        // OS killed the tap — re-enable in place. The event itself is
        // synthetic and gets discarded.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let reason = type == .tapDisabledByTimeout ? "timeout" : "userInput"
            Log.tap.info("OS disabled tap (\(reason)) — re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return nil
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        let isLocal     = Settings.enableLocalPaste && HotkeyBinding.localPaste.matches(keyCode: keyCode, flags: flags)
        let isBroadcast = Settings.enableBroadcast && Settings.broadcastHotkey.binding.matches(keyCode: keyCode, flags: flags)

        guard isLocal || isBroadcast else {
            return Unmanaged.passUnretained(event)
        }

        // Broadcast wins ties: if both bindings collide, the more-specific
        // (more-modifiers) chord is the broadcast one in the default config.
        let category = isBroadcast ? Log.cmdOptV : Log.cmdV

        let frontmost = frontmostBundleID()
        guard let frontmost, Settings.targetBundleIDs.contains(frontmost) else {
            category.info("bail — frontmost is \(frontmost ?? "nil")")
            return Unmanaged.passUnretained(event)
        }

        // Quick clipboard probe: just check declared types, don't read the
        // image. The full read happens off-thread so this callback returns
        // in <5ms even on a giant Retina capture.
        guard NSPasteboard.general.hasImageType else {
            category.info("bail — clipboard has no image")
            return Unmanaged.passUnretained(event)
        }

        if isBroadcast {
            DispatchQueue.global(qos: .userInitiated).async {
                Broadcast.handle()
            }
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                ImagePaste.handleLocal()
            }
        }
        return nil
    }

    private func startWatchdog() {
        watchdog = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.checkAndRevive()
        }
    }

    // The 30s watchdog is too coarse for the menu: the Secure Input warning
    // would lag up to 30s appearing and clearing. A short poll keeps the menu
    // within a couple seconds of reality. publishStatus only writes the model
    // on change, so steady state is just a cheap read with no re-render.
    private static let uiRefreshInterval: TimeInterval = 2

    private func startUIRefresh() {
        uiTimer = Timer.scheduledTimer(withTimeInterval: Self.uiRefreshInterval, repeats: true) { [weak self] _ in
            self?.publishStatus()
        }
    }

    // How long the tap must be silent before we look for Secure Input. Silence
    // is NOT proof of a dead tap — it's identical to the user simply not typing —
    // so it only gates the Secure Input check (and keeps that from false-alarming
    // on brief password prompts). The "silent death" that originally motivated a
    // silence-based reinstall traced back to Secure Input, which we now detect
    // directly; real tap death surfaces via tapIsEnabled and the OS tapDisabled
    // events instead.
    private static let staleTapInterval: CFTimeInterval = 90

    private func checkAndRevive() {
        // Refresh the menu model once per tick regardless of which branch we
        // take — this is what keeps Secure Input status current in the menu.
        defer { publishStatus() }
        guard let tap else {
            Log.watchdog.info("tap is nil; reinstalling")
            installTap()
            return
        }
        let enabled = CGEvent.tapIsEnabled(tap: tap)
        let silent = CFAbsoluteTimeGetCurrent() - lastEventTime

        // Long silence with the tap still "enabled" has one confirmed cause:
        // Secure Input swallowing key events. Idle looks identical, so we surface
        // Secure Input but deliberately do NOT reinstall on silence — that just
        // churned a healthy, merely-idle tap every 30s. A reinstall can't defeat
        // Secure Input anyway. Only alert when the user is in an app CopyCat
        // handles; otherwise stay quiet.
        if enabled && silent > Self.staleTapInterval, case .blocked(let owner) = SecureInput.status() {
            if frontmostIsTarget() {
                logSecureInputBlocked(owner)
            } else {
                Log.watchdog.info("Secure Input active (\(owner?.description ?? "unknown source")); frontmost not a target app — not alerting")
            }
            return
        }

        noteSecureInputCleared()

        if enabled {
            Log.watchdog.info("tap.enabled=true")
            return
        }
        Log.watchdog.info("tap.enabled=false; re-enabling")
        CGEvent.tapEnable(tap: tap, enable: true)
        if !CGEvent.tapIsEnabled(tap: tap) {
            Log.watchdog.error("re-enable did not stick; full reinstall")
            teardownTap()
            installTap()
        }
    }

    // Log the blocked edge once (prominent, actionable), then a quiet per-tick
    // line so a `tail -f` keeps showing the live cause. Remediation differs by
    // owner: a live app can be quit/refocused, but an orphaned lock survives
    // that and needs a WindowServer reset.
    private func logSecureInputBlocked(_ owner: SecureInput.Owner?) {
        let restore = HotkeyBinding.localPaste.displayString
        guard !secureInputWarned else {
            Log.watchdog.info("still blocked by Secure Input (\(owner?.description ?? "unknown source"))")
            return
        }
        secureInputWarned = true
        if let owner, owner.isOrphaned {
            Log.tap.error("blocked by an orphaned Secure Input lock — its owner (pid \(owner.pid)) exited without releasing it; \(restore) stays dead session-wide until a WindowServer reset (log out and back in) clears it")
        } else if let owner {
            Log.tap.error("blocked by Secure Input held by \(owner.description) — key events are suppressed for every app session-wide; quit/refocus \(owner.appName ?? "that process") or finish its password prompt to restore \(restore)")
        } else {
            Log.tap.error("blocked by Secure Input (owner unknown) — key events are suppressed session-wide; if it persists, log out and back in to restore \(restore)")
        }
        Notifier.secureInputBlocked(owner)
    }

    // Log the blocked→restored edge exactly once so a `tail -f` shows a clear
    // recovery line instead of events silently resuming.
    private func noteSecureInputCleared() {
        guard secureInputWarned else { return }
        secureInputWarned = false
        Log.tap.info("Secure Input cleared — \(HotkeyBinding.localPaste.displayString) interception restored")
        Notifier.secureInputCleared()
    }

    private func ensureAccessibility(prompt: Bool) -> Bool {
        // Hardcoded value of kAXTrustedCheckOptionPrompt — referencing the
        // global var trips Swift 6 strict concurrency (it's non-Sendable).
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let opts = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }
}

extension NSPasteboard {
    var hasImageType: Bool {
        guard let types else { return false }
        let imageTypes: Set<NSPasteboard.PasteboardType> = [
            .tiff,
            .png,
            NSPasteboard.PasteboardType("public.png"),
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.tiff"),
        ]
        return !Set(types).isDisjoint(with: imageTypes)
    }
}

enum Typer {
    // Synthesize keystrokes via keyboardSetUnicodeString so we don't have to
    // map characters to physical keycodes. The synthesized events have no
    // modifier flags so they won't re-trigger our hotkey handler.
    static func type(_ text: String) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        for codeUnit in text.utf16 {
            var unit = codeUnit
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            down?.flags = []
            down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
            down?.post(tap: .cghidEventTap)

            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            up?.flags = []
            up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
            up?.post(tap: .cghidEventTap)
        }
    }
}
