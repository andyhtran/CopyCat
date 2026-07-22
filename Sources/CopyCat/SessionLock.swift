import Foundation

// Locks the screen programmatically for Secure Input remediation. There is no
// public API for this: posting synthetic ⌃⌘Q can be swallowed by the very
// Secure Input state we're trying to clear, so we call login.framework's
// private SACLockScreenImmediate — the same call the Apple menu's Lock Screen
// item makes. Private-API risk is acceptable here: the app is notarized but
// not sandboxed/MAS, and the failure mode is a logged no-op.
enum SessionLock {
    private typealias LockFn = @convention(c) () -> Int32

    // Resolved once and cached; the framework handle is deliberately never
    // dlclosed (unloading system frameworks mid-process is riskier than the
    // one-time leak).
    private static let lockFn: LockFn? = {
        let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
        guard let handle = dlopen(path, RTLD_NOW) else {
            Log.secure.error("SessionLock: dlopen(login.framework) failed — \(String(cString: dlerror()))")
            return nil
        }
        guard let sym = dlsym(handle, "SACLockScreenImmediate") else {
            Log.secure.error("SessionLock: SACLockScreenImmediate not found in login.framework")
            return nil
        }
        return unsafeBitCast(sym, to: LockFn.self)
    }()

    static func lockScreen() {
        guard let lockFn else {
            Log.secure.error("SessionLock: lock unavailable — lock manually with ⌃⌘Q")
            return
        }
        let rc = lockFn()
        if rc != 0 {
            Log.secure.error("SessionLock: SACLockScreenImmediate returned \(rc)")
        }
    }
}
