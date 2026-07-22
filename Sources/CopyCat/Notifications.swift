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

    static func secureInputBlocked(_ presentation: SecureInputPresentation) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = presentation.title
        // Advice only — banners get ~4 visible lines and the title already
        // names the culprit; the full cause stays in the menu and log.
        content.body = presentation.advice
        content.sound = .default

        let request = UNNotificationRequest(identifier: secureInputID, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func secureInputCleared() {
        guard available else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [secureInputID])
    }
}
