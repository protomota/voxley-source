import AppKit
import ApplicationServices
import AVFoundation
import Observation
import OSLog
import Speech
import UniformTypeIdentifiers

enum Phase: Equatable {
    case idle, preparing, recording, transcribing, refining

    var title: String {
        switch self {
        case .idle: "Ready to dictate"
        case .preparing: "Getting the microphone ready…"
        case .recording: "Listening…"
        case .transcribing: "Transcribing…"
        case .refining: "Polishing with Apple Intelligence…"
        }
    }
}

@MainActor
@Observable
final class DictationController {
    private(set) var phase = Phase.idle
    var showsRecorder: Bool { phase == .preparing || phase == .recording }
    private(set) var liveText = ""
    private(set) var waveform = WaveformFrame.silence
    private(set) var recordingWindow: NSRect?
    private var latest: Transcript?
    private(set) var locales: [Locale] = []
    private(set) var shortcutReady = false
    private(set) var modelStatus = AppleModels.modelStatus
    private(set) var microphoneReady = false
    private(set) var accessibilityReady = false
    private(set) var pasteNeedsAttention = false
    private(set) var speechReady = false
    private(set) var speechStatus = "Checking model…"
    private(set) var shortcutPressed = false
    private(set) var shortcutPresses = 0
    private(set) var lastPasteStatus: String?
    private(set) var lastPracticePasteStatus: String?
    private(set) var testingPracticePaste = false
    @ObservationIgnored weak var practiceWindow: NSWindow?
    @ObservationIgnored weak var shortcutProbeWindow: NSWindow?
    var message: String?

    var preferences: Preferences {
        get { library.preferences }
        set {
            let changedLocale = newValue.locale != library.preferences.locale
            library.preferences = newValue
            if changedLocale { prepareSpeech() }
            save()
        }
    }
    var mostRecentTranscript: Transcript? { latest ?? library.history.first }

    private var library: Library
    @ObservationIgnored private let libraryURL: URL
    @ObservationIgnored private let shortcut = GlobalShortcut()
    @ObservationIgnored private let deliveryLog = Logger(subsystem: "com.protomota.voxley", category: "Delivery")
    @ObservationIgnored private var shortcutGesture = DictationShortcutGesture()
    @ObservationIgnored private var live: LiveDictation?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var destination: Destination?
    @ObservationIgnored private var capturePreferences: Preferences?
    @ObservationIgnored private var captureID: UUID?
    @ObservationIgnored private var speechPreparation: Task<Locale, Error>?
    @ObservationIgnored private var speechPreparationID: UUID?
    @ObservationIgnored private var preparationTimeout: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var diskReadable = true

    init() {
        let directory = URL.applicationSupportDirectory.appending(path: "Voxley", directoryHint: .isDirectory)
        libraryURL = directory.appending(path: "Library.json")
        do {
            library = FileManager.default.fileExists(atPath: libraryURL.path) ? try Library.read(libraryURL) : Library()
        } catch {
            library = Library()
            diskReadable = false
            message = "Couldn’t open the saved library. Voxley will leave that file untouched. Restore a backup to recover."
        }
    }

    func activate() {
        refreshPermissions()
        guard !started else { return }
        started = true
        shortcut.onEvent = { [weak self] pressed, time in self?.handleShortcut(pressed, at: time) }
        shortcut.onInterrupted = { [weak self] in
            guard let self else { return }
            self.shortcutPressed = false
            if self.shortcutGesture.interrupt() { self.cancel() }
        }
        if preferences.shortcutKey.isStandardEditingShortcut {
            let oldLabel = preferences.shortcutKey.label
            preferences.shortcutKey = .controlShiftSpace
            message = "Voxley reset \(oldLabel) to \(Shortcut.controlShiftSpace.label) so the editing command works normally."
        }
        retryShortcut()
        Task { locales = await SpeechTranscriber.supportedLocales }
        prepareSpeech()
    }

    func beginShortcutRecording() {
        shortcutGesture = DictationShortcutGesture()
        shortcutPressed = false
        message = nil
        shortcut.suspend()
    }

    func saveRecordedShortcut(_ recorded: Shortcut) -> Bool {
        guard shortcut.register(recorded) else { return false }
        shortcutReady = true
        message = "Shortcut saved: \(recorded.label)"
        if preferences.shortcutKey != recorded { preferences.shortcutKey = recorded }
        return true
    }

    func retryShortcut() {
        shortcutReady = shortcut.register(preferences.shortcutKey)
        deliveryLog.info("Global shortcut registered: \(self.shortcutReady, privacy: .public)")
    }

    func endSetupTest() {
        practiceWindow = nil
        shortcutProbeWindow = nil
        if destination?.isPractice == true { cancel() }
    }

