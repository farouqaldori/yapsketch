import Foundation
import ServiceManagement

enum LoginItem {
    static var isOn: Bool { SMAppService.mainApp.status == .enabled }

    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.info("login item: \(error.localizedDescription)")
        }
    }

    static func offerOnce() {
        let key = "loginItemOffered"
        // Only the real app (not the debug binary or a snapshot run) becomes a login item.
        guard Bundle.main.bundleIdentifier == "com.yapsketch.app", !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        set(true)
    }
}
