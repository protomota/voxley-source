import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class LaunchAtLogin {
    private static let configuredKey = "didConfigureLaunchAtLogin"
    private let service = SMAppService.mainApp

    private(set) var status: SMAppService.Status = .notRegistered
    private(set) var errorMessage: String?

    var isRegistered: Bool { status == .enabled || status == .requiresApproval }

    func configureDefault() {
        refresh()
        guard !UserDefaults.standard.bool(forKey: Self.configuredKey) else { return }
        if isRegistered {
            UserDefaults.standard.set(true, forKey: Self.configuredKey)
        } else {
            setEnabled(true)
        }
    }

    func refresh() {
        status = service.status
    }

    func setEnabled(_ enabled: Bool) {
        refresh()
        errorMessage = nil
        do {
            if enabled != isRegistered {
                if enabled {
                    try service.register()
                } else {
                    try service.unregister()
                }
            }
            UserDefaults.standard.set(true, forKey: Self.configuredKey)
        } catch {
            errorMessage = enabled
                ? "Voxley couldn’t enable Launch at Login."
                : "Voxley couldn’t disable Launch at Login."
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
