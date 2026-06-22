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
    }

    private func installTap() {
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

        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
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

    // Stale-tap detection: macOS can silently stop delivering events to
    // a CGEvent tap even though tapIsEnabled still returns true. The Mach
    // port stays valid but the kernel no longer routes HID events through
    // it. A keyboard generates continuous keyDown events from normal
    // typing, so a 5-minute silence is a strong signal the tap is dead.
    private static let staleTapInterval: CFTimeInterval = 90

    private func checkAndRevive() {
        guard let tap else {
            Log.watchdog.info("tap is nil; reinstalling")
            installTap()
            return
        }
        let enabled = CGEvent.tapIsEnabled(tap: tap)
        let silent = CFAbsoluteTimeGetCurrent() - lastEventTime

        if enabled && silent > Self.staleTapInterval {
            Log.watchdog.info("tap appears stale (enabled=true but silent \(Int(silent))s); full reinstall")
            teardownTap()
            installTap()
            return
        }

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