    func testPracticePaste() async {
        guard phase == .idle, !testingPracticePaste else { return }
        let target = Destination(practiceWindow: practiceWindow, explicitPractice: true)
        guard target.practiceFieldReady else {
            lastPracticePasteStatus = "Click inside the practice field first"
            return
        }
        testingPracticePaste = true
        defer { testingPracticePaste = false }
        let delivery = await target.deliver("Voxley paste test.")
        lastPracticePasteStatus = delivery.status
        message = delivery.message
        deliveryLog.info("Practice paste: \(delivery.status, privacy: .public)")
    }

    func cancelShortcutRecording() { retryShortcut() }

    private func prepareSpeech() {
        speechPreparation?.cancel()
        let locale = preferences.locale
        let id = UUID()
        speechPreparationID = id
        speechStatus = "Preparing the on-device model…"
        speechPreparation = Task { [weak self] in
            do {
                let resolved = try await AppleModels.prepareSpeech(for: locale)
                if self?.speechPreparationID == id { self?.speechStatus = "Ready on this Mac" }
                return resolved
            } catch {
                if self?.speechPreparationID == id { self?.speechStatus = error.localizedDescription }
                throw error
            }
        }
    }

    func refreshPermissions() {
        modelStatus = AppleModels.modelStatus
        microphoneReady = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let canAccessFields = AXIsProcessTrusted()
        let canPostPaste = CGPreflightPostEventAccess()
        accessibilityReady = canAccessFields && canPostPaste
        deliveryLog.info("Voxley permissions: microphone \(self.microphoneReady, privacy: .public), field access \(canAccessFields, privacy: .public), key events \(canPostPaste, privacy: .public)")
        speechReady = SpeechTranscriber.isAvailable
    }

