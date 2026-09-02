import Foundation
import ServiceManagement
import Combine

/// Manages automatic launch on Mac restart/login using `SMAppService.mainApp`.
@MainActor
final class LaunchManager: ObservableObject {
    static let shared = LaunchManager()

    private let userDefaultsKey = "rd.startAutomaticallyOnRestart"

    @Published private(set) var isEnabled: Bool = true
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var lastError: String?

    private init() {
        let currentStatus = SMAppService.mainApp.status
        self.status = currentStatus

        let hasSavedPreference = UserDefaults.standard.object(forKey: userDefaultsKey) != nil
        if !hasSavedPreference {
            // Default enabled on first launch
            UserDefaults.standard.set(true, forKey: userDefaultsKey)
            self.isEnabled = true
            applyRegistration(true)
        } else {
            let savedPreference = UserDefaults.standard.bool(forKey: userDefaultsKey)
            self.isEnabled = savedPreference
            if savedPreference && currentStatus == .notRegistered {
                applyRegistration(true)
            } else if !savedPreference && currentStatus == .enabled {
                applyRegistration(false)
            }
        }
    }

    /// Re-checks SMAppService status against system configuration and user preference.
    func refreshStatus() {
        status = SMAppService.mainApp.status
        if let savedPreference = UserDefaults.standard.object(forKey: userDefaultsKey) as? Bool {
            if !savedPreference {
                isEnabled = false
            } else {
                isEnabled = (status == .enabled || status == .requiresApproval)
            }
        } else {
            isEnabled = true
        }
    }

    /// Enables or disables starting automatically on restart.
    func setLaunchOnRestart(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: userDefaultsKey)
        applyRegistration(enabled)
    }

    private func applyRegistration(_ enable: Bool) {
        lastError = nil
        do {
            if enable {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status != .notRegistered {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
        status = SMAppService.mainApp.status
        if let savedPreference = UserDefaults.standard.object(forKey: userDefaultsKey) as? Bool {
            isEnabled = savedPreference ? (status == .enabled || status == .requiresApproval) : false
        }
    }

    /// Opens System Settings -> General -> Login Items if user approval is needed.
    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
