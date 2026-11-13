#if VOXLEY_SPARKLE
import Foundation
import Observation
import Sparkle
import SwiftUI

@MainActor
@Observable
final class VoxleyUpdates: NSObject, SPUUpdaterDelegate {
    static let shared = VoxleyUpdates()

    private(set) var canCheck = false
    private(set) var automaticUpdates = false
    @ObservationIgnored private weak var dictation: DictationController?
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var pendingInstall: (() -> Void)?

    func start(dictation: DictationController) {
        guard controller == nil else { return }
        self.dictation = dictation
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil
        )
        self.controller = controller
        observations = [
            controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            },
            controller.updater.observe(\.automaticallyDownloadsUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            }
        ]
        controller.startUpdater()
        refresh()
    }

    func check() {
        guard dictation?.phase == .idle, let updater = controller?.updater, updater.canCheckForUpdates else { return }
        updater.checkForUpdates()
    }

    func setAutomaticUpdates(_ enabled: Bool) {
        controller?.updater.automaticallyDownloadsUpdates = enabled
        refresh()
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard dictation?.phase == .idle else {
            throw CocoaError(.userCancelled, userInfo: [
                NSLocalizedDescriptionKey: "Finish dictating before checking for updates."
            ])
        }
    }

    func updater(
        _ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        guard let dictation, dictation.phase != .idle else { return false }
        // Observe the whole dictation session, including final transcription and paste.
        pendingInstall = installHandler
        installWhenIdle()
        return true
    }

    private func installWhenIdle() {
        guard let dictation, dictation.phase != .idle else {
            let install = pendingInstall
            pendingInstall = nil
            install?()
            return
        }
        withObservationTracking {
            _ = dictation.phase
        } onChange: { [weak self] in
            Task { @MainActor in self?.installWhenIdle() }
        }
    }

    private func refresh() {
        canCheck = controller?.updater.canCheckForUpdates ?? false
        automaticUpdates = controller?.updater.automaticallyDownloadsUpdates ?? false
    }
}
#endif
