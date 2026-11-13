import AppKit
import Carbon
import SwiftUI
import UniformTypeIdentifiers

struct VoxleySettings: View {
    @Bindable var controller: DictationController
    let openOnboarding: () -> Void
    let openAbout: () -> Void
    @State private var ruleApp = ""
    @State private var ruleMode = WritingMode.clean

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                settings.tabItem { Label("General", systemImage: "gearshape") }
                modes.tabItem { Label("Modes", systemImage: "slider.horizontal.3") }
                dictionary.tabItem { Label("Dictionary", systemImage: "text.book.closed") }
                VoxleyAbout().tabItem { Label("About", systemImage: "info.circle") }
            }
            if let message = controller.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .frame(width: 590, height: 450)
        .onAppear { controller.refreshPermissions() }
    }

    private var modes: some View {
        Form {
            SwiftUI.Section("Default mode") {
                Picker("Writing mode", selection: $controller.preferences.mode) {
                    ForEach(WritingMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                Text(controller.preferences.mode == .verbatim
                     ? "Keep Apple Speech’s output without an AI rewrite."
                     : controller.preferences.mode.instruction)
                    .foregroundStyle(.secondary)
            }
            SwiftUI.Section("Modes by app") {
                Text("Set a different mode for apps you dictate into. These rules use an app’s bundle identifier.")
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("e.g. com.apple.mail", text: $ruleApp)
                        .accessibilityLabel("App bundle identifier")
                    Picker("Mode", selection: $ruleMode) {
                        ForEach(WritingMode.allCases) { Text($0.rawValue).tag($0) }
                    }.labelsHidden()
                    Button("Choose App…") { chooseApp() }
                    Button("Add") {
                        controller.preferences.appModes[ruleApp.trimmingCharacters(in: .whitespacesAndNewlines)] = ruleMode
                        ruleApp = ""
                    }.disabled(ruleApp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ForEach(controller.preferences.appModes.keys.sorted(), id: \.self) { id in
                    LabeledContent(id) {
                        Text(controller.preferences.appModes[id]?.rawValue ?? "")
                        Button("Remove", systemImage: "minus.circle") {
                            controller.preferences.appModes.removeValue(forKey: id)
                        }.labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                }
            }
        }.formStyle(.grouped)
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        if panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier {
            ruleApp = id
        }
    }

    private var dictionary: some View {
        Form {
            SwiftUI.Section("Vocabulary") {
                Text("Add names, spellings, or phrases one per line. Voxley sends them as hints to Apple Speech when you dictate.")
                    .foregroundStyle(.secondary)
                TextEditor(text: $controller.preferences.vocabulary)
                    .font(.body).frame(height: 132)
                    .accessibilityLabel("Custom vocabulary")
                let count = controller.preferences.vocabularyEntries.count
                HStack {
                    Button("Import Word List…", action: controller.importWordList)
                        .help("Import a text or CSV file. Separate entries with new lines, commas, semicolons, or tabs.")
                    Spacer()
                    Text("\(min(count, Preferences.vocabularyLimit)) of \(Preferences.vocabularyLimit) hints")
                        .foregroundStyle(.secondary)
                }
                if count > Preferences.vocabularyLimit {
                    Text("Apple Speech uses the first \(Preferences.vocabularyLimit) entries.")
                        .foregroundStyle(.secondary)
                }
            }
            SwiftUI.Section("Replacements") {
                ForEach($controller.preferences.replacements) { $replacement in
                    HStack {
                        TextField("Spoken text", text: $replacement.spoken)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField("Replace with", text: $replacement.written)
                        Button("Remove", systemImage: "minus.circle") {
                            controller.preferences.replacements.removeAll { $0.id == replacement.id }
                        }.labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                }
                Button("Add replacement", systemImage: "plus") {
                    controller.preferences.replacements.append(WordReplacement())
                }
            }
        }.formStyle(.grouped)
    }

    private var settings: some View {
        Form {
            SwiftUI.Section("Dictation") {
                ShortcutRecorder(controller: controller)
                Button("Voxley Onboarding…", action: openOnboarding)
                Text("Tap to start or stop. Hold to speak, then release to finish.")
                    .foregroundStyle(.secondary)
                Picker("Language", selection: $controller.preferences.locale) {
                    let names = Set(controller.locales.map { $0.identifier(.bcp47) }).union([controller.preferences.locale])
                    ForEach(names.sorted(), id: \.self) { name in
                        Text(Locale.current.localizedString(forIdentifier: name) ?? name).tag(name)
                    }
                }
                Toggle("Save transcript history", isOn: $controller.preferences.retainHistory)
            }
            #if VOXLEY_SPARKLE
            SwiftUI.Section("Updates") {
                Toggle("Automatically install updates", isOn: Binding(
                    get: { VoxleyUpdates.shared.automaticUpdates },
                    set: VoxleyUpdates.shared.setAutomaticUpdates
                ))
                Button("Check for Updates…", action: VoxleyUpdates.shared.check)
                    .disabled(!VoxleyUpdates.shared.canCheck || controller.phase != .idle)
            }
            #endif
            SwiftUI.Section("Models and permissions") {
                LabeledContent("Apple Speech", value: controller.speechReady ? "Supported on this Mac" : "Unavailable")
                LabeledContent("Apple Intelligence", value: controller.modelStatus)
                LabeledContent("Microphone") {
                    if controller.microphoneReady { Text("Allowed") }
                    else { Button("Allow microphone…") { controller.allowMicrophone() } }
                }
                LabeledContent("Automatic Paste") {
                    if controller.accessibilityReady { Text("Allowed") }
                    else { Button("Enable Automatic Paste…") { controller.allowAccessibility() } }
                }
                Button("Refresh status") { controller.refreshPermissions() }
            }
            SwiftUI.Section("Backup") {
                Text("Export settings, app modes, dictionary and transcript history to a JSON file.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Export backup…") { controller.exportBackup() }
                    Button("Restore backup…") { controller.importBackup() }
                }.disabled(controller.phase != .idle)
            }
            SwiftUI.Section("About") {
                Button("About Voxley", action: openAbout)
            }
        }.formStyle(.grouped)
    }
}

struct ShortcutRecorder: View {
    let controller: DictationController
    var windowForRecording: (() -> NSWindow?)? = nil
    @State private var monitor: Any?
    @State private var instruction = "Press your shortcut…"
    @State private var recordingWindow: NSWindow?
    @State private var candidate: Shortcut?
    @State private var modifierCapture = ModifierChordCapture()
    @State private var anchor = NSView()

    var body: some View {
        HStack {
            Text("Keyboard shortcut")
            Spacer()
            if monitor == nil {
                Text(controller.preferences.shortcutKey.label)
                    .monospaced()
                Button("Record Shortcut…", action: begin)
                    .disabled(controller.phase != .idle)
            } else {
                Text(instruction).foregroundStyle(.secondary)
                Button("Cancel") { finish(nil) }
            }
        }
        .background(ShortcutWindowAnchor(view: anchor))
        .onDisappear { if monitor != nil { finish(nil) } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { event in
            if monitor != nil, event.object as? NSWindow === recordingWindow { finish(nil) }
        }
    }

    private func begin() {
        guard let window = windowForRecording?() ?? anchor.window ?? NSApp.keyWindow else {
            controller.message = "Click inside the Voxley window and try Record Shortcut again."
            return
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        recordingWindow = window
        instruction = "Hold the keys together…"
        candidate = nil
        modifierCapture = ModifierChordCapture()
        controller.beginShortcutRecording()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            guard (event.window ?? NSApp.keyWindow) === window else { return event }
            switch event.type {
            case .flagsChanged:
                recordModifiers(event.modifierFlags)
            case .keyDown:
                if !event.isARepeat {
                    modifierCapture.ordinaryKeyDown()
                    recordKeyDown(event)
                }
            case .keyUp:
                if let candidate, candidate.code == UInt32(event.keyCode) { finish(candidate) }
            default: break
            }
            return nil
        }
        if monitor == nil {
            recordingWindow = nil
            controller.cancelShortcutRecording()
            controller.message = "Couldn’t start shortcut capture. Try again."
        }
    }

    private func recordModifiers(_ flags: NSEvent.ModifierFlags) {
        guard candidate == nil else { return }
        let held = Shortcut.chordModifiers(for: flags)
        if let recorded = modifierCapture.modifiersChanged(held) {
            finish(recorded)
        } else if let modifierChord = modifierCapture.pending {
            instruction = "\(modifierChord.label)  Release to save or press another key"
        } else if held != 0 {
            instruction = "\(Shortcut.modifierLabel(for: flags))  Hold another key"
        }
    }

    private func recordKeyDown(_ event: NSEvent) {
        if event.keyCode == kVK_Escape, Shortcut.modifierLabel(for: event.modifierFlags).isEmpty {
            finish(nil)
        } else if candidate == nil {
            guard let shortcut = Shortcut(event: event) else {
                instruction = "Add a modifier or use a function key."
                return
            }
            guard !shortcut.isStandardEditingShortcut else {
                instruction = "\(shortcut.label) is reserved for editing. Try another."
                return
            }
            candidate = shortcut
            instruction = "\(shortcut.label)  Release to save"
        }
    }

    private func finish(_ shortcut: Shortcut?) {
        if let shortcut, !controller.saveRecordedShortcut(shortcut) {
            candidate = nil
            instruction = "\(shortcut.label) is unavailable. Try another."
            return
        }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recordingWindow = nil
        candidate = nil
        if shortcut == nil { controller.cancelShortcutRecording() }
    }
}

private struct ShortcutWindowAnchor: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ view: NSView, context: Context) {}
}
