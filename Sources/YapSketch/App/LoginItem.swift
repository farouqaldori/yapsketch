import Foundation
import ServiceManagement

/// Opening YapSketch when you log in: macOS's login item for this app, the one System
/// Settings › General › Login Items lists.
enum LoginItem {
    static var isOn: Bool { SMAppService.mainApp.status == .enabled }

    /// macOS wants it approved in System Settings before it takes effect.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.info("login item: \(error.localizedDescription)")
        }
    }

    /// Onboarding offers it once, switched on; after that it's whatever the person chose.
    static func offerOnce() {
        let key = "loginItemOffered"
        // Only the real app (not the debug binary or a snapshot run) becomes a login item.
        guard Bundle.main.bundleIdentifier == "com.yapsketch.app", !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        set(true)
    }
}
