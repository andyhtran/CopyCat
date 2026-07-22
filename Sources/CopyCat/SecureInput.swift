import AppKit
import Carbon
import Foundation
import IOKit

// macOS Secure Input (EnableSecureEventInput) is session-wide, not per-app:
// while any one process holds it, the kernel stops delivering key events to
// *every* CGEventTap, regardless of which app is frontmost. At the tap this is
// indistinguishable from "enabled but dead" — same symptom, opposite cause.
// A tap reinstall cannot bypass Secure Input, so the watchdog must detect it
// explicitly instead of churning the tap.
enum SecureInput {
    /// Who holds the lock, and whether that process still exists.
    struct Owner: Equatable, Sendable {
        let pid: pid_t
        /// Localized GUI app name (e.g. "Ghostty") or the BSD process name for
        /// daemons; nil only when the owner has already exited.
        let appName: String?
        let isRunning: Bool
        /// Bundle identifier when the owner is a GUI app — the stable key the
        /// triage layer matches against (loginwindow, target terminals).
        let bundleID: String?

        init(pid: pid_t, appName: String?, isRunning: Bool, bundleID: String? = nil) {
            self.pid = pid
            self.appName = appName
            self.isRunning = isRunning
            self.bundleID = bundleID
        }

        /// True when the lock points at a PID that no longer exists — the lock
        /// leaked because the owner died without balancing its enable. This is
        /// the stubborn case: quitting/restarting apps usually won't clear it;
        /// only a WindowServer reset (log out/in, reboot) reliably does.
        var isOrphaned: Bool { !isRunning }

        var description: String {
            if let appName { return appName }
            return isRunning ? "pid \(pid)" : "pid \(pid), no longer running"
        }
    }

    enum Status: Equatable {
        case clear
        /// Active but the owner couldn't be resolved (owner == nil) means key
        /// events are blocked by an unknown source — still actionable, just
        /// without a name to point at.
        case blocked(owner: Owner?)
    }

    /// Current block state. Treats Secure Input as active if *either* the Carbon
    /// API reports it *or* the IOKit session key is present — checked together
    /// defensively: during an orphaned lock the two can disagree (the IOKit key
    /// can linger on a dead owner), so relying on one alone risks missing it.
    static func status() -> Status {
        let owner = resolveOwner()
        if owner == nil && !IsSecureEventInputEnabled() { return .clear }
        return .blocked(owner: owner)
    }

    private static func resolveOwner() -> Owner? {
        guard let pid = ownerPID() else { return nil }
        let app = NSRunningApplication(processIdentifier: pid)
        // PID reuse is a tolerated race here: if `pid` was recycled we may label
        // a dead orphan as "running", but the lock itself is what we report on.
        let running = app != nil || processExists(pid)
        let name = app?.localizedName ?? (running ? processName(pid) : nil)
        return Owner(pid: pid, appName: name, isRunning: running, bundleID: app?.bundleIdentifier)
    }

    /// BSD process name for non-GUI holders (daemons, helpers) so the alert
    /// can name the culprit instead of showing a bare pid.
    private static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 128)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// PID recorded as the Secure Input owner, or nil when the key is absent.
    /// Source is the undocumented `kCGSSessionSecureInputPID` key on the
    /// IOConsoleUsers session dict — there is no public API that names the owner.
    static func ownerPID() -> pid_t? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }

        guard let sessions = IORegistryEntrySearchCFProperty(
            root,
            kIOServicePlane,
            "IOConsoleUsers" as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively)
        ) as? [[String: Any]] else { return nil }

        return secureInputPID(in: sessions)
    }

    /// Pure extraction of the owner PID from the IOConsoleUsers session array,
    /// split out so the dict-shape handling is testable without live IOKit.
    /// The key is absent (not zero) when Secure Input is off; a zero value is
    /// treated as inactive defensively.
    static func secureInputPID(in sessions: [[String: Any]]) -> pid_t? {
        for session in sessions {
            if let num = session["kCGSSessionSecureInputPID"] as? NSNumber,
               num.int32Value != 0 {
                return num.int32Value
            }
        }
        return nil
    }

    /// True if a process with `pid` exists. kill(_,0) is the canonical probe:
    /// 0 = exists; EPERM = exists but not ours; ESRCH = gone. Needed on top of
    /// NSRunningApplication because Secure Input can be held by non-GUI daemons.
    private static func processExists(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
