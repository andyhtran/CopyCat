import AppKit
import IOKit.hid

// Detects ⌘V while Secure Input is blocking the event tap. Secure Input hides
// keyboard events from CGEventTaps but not from IOHID device monitoring, so
// this is the only way to know the user just tried to paste while blocked —
// the tap literally never sees the keystroke. Listen-only (no seize): the
// original event still reaches the frontmost app untouched. Non-chord keys
// are discarded in the callback; nothing is stored or logged.
//
// Reports the full modifier set so the caller can distinguish the exact local
// paste chord (degradable) from broadcast variants (explain-only).
//
// Requires the Input Monitoring TCC grant (Accessibility approval typically
// satisfies it). The watcher arms this only while a blockage episode is live,
// so HID monitoring is off in normal operation.
@MainActor
final class PasteAttemptSensor {
    private var manager: IOHIDManager?
    /// HID usages (0xE0–0xE7) of modifiers currently held down.
    private var downModifiers: Set<Int> = []
    private let onPasteAttempt: (CGEventFlags) -> Void

    init(onPasteAttempt: @escaping (CGEventFlags) -> Void) {
        self.onPasteAttempt = onPasteAttempt
    }

    static var accessGranted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Triggers the one-time OS consent prompt; returns whether access is
    /// granted right now (a fresh prompt returns false until the user acts).
    static func requestAccess() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    func start() {
        guard manager == nil else { return }
        guard Self.accessGranted else { return }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [[String: Any]] = [[
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard,
        ]]
        IOHIDManagerSetDeviceMatchingMultiple(manager, match as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            let sensor = Unmanaged<PasteAttemptSensor>.fromOpaque(context).takeUnretainedValue()
            // Scheduled on the main runloop, so the callback lands on main.
            MainActor.assumeIsolated {
                sensor.handle(value: value)
            }
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let rc = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard rc == kIOReturnSuccess else {
            Log.secure.error("paste-attempt sensor: IOHIDManagerOpen failed (\(rc))")
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            return
        }
        self.manager = manager
        Log.secure.info("paste-attempt sensor armed")
    }

    func stop() {
        guard let manager else { return }
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        self.manager = nil
        downModifiers = []
        Log.secure.info("paste-attempt sensor disarmed")
    }

    private func handle(value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_KeyboardOrKeypad) else { return }
        let usage = Int(IOHIDElementGetUsage(element))
        let pressed = IOHIDValueGetIntegerValue(value) != 0

        switch usage {
        case kHIDUsage_KeyboardLeftControl...kHIDUsage_KeyboardRightGUI:
            if pressed { downModifiers.insert(usage) } else { downModifiers.remove(usage) }
        case kHIDUsage_KeyboardV:
            if pressed && currentFlags().contains(.maskCommand) {
                onPasteAttempt(currentFlags())
            }
        default:
            break
        }
    }

    private func currentFlags() -> CGEventFlags {
        var flags = CGEventFlags()
        for usage in downModifiers {
            switch usage {
            case kHIDUsage_KeyboardLeftControl, kHIDUsage_KeyboardRightControl:
                flags.insert(.maskControl)
            case kHIDUsage_KeyboardLeftShift, kHIDUsage_KeyboardRightShift:
                flags.insert(.maskShift)
            case kHIDUsage_KeyboardLeftAlt, kHIDUsage_KeyboardRightAlt:
                flags.insert(.maskAlternate)
            case kHIDUsage_KeyboardLeftGUI, kHIDUsage_KeyboardRightGUI:
                flags.insert(.maskCommand)
            default:
                break
            }
        }
        return flags
    }
}
