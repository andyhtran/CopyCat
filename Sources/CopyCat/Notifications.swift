import Foundation
import UserNotifications

// Proactive surface for failures the user would otherwise only find by opening
// the menu or tailing the log. Secure Input blocks ⌘V silently and session-wide,
// so a banner is the only signal that reaches a user who isn't already looking.
enum Notifier {
    // Stable id so repeat posts replace rather than stack, and so recovery can
    // pull the now-stale banner back out of Notification Center.
    private static let secureInputID = "secure-input-blocked"

    // UNUserNotificationCenter.current() traps when there's no bundle proxy
    // (unit tests, raw CLI). Gate every entry point on a real bundle so the
    // detection code stays safe to exercise outside the packaged app.
    private static var available: Bool { Bundle.main.bundleIdentifier != nil }

    // Requested at launch, not at incident time: surfacing the OS permission
    // prompt during a failure would be worse than asking once up front.
    static func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { Log.app.error("notification auth failed: \(error.localizedDescription)") }
        }
    }

    static func secureInputBlocked(_ owner: SecureInput.Owner?) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = "CopyCat — paste blocked"
        content.body = blockedBody(owner)
        content.sound = .default

        let request = UNNotificationRequest(identifier: secureInputID, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func secureInputCleared() {
        guard available else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [secureInputID])
    }

    private static func blockedBody(_ owner: SecureInput.Owner?) -> String {
        let restore = HotkeyBinding.localPaste.displayString
        if let owner, owner.isOrphaned {
            return "An orphaned Secure Input lock (owner pid \(owner.pid) has exited) is suppressing \(restore) for every app. Log out and back in to clear it."
        }
        if let owner {
            return "\(owner.description) is holding Secure Input, which suppresses \(restore) for every app. Quit or refocus it, or finish its password prompt."
        }
        return "Secure Input is suppressing \(restore) for every app. Log out and back in if it persists."
    }
}
