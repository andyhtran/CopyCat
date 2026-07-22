import AppKit
import CoreGraphics

// All mutation happens on the main thread (eventtap callback + watchdog
// timer fire there). We mark Sendable for the [weak self] capture in
// the watchdog closure; concurrent access isn't actually possible.
final class PasteHandler: @unchecked Sendable {
    private var tap: CFMachPort?
    private var runloopSource: CFRunLoopSource?
    private var watchdog: Timer?
    private var lastEventTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    private var starvedRebuilds = 0

    func start() {
        installTap()
        startWatchdog()

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
        teardownTap()
    }

    // Public probe so the menu bar status header can reflect tap state.
    var isTapEnabled: Bool {
        guard let tap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    // Push tap state into the observable menu model. The menu can't read it
    // live (the read isn't observable, so SwiftUI froze it at launch — the old
    // "Tap off" bug), so we publish on every state change and once per
    // watchdog tick; SecureInputWatcher also refreshes it on its own poll.
    // Callers are always on the main thread (start / wake observer /
    // main-runloop timer), so assumeIsolated is safe and avoids an async hop.
    // Secure Input state is owned end-to-end by SecureInputWatcher.
    private func publishStatus() {
        let enabled = isTapEnabled
        MainActor.assumeIsolated {
            let model = StatusModel.shared
            if model.tapEnabled != enabled { model.tapEnabled = enabled }
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

    // How long the tap must be silent before we look for blocked delivery paths.
    // Silence is NOT proof of a dead tap — it's identical to the user simply not
    // typing — so it only gates checks that have an independent signal. Secure
    // Input is detected directly, and real tap death must surface via tapIsEnabled,
    // the OS tapDisabled events, or the starved-queue check below.
    private static let staleTapInterval: CFTimeInterval = 90

    // WindowServer-reported queue latency above which an "enabled" tap is
    // treated as dead. Healthy FILTER taps report µs–ms; WindowServer's own
    // per-event tap timeout is single-digit seconds, so anything past 5s means
    // events are rotting in the queue, not being processed slowly.
    private static let starvedTapLatencyUs: Float = 5_000_000

    // How WindowServer sees our tap. A starved tap — mach port still registered
    // but its events no longer being serviced — keeps reporting enabled=true,
    // so tapIsEnabled can't detect it. The queue latency WindowServer tracks
    // per tap can: it grows in lockstep with wall clock while an event sits
    // undelivered.
    private func reportedTapLatencyUs() -> Float? {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return nil }
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        guard CGGetEventTapList(count, &taps, &count) == .success else { return nil }
        let pid = getpid()
        return taps.prefix(Int(count))
            .filter { $0.tappingProcess == pid }
            .map(\.avgUsecLatency)
            .max()
    }

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

        // Starved tap: enabled by every local measure, but WindowServer shows
        // events queued and unserviced. Re-enabling is a no-op for this state;
        // only a full rebuild recovers. Gate on silence too so one slow event
        // around a sleep/wake transition doesn't churn a healthy tap. Repeated
        // rebuilds point to an upstream event-delivery/session problem; the count
        // in the log line is the diagnostic signal.
        if enabled && silent > Self.staleTapInterval,
           let latencyUs = reportedTapLatencyUs(), latencyUs > Self.starvedTapLatencyUs {
            starvedRebuilds += 1
            Log.watchdog.error("tap starved — enabled but WindowServer queue latency \(Int(latencyUs / 1_000_000))s; rebuilding (rebuild #\(starvedRebuilds) since last healthy tick)")
            teardownTap()
            installTap()
            return
        }

        // Long silence with the tap still "enabled" has one confirmed cause:
        // Secure Input swallowing key events. A reinstall can't defeat Secure
        // Input, and rebuilding on silence just churned a healthy, merely-idle
        // tap every 30s — so skip the rebuild path entirely. Alerting the user
        // is SecureInputWatcher's job; this branch only protects the tap.
        if enabled && silent > Self.staleTapInterval, case .blocked(let owner) = SecureInput.status() {
            Log.watchdog.info("tap silent \(Int(silent))s with Secure Input active (\(owner?.description ?? "unknown source")) — not rebuilding")
            return
        }

        if enabled {
            starvedRebuilds = 0
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

    // Any flavor the frontmost app might paste on its own for a raw ⌘V. The
    // degraded (Secure Input) paste path can't swallow the original keystroke,
    // so it must only run when the terminal would paste nothing itself —
    // otherwise the terminal's paste and CopyCat's typed path both land.
    var hasTextLikeType: Bool {
        guard let types else { return false }
        let textTypes: Set<NSPasteboard.PasteboardType> = [
            .string, .rtf, .html, .fileURL, .URL,
        ]
        return !Set(types).isDisjoint(with: textTypes)
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