    func allowMicrophone() {
        Task {
            if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
                Self.openSettings("com.apple.preference.security?Privacy_Microphone")
            } else {
                _ = await LiveDictation.requestMicrophone()
                refreshPermissions()
            }
        }
    }

    func allowAccessibility() {
        Destination.requestAccessibility()
        Self.openSettings("com.apple.preference.security?Privacy_Accessibility")
    }

    static func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:" + pane) {
            NSWorkspace.shared.open(url)
        }
    }

    private func handleShortcut(_ pressed: Bool, at time: TimeInterval) {
        shortcutPressed = pressed
        if pressed { shortcutPresses += 1 }
        deliveryLog.debug("Shortcut \(pressed ? "pressed" : "released", privacy: .public)")
        if let shortcutProbeWindow, NSApp.keyWindow === shortcutProbeWindow, phase == .idle { return }
        let action = shortcutGesture.update(pressed: pressed, time: time,
                                            canStart: phase == .idle, isRecording: showsRecorder)
        switch action {
        case .start: start()
        case .stop:
            if phase == .preparing { cancel() }
            else { stopRecording() }
        case .none: break
        }
    }

    private func start() {
        guard phase == .idle, !testingPracticePaste else { return }
        let capture = LiveDictation()
        let id = UUID()
        let snapshot = preferences
        let target = Destination(practiceWindow: practiceWindow)
        live = capture
        captureID = id
        destination = target
        capturePreferences = snapshot
        liveText = ""
        recordingWindow = target.windowFrame
        message = nil
        if target.isPractice { lastPracticePasteStatus = nil }
        pasteNeedsAttention = false
        phase = .preparing

        if speechPreparation == nil { prepareSpeech() }
        let preparation = speechPreparation
        preparationTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(12)) }
            catch { return }
            guard let self, self.captureID == id, self.phase == .preparing else { return }
            self.cancel()
            self.message = "Apple Speech is still getting ready. Try holding the shortcut again in a moment."
        }
        task = Task { [self] in
            do {
                guard await LiveDictation.requestMicrophone() else { throw VoxleyError.microphone }
                refreshPermissions()
                try Task.checkCancellation()
                guard let preparation else { throw VoxleyError.speechUnavailable }
                let locale: Locale
                do {
                    locale = try await preparation.value
                } catch {
                    if captureID == id, preferences.locale == snapshot.locale { speechPreparation = nil }
                    throw error
                }
                let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
                try Task.checkCancellation()
                try await capture.start(
                    module: module, words: snapshot.contextWords,
                    update: { [weak self] text in await self?.showPartial(text, capture: id) },
                    meter: { [weak self] waveform in
                        Task { @MainActor in
                            guard let self, self.captureID == id, self.phase == .recording else { return }
                            self.waveform = waveform
                        }
                    }
                )
                try Task.checkCancellation()
                preparationTimeout?.cancel()
                phase = .recording
            } catch {
                await capture.cancel()
                guard captureID == id else { return }
                if !Task.isCancelled { message = error.localizedDescription }
                reset()
            }
        }
    }

    private func showPartial(_ text: String, capture id: UUID) {
        if captureID == id { liveText = text }
    }

    func stopRecording() {
        guard phase == .recording, let live, let target = destination, let snapshot = capturePreferences else { return }
        phase = .transcribing
        task = Task { [self] in
            do {
                let original = try await live.finish()
                try Task.checkCancellation()
                let mode = target.isPractice ? .verbatim : target.identifier.flatMap { snapshot.appModes[$0] } ?? snapshot.mode
                try await complete(original, mode: mode, snapshot: snapshot, source: target.name, target: target)
            } catch {
                if !Task.isCancelled { message = error.localizedDescription }
            }
            reset()
        }
    }

    func cancel() {
        guard phase == .preparing || phase == .recording else { return }
        let capture = live
        task?.cancel()
        reset()
        Task { await capture?.cancel() }
    }

    private func complete(_ original: String, mode: WritingMode, snapshot: Preferences,
                          source: String, target: Destination) async throws {
        guard !original.isEmpty else { throw VoxleyError.noSpeech }
        if mode != .verbatim { phase = .refining }
        let result = await AppleModels.refine(original, mode: mode, locale: snapshot.locale)
        let text = snapshot.applyingReplacements(to: result.text)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VoxleyError.noSpeech }

        let delivery = await target.deliver(text)
        deliveryLog.info("Delivery to \(target.identifier ?? "unknown", privacy: .public): \(delivery.status, privacy: .public)")
        refreshPermissions()
        if target.isPractice {
            lastPracticePasteStatus = delivery.status
            message = delivery.message
            return
        }
        let entry = Transcript(original: original, text: text, source: source, mode: mode)
        latest = entry
        lastPasteStatus = "\(source): \(delivery.status)"
        pasteNeedsAttention = delivery.needsAttention
        message = [result.note, delivery.message].compactMap { $0 }.joined(separator: " ").nilIfEmpty
        if preferences.retainHistory {
            library.history.insert(entry, at: 0)
            save()
        }
    }

    func exportBackup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Voxley Backup.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try library.write(url)
            message = "Backup exported."
        } catch {
            message = error.localizedDescription
        }
    }

    func importWordList() {
        let panel = NSOpenPanel()
        panel.title = "Import Word List"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.plainText, .commaSeparatedText, .tabSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            var encoding = String.Encoding.utf8
            let text = try String(contentsOf: url, usedEncoding: &encoding)
            var updated = library
            let added = try updated.preferences.importVocabulary(text)
            guard added > 0 else {
                message = "Those entries are already in your vocabulary."
                return
            }
            guard diskReadable else {
                message = "Restore your library before importing a word list."
                return
            }
            try persist(updated)
            library = updated
            message = added == 1 ? "Added 1 vocabulary entry." : "Added \(added) vocabulary entries."
        } catch {
            message = error.localizedDescription
        }
    }

    func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let backup = try Library.read(url)
            let confirm = NSAlert()
            confirm.messageText = "Restore Voxley backup?"
            confirm.informativeText = "This replaces your settings and merges transcripts into your current history."
            confirm.addButton(withTitle: "Restore")
            confirm.addButton(withTitle: "Cancel")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
            if !diskReadable && FileManager.default.fileExists(atPath: libraryURL.path) {
                let original = libraryURL.deletingLastPathComponent().appending(path: "Library-recovery-\(UUID()).json")
                try FileManager.default.copyItem(at: libraryURL, to: original)
            }
            var merged = library
            merged.restore(backup)
            let previousShortcut = preferences.shortcutKey
            let restoredShortcut = shortcut.register(merged.preferences.shortcutKey)
            if !restoredShortcut { merged.preferences.shortcutKey = previousShortcut }
            do {
                try persist(merged)
            } catch {
                shortcutReady = shortcut.register(previousShortcut)
                throw error
            }
            diskReadable = true
            library = merged
            shortcutReady = shortcut.register(preferences.shortcutKey)
            prepareSpeech()
            message = restoredShortcut ? "Backup restored." : "Backup restored. The saved shortcut was unavailable, so Voxley kept your current shortcut."
        } catch {
            message = error.localizedDescription
        }
    }

    private func reset() {
        preparationTimeout?.cancel()
        preparationTimeout = nil
        shortcutGesture = DictationShortcutGesture()
        phase = .idle
        task = nil
        captureID = nil
        live = nil
        destination = nil
        capturePreferences = nil
        liveText = ""
        waveform = WaveformFrame.silence
        recordingWindow = nil
    }

    private func persist(_ value: Library) throws {
        try FileManager.default.createDirectory(at: libraryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try value.write(libraryURL)
    }

    private func save() {
        guard diskReadable else {
            message = "The library could not be read. Changes are in memory until you restore a backup."
            return
        }
        do { try persist(library) }
        catch { message = "Couldn’t save the library: \(error.localizedDescription)" }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
