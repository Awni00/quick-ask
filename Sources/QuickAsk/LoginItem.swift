import Foundation
import ServiceManagement

/// Opens QuickAsk at login via the system's login-item service (shown in
/// System Settings → General → Login Items).
///
/// The user's choice is kept in Settings and re-applied on every launch,
/// because a rebuilt app (new ad-hoc signature) can lose its registration.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Needs the user to approve it in System Settings.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ enabled: Bool) {
        Settings.shared.launchAtLogin = enabled
        apply()
    }

    /// Only an installed copy registers, so a test build in build/ never
    /// replaces the one in Applications.
    static var isInstalledCopy: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    /// Brings the system registration in line with the user's setting.
    static func apply() {
        guard isInstalledCopy else { return }
        let wanted = Settings.shared.launchAtLogin
        let service = SMAppService.mainApp
        do {
            if wanted, service.status != .enabled {
                try service.register()
            } else if !wanted, service.status == .enabled {
                try service.unregister()
            }
        } catch {
            NSLog("QuickAsk: couldn't \(wanted ? "register" : "unregister") login item: \(error)")
        }
    }
}
