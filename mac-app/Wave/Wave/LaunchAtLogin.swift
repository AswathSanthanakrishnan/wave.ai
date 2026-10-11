import AppKit
import Combine
import SwiftUI
import ServiceManagement

// MARK: - Launch at Login Manager (macOS 13+ SMAppService)

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    @Published private(set) var isEnabled: Bool = false

    init() {
        refreshStatus()
    }

    /// Queries the system Login Items state
    func refreshStatus() {
        if #available(macOS 13.0, *) {
            isEnabled = (SMAppService.mainApp.status == .enabled)
        } else {
            isEnabled = UserDefaults.standard.bool(forKey: "launch_at_login")
        }
    }

    /// Enables or disables automatic launch on Mac boot/login
    func setEnabled(_ enable: Bool) {
        UserDefaults.standard.set(enable, forKey: "launch_at_login")
        if #available(macOS 13.0, *) {
            do {
                if enable {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else {
                    if SMAppService.mainApp.status == .enabled {
                        try SMAppService.mainApp.unregister()
                    }
                }
            } catch {
                NSLog("Wave LaunchAtLogin registration warning: %@", error.localizedDescription)
            }
            refreshStatus()
        } else {
            isEnabled = enable
        }
    }

    /// Automatically registers launch-at-login on startup by default, keeping Wave living in the system.
    func configureOnLaunch() {
        let isFirstRun = UserDefaults.standard.object(forKey: "launch_at_login") == nil
        if isFirstRun {
            // Default to enabled: your Mac boots, the ball is just there.
            setEnabled(true)
        } else if UserDefaults.standard.bool(forKey: "launch_at_login") {
            if #available(macOS 13.0, *), SMAppService.mainApp.status != .enabled {
                try? SMAppService.mainApp.register()
            }
            refreshStatus()
        }
    }
}
