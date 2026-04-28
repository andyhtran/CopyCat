import Foundation
import ServiceManagement

// Wraps SMAppService.mainApp. Only meaningful for an app installed in
// /Applications — the login-item registration is keyed off the bundle's
// install location, so a half-built dev bundle in build/ won't survive
// reboots even if the API returns success.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                Log.app.info("launch-at-login registered")
            } else {
                try SMAppService.mainApp.unregister()
                Log.app.info("launch-at-login unregistered")
            }
        } catch {
            Log.app.error("launch-at-login toggle failed: \(error.localizedDescription)")
        }
    }
}
