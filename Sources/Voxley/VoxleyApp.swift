import AppKit
import SwiftUI

private let supportURL = URL(string: "https://protomota.com/support?app=voxley")!
private let feedbackURL = URL(string: "https://protomota.com/apps?app=voxley#feedback")!

@main
@MainActor
struct VoxleyApp: App {
    @NSApplicationDelegateAdaptor(VoxleyDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Voxley", systemImage: menuIcon) {
            MenuCommands(controller: delegate.controller, openOnboarding: delegate.openOnboarding,
                         openAbout: delegate.openAbout)
        }

        Settings {
            VoxleySettings(controller: delegate.controller, launchAtLogin: delegate.launchAtLogin,
                           openOnboarding: delegate.openOnboarding, openAbout: delegate.openAbout)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Voxley", action: delegate.openAbout)
            }
            CommandGroup(after: .appInfo) {
                Button("Voxley Onboarding…", action: delegate.openOnboarding)
            }
            CommandGroup(after: .help) {
                Button("Get App Help") { NSWorkspace.shared.open(supportURL) }
                Button("Send Feedback…") { NSWorkspace.shared.open(feedbackURL) }
            }
        }
    }

    private var menuIcon: String {
        if delegate.controller.phase == .recording { return "mic.fill" }
        return delegate.controller.pasteNeedsAttention ? "exclamationmark.circle" : "waveform"
    }
}

@MainActor
final class VoxleyDelegate: NSObject, NSApplicationDelegate {
    let controller = DictationController()
    let launchAtLogin = LaunchAtLogin()
    private let recorder = RecorderPanel()
    private let setup = SetupWindow()
    private let about = AboutWindow()

    func applicationDidFinishLaunching(_ notification: Notification) {
        launchAtLogin.configureDefault()
        controller.activate()
        recorder.connect(controller)
        #if VOXLEY_SPARKLE
        VoxleyUpdates.shared.start(dictation: controller)
        #endif
        if CommandLine.arguments.contains("--onboarding") ||
            !UserDefaults.standard.bool(forKey: "didCompleteVoxleySetup") {
            openOnboarding()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        launchAtLogin.refresh()
        controller.refreshPermissions()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openOnboarding()
        return true
    }

    func openOnboarding() {
        // Let the menu finish closing before asking AppKit to activate the window.
        DispatchQueue.main.async { self.setup.show(self.controller) }
    }

    func openAbout() { DispatchQueue.main.async { self.about.show() } }
}

private struct MenuCommands: View {
    let controller: DictationController
    let openOnboarding: () -> Void
    let openAbout: () -> Void
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Voxley Onboarding…", action: openOnboarding)
        Divider()
        Text("Tap or hold \(controller.preferences.shortcutKey.label) to dictate")

        if controller.phase == .recording || controller.phase == .preparing {
            Button("Cancel Dictation") { controller.cancel() }
        }
        if let transcript = controller.mostRecentTranscript {
            Button("Copy Last Transcript") { Destination.copy(transcript.text) }
        }
        if let message = controller.message {
            Text(message)
        }
        if controller.pasteNeedsAttention, !controller.accessibilityReady {
            Button("Enable Automatic Paste…") { controller.allowAccessibility() }
        }
        if !controller.shortcutReady {
            Text("Choose an available shortcut in Voxley Onboarding.")
        }
        Divider()
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")

        #if VOXLEY_SPARKLE
        Button("Check for Updates…", action: VoxleyUpdates.shared.check)
            .disabled(!VoxleyUpdates.shared.canCheck || controller.phase != .idle)
        #endif
        Button("About Voxley", action: openAbout)
        Button("Get App Help") { NSWorkspace.shared.open(supportURL) }
        Button("Send Feedback…") { NSWorkspace.shared.open(feedbackURL) }
        Button("Quit Voxley") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
