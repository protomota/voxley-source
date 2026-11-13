import AppKit
import SwiftUI

@MainActor
final class SetupWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private weak var controller: DictationController?

    func show(_ controller: DictationController) {
        if let window {
            bringForward(window)
            return
        }
        self.controller = controller
        controller.refreshPermissions()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 450),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Voxley Onboarding"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: VoxleyOnboarding(controller: controller,
            initialStep: UserDefaults.standard.bool(forKey: "didCompleteVoxleySetup") ? .shortcut : .welcome,
            windowForRecording: { [weak window] in window },
            select: { [weak window, weak controller] step in
                controller?.shortcutProbeWindow = step == .shortcut ? window : nil
                controller?.practiceWindow = step == .practice ? window : nil
            },
            finish: { [weak window] in
                UserDefaults.standard.set(true, forKey: "didCompleteVoxleySetup")
                window?.close()
            }
        ))
        self.window = window
        window.center()
        bringForward(window)
    }

    private func bringForward(_ window: NSWindow) {
        // Onboarding is a normal app window. Dictation returns to menu bar mode when it closes.
        NSApp.setActivationPolicy(.regular)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        controller?.endSetupTest()
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }
}

private struct VoxleyOnboarding: View {
    enum Step: Int, CaseIterable {
        case welcome, access, shortcut, practice

        var title: String {
            switch self {
            case .welcome: "Welcome to Voxley"
            case .access: "Permissions"
            case .shortcut: "Keyboard shortcut"
            case .practice: "Practice dictation"
            }
        }

        var icon: String {
            switch self {
            case .welcome: "waveform.circle"
            case .access: "checkmark.shield"
            case .shortcut: "keyboard"
            case .practice: "waveform"
            }
        }
    }

    let controller: DictationController
    let windowForRecording: () -> NSWindow?
    let select: (Step) -> Void
    let finish: () -> Void
    @State private var step: Step
    @State private var startingPresses = 0
    @State private var practiceText = ""
    @FocusState private var practiceFocused: Bool

    init(controller: DictationController, initialStep: Step,
         windowForRecording: @escaping () -> NSWindow?,
         select: @escaping (Step) -> Void, finish: @escaping () -> Void) {
        self.controller = controller
        self.windowForRecording = windowForRecording
        self.select = select
        self.finish = finish
        _step = State(initialValue: initialStep)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 17) {
                Text(step.title)
                    .font(.system(size: 26, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)

                switch step {
                case .welcome:
                    Text("Speak into any text field. Voxley transcribes on your Mac and pastes at your cursor.")
                        .foregroundStyle(.secondary)
                    Text("Check permissions, set your keyboard shortcut, and try a practice dictation.")
                        .foregroundStyle(.secondary)
                case .access: permissions
                case .shortcut: shortcut
                case .practice: practice
                }

                Spacer(minLength: 0)
                if let message = controller.message {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Divider()
                HStack {
                    if let previous = Step(rawValue: step.rawValue - 1) {
                        Button("Back") { step = previous }
                    }
                    Spacer()
                    if let next = Step(rawValue: step.rawValue + 1) {
                        Button(step == .welcome ? "Get Started" : "Continue") { step = next }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Done", action: finish)
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(26)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 680, minHeight: 450)
        .onChange(of: step, initial: true) {
            startingPresses = controller.shortcutPresses
            select(step)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("Voxley", systemImage: "waveform.circle.fill")
                .font(.title2.weight(.semibold))
                .padding(.bottom, 15)
            ForEach(Step.allCases, id: \.rawValue) { item in
                Button {
                    step = item
                } label: {
                    Label(item == .welcome ? "Welcome" : item.title, systemImage: item.icon)
                        .font(.callout.weight(step == item ? .semibold : .regular))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(step == item ? Color.accentColor.opacity(0.14) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(step == item ? .isSelected : [])
            }
            Spacer()
            Text("Setup & diagnostics").font(.caption).foregroundStyle(.secondary)
        }
        .padding(17)
        .frame(width: 192)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.35))
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Give Voxley access to listen and paste at your cursor. Apple Speech transcribes on this Mac.")
                .foregroundStyle(.secondary)
            statusRow("Microphone", detail: controller.microphoneReady ? "Allowed" : "Permission required",
                      ready: controller.microphoneReady) {
                if !controller.microphoneReady { Button("Allow Microphone", action: controller.allowMicrophone) }
            }
            statusRow("Automatic paste", detail: controller.accessibilityReady ? "Allowed" : "Permission required",
                      ready: controller.accessibilityReady) {
                if !controller.accessibilityReady { Button("Open System Settings", action: controller.allowAccessibility) }
            }
            statusRow("Apple Speech", detail: controller.speechStatus,
                      ready: controller.speechStatus == "Ready on this Mac") { EmptyView() }
            Button("Check Permissions Again", action: controller.refreshPermissions)
        }
    }

    private var shortcut: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Record your own key combination, then press it here. The indicator shows when Voxley receives the global key press and release.")
                .foregroundStyle(.secondary)
            ShortcutRecorder(controller: controller, windowForRecording: windowForRecording)
            let detected = controller.shortcutPresses > startingPresses
            statusRow("Shortcut test",
                      detail: controller.shortcutPressed ? "Pressed" : detected ? "Press and release detected" : "Waiting for your shortcut",
                      ready: detected) {
                Text(controller.preferences.shortcutKey.label)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            }
            if !controller.shortcutReady {
                Label("This shortcut couldn’t be registered. Try a different key combination.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Button("Retry Shortcut", action: controller.retryShortcut)
            }
            Text("Hold to talk and release to paste. For hands-free dictation, tap once to start and again to stop.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .onChange(of: controller.preferences.shortcutKey) {
            startingPresses = controller.shortcutPresses
        }
    }

    private var practice: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Click the field, hold \(controller.preferences.shortcutKey.label), say “Voxley is ready,” then release.")
                .foregroundStyle(.secondary)
            TextEditor(text: $practiceText)
                .font(.body)
                .focused($practiceFocused)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 72)
                .background(.quaternary.opacity(0.42), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary).allowsHitTesting(false)
                }
                .accessibilityLabel("Practice text field")
            statusRow("This test", detail: controller.testingPracticePaste ? "Testing paste…" :
                      controller.phase != .idle ? controller.phase.title :
                      controller.lastPracticePasteStatus ?? "Waiting for dictation",
                      ready: controller.lastPracticePasteStatus == "Paste confirmed") {
                Button("Test Paste") {
                    practiceFocused = true
                    Task {
                        try? await Task.sleep(for: .milliseconds(100))
                        if step == .practice { await controller.testPracticePaste() }
                    }
                }
                .disabled(controller.phase != .idle || controller.testingPracticePaste)
                Button("Clear") { practiceText = "" }
                    .disabled(practiceText.isEmpty || controller.phase != .idle || controller.testingPracticePaste)
            }
            if let lastPaste = controller.lastPasteStatus {
                Text("Last paste in another app: \(lastPaste)").font(.callout).foregroundStyle(.secondary)
            }
            Text("To check another app, dictate into an unsent draft there, then return here to see its paste status.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func statusRow<T: View>(_ title: String, detail: String, ready: Bool,
                                    @ViewBuilder trailing: () -> T) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ready ? Color.green : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            trailing()
        }
    }
}
