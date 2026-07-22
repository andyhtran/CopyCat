import AppKit
import Foundation

// Classification layer between raw Secure Input state and user-facing alerts.
// A raw "blocked" is not actionable by itself: most holds are legitimate and
// transient (a focused password field, sudo in a terminal, the lock screen).
// Alerting on those trains the user to ignore the warning. Everything here is
// pure — state in, judgment out — so the noise policy is unit-testable.

/// Judgment about the current Secure Input hold, ordered roughly by severity.
enum SecureInputAssessment: Equatable, Sendable {
    case clear
    /// A hold that's normal right now: the frontmost app owns it (focused
    /// password field), a system auth dialog, or loginwindow while the screen
    /// is actually locked / screensaver is up. Never alert on these.
    case expected(SecureInput.Owner)
    /// loginwindow holds Secure Input while the session is unlocked. That
    /// combination is never legitimate — it's the well-known stuck state left
    /// behind by an unlock (biometric unlocks especially).
    case stuckLoginwindow(SecureInput.Owner)
    /// The frontmost app holds it AND it's one of CopyCat's target terminals —
    /// almost always the terminal's own "Secure Keyboard Entry" feature, which
    /// blocks ⌘V exactly where CopyCat matters. Expected briefly during
    /// password prompts, so this only alerts after a long grace.
    case terminalSecureEntry(SecureInput.Owner)
    /// A live, non-frontmost process holds it. Legitimate holders release
    /// within seconds (background password prompt); persistent ones are the
    /// classic "app forgot to release" bug.
    case backgroundHolder(SecureInput.Owner)
    /// The owning process is dead — the lock leaked and nothing can release it
    /// except a session reset.
    case orphaned(SecureInput.Owner)
    /// Blocked, but no owner PID could be resolved.
    case unknownHolder
}

extension SecureInputAssessment {
    /// Stable identity for alert dedup: same kind + same holder = same episode.
    /// nil means "never alert for this state".
    var alertKey: String? {
        switch self {
        case .clear, .expected:
            return nil
        case .stuckLoginwindow(let o):
            return "stuck-loginwindow:\(o.pid)"
        case .terminalSecureEntry(let o):
            return "terminal-ske:\(o.pid)"
        case .backgroundHolder(let o):
            return "background:\(o.pid)"
        case .orphaned(let o):
            return "orphaned:\(o.pid)"
        case .unknownHolder:
            return "unknown"
        }
    }

    /// How long the state must persist before alerting. Graces are the
    /// false-positive brake: every legitimate hold pattern must fit inside
    /// its bucket's grace or the alert becomes noise.
    var alertGrace: TimeInterval {
        switch self {
        case .clear, .expected:
            return .infinity
        // Never legitimate while unlocked; the grace only debounces the
        // few seconds loginwindow properly holds it during the unlock
        // handoff itself.
        case .stuckLoginwindow:
            return 3
        // Terminals auto-enable Secure Keyboard Entry around tty password
        // prompts (sudo, ssh); those routinely last tens of seconds. Only a
        // persistent hold — the manual menu toggle — should alert.
        case .terminalSecureEntry:
            return 30
        // Background password prompts (autofill dialogs etc.) come and go
        // within a few seconds.
        case .backgroundHolder:
            return 12
        // The IOKit key can linger for a beat after an owner exits cleanly.
        case .orphaned:
            return 5
        case .unknownHolder:
            return 20
        }
    }
}

enum SecureInputTriage {
    static let loginwindowBundleID = "com.apple.loginwindow"

    // System processes that legitimately hold Secure Input without being
    // frontmost (out-of-process auth dialogs).
    private static let expectedSystemHolders: Set<String> = [
        "com.apple.SecurityAgent",
    ]

    static func classify(
        status: SecureInput.Status,
        screenLocked: Bool,
        frontmostPID: pid_t?,
        targetBundleIDs: Set<String>
    ) -> SecureInputAssessment {
        guard case .blocked(let owner) = status else { return .clear }
        guard let owner else { return .unknownHolder }

        // loginwindow before the orphan check — it's always running, and the
        // locked/unlocked split is the entire judgment for it.
        if isLoginwindow(owner) {
            return screenLocked ? .expected(owner) : .stuckLoginwindow(owner)
        }
        if owner.isOrphaned {
            return .orphaned(owner)
        }
        if let bundleID = owner.bundleID, expectedSystemHolders.contains(bundleID) {
            return .expected(owner)
        }
        if owner.pid == frontmostPID {
            if let bundleID = owner.bundleID, targetBundleIDs.contains(bundleID) {
                return .terminalSecureEntry(owner)
            }
            return .expected(owner)
        }
        return .backgroundHolder(owner)
    }

    static func isLoginwindow(_ owner: SecureInput.Owner) -> Bool {
        owner.bundleID == loginwindowBundleID || owner.appName == "loginwindow"
    }
}

/// Edge-triggered alert gate: holds must survive their grace period before
/// alerting, each episode (kind+pid) alerts exactly once, and `cleared` fires
/// exactly once per alerted episode. Pure — the caller injects the clock.
struct SecureInputAlertPolicy {
    enum Action: Equatable {
        case none
        /// The state survived its grace — surface it now. Also fires when the
        /// holder changes mid-episode (new culprit deserves a fresh alert).
        case alert
        /// A previously alerted episode ended.
        case cleared
    }

    private var pendingKey: String?
    private var pendingSince: TimeInterval?
    private(set) var alertedKey: String?

    var isAlerting: Bool { alertedKey != nil }

    mutating func evaluate(key: String?, grace: TimeInterval, now: TimeInterval) -> Action {
        guard let key else {
            pendingKey = nil
            pendingSince = nil
            if alertedKey != nil {
                alertedKey = nil
                return .cleared
            }
            return .none
        }
        if key != pendingKey {
            pendingKey = key
            pendingSince = now
        }
        if alertedKey == key { return .none }
        if now - (pendingSince ?? now) >= grace {
            alertedKey = key
            return .alert
        }
        return .none
    }
}

/// Everything the surfaces (menu, HUD, notification) need to render one
/// blocked state, built in one place so all three tell the same story.
struct SecureInputPresentation: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case expected, stuckLoginwindow, terminalSecureEntry, backgroundHolder, orphaned, unknown
    }
    enum Action: Equatable, Sendable {
        case lockScreen
        case quitApp(pid: pid_t, name: String)

        var label: String {
            switch self {
            case .lockScreen: return "Lock Screen to Fix"
            case .quitApp(_, let name): return "Quit \(name)"
            }
        }
    }

    let kind: Kind
    /// Short one-liner for the menu caption.
    let menuLabel: String
    /// HUD / notification headline.
    let title: String
    /// Who's holding it and why that breaks paste.
    let detail: String
    /// What the user should do about it.
    let advice: String
    let action: Action?

    /// Short culprit tag for the collapsed HUD pill.
    let pillLabel: String

    static func make(for assessment: SecureInputAssessment) -> SecureInputPresentation? {
        let paste = HotkeyBinding.localPaste.displayString
        switch assessment {
        case .clear:
            return nil

        case .expected(let owner):
            return SecureInputPresentation(
                kind: .expected,
                menuLabel: "Secure Input active (\(owner.description))",
                title: "Secure Input active",
                detail: "\(owner.description) is holding Secure Input.",
                advice: "Normal while a password prompt is focused.",
                action: nil,
                pillLabel: owner.description)

        // "loginwindow" as holder is often misattribution: macOS pins Secure
        // Input on loginwindow when a background agent (password manager,
        // browser password prompt) actually grabbed it — and then only
        // quitting that app releases it; lock/unlock cycles won't.
        case .stuckLoginwindow:
            return SecureInputPresentation(
                kind: .stuckLoginwindow,
                menuLabel: "⚠ Blocked by Secure Input — loginwindow (stuck)",
                title: "Paste blocked — Secure Input is stuck",
                detail: "Secure Input is stuck attributed to loginwindow — usually a background password app (1Password, a browser) or an unlock that didn't release it.",
                advice: "Quit password apps (1Password, browser) — or lock the screen and unlock by typing your password.",
                action: .lockScreen,
                pillLabel: "loginwindow")

        case .terminalSecureEntry(let owner):
            let name = owner.appName ?? owner.description
            return SecureInputPresentation(
                kind: .terminalSecureEntry,
                menuLabel: "⚠ Blocked by Secure Input (\(name))",
                title: "Paste blocked by \(name)",
                detail: "\(name)'s Secure Keyboard Entry is hiding \(paste) from CopyCat.",
                advice: "Turn off Secure Keyboard Entry in \(name)'s menu if it persists.",
                action: nil,
                pillLabel: name)

        case .backgroundHolder(let owner):
            let name = owner.appName ?? owner.description
            return SecureInputPresentation(
                kind: .backgroundHolder,
                menuLabel: "⚠ Blocked by Secure Input (\(owner.description))",
                title: "Paste blocked by \(owner.description)",
                detail: "\(owner.description) is holding Secure Input from the background, hiding \(paste) from every app.",
                advice: "Finish its password prompt, or quit it.",
                // Quit is offered only for GUI apps: terminate() needs an
                // NSRunningApplication, which daemons/CLI holders don't have.
                action: owner.bundleID != nil ? .quitApp(pid: owner.pid, name: name) : nil,
                pillLabel: owner.description)

        case .orphaned(let owner):
            return SecureInputPresentation(
                kind: .orphaned,
                menuLabel: "⚠ Blocked by Secure Input (orphaned lock)",
                title: "Paste blocked — orphaned Secure Input lock",
                detail: "The process holding Secure Input (pid \(owner.pid)) exited without releasing it.",
                advice: "Lock and unlock the screen; log out if it persists.",
                action: .lockScreen,
                pillLabel: "orphaned lock")

        case .unknownHolder:
            return SecureInputPresentation(
                kind: .unknown,
                menuLabel: "⚠ Blocked by Secure Input (unknown source)",
                title: "Paste blocked by Secure Input",
                detail: "Something is holding Secure Input, but macOS won't name it.",
                advice: "Lock and unlock the screen; log out if it persists.",
                action: .lockScreen,
                pillLabel: "unknown source")
        }
    }
}

/// Executes a presentation's remediation action. Kept out of the views so the
/// menu and HUD share one implementation.
@MainActor
enum SecureInputActions {
    static func perform(_ action: SecureInputPresentation.Action) {
        switch action {
        case .lockScreen:
            Log.secure.info("user requested lock-screen remediation")
            SessionLock.lockScreen()
        case .quitApp(let pid, let name):
            Log.secure.info("user requested quit of Secure Input holder \(name) (pid \(pid))")
            guard let app = NSRunningApplication(processIdentifier: pid) else {
                Log.secure.error("holder pid \(pid) is not a running application — cannot terminate")
                return
            }
            app.terminate()
        }
    }
}
