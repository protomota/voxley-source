import AppKit
import Foundation
import Testing
@testable import Voxley

@Test func wordListMergesDelimitedPhrasesWithManualVocabulary() throws {
    var preferences = Preferences()
    preferences.vocabulary = "Voxley\n"
    let added = try preferences.importVocabulary("\u{FEFF}voxley, Protomota Lab\r\nInkspring; \"Acme, Inc.\"\tinkSpring")

    #expect(added == 3)
    #expect(preferences.contextWords == ["Voxley", "Protomota Lab", "Inkspring", "Acme, Inc."])
}

@Test func wordListDoesNotChangeVocabularyWhenImportFails() throws {
    var preferences = Preferences()
    preferences.vocabulary = (1..<Preferences.vocabularyLimit).map { "Word \($0)" }.joined(separator: "\n")
    let original = preferences.vocabulary
    do {
        _ = try preferences.importVocabulary("Protomota, Voxley")
        Issue.record("Expected an import beyond the hint limit to fail")
    } catch WordList.ImportError.overLimit(let newEntries, let available) {
        #expect(newEntries == 2)
        #expect(available == 1)
    }
    #expect(preferences.vocabulary == original)
    #expect(throws: WordList.ImportError.self) { try preferences.importVocabulary("\"Unclosed") }
    #expect(preferences.vocabulary == original)
}

@Test func dictionaryPreservesWordBoundariesAndLiteralReplacement() {
    var preferences = Preferences()
    preferences.replacements = [WordReplacement(spoken: "ink", written: "$Ink")]
    #expect(preferences.applyingReplacements(to: "INK, Inkspring, ink. Think.") == "$Ink, Inkspring, $Ink. Think.")
}

@Test func backupRestoresPreferencesWithoutDuplicatingHistory() throws {
    let entry = Transcript(original: "hi", text: "Hi.", source: "Notes", mode: .clean)
    var backup = Library()
    backup.history = [entry]
    backup.preferences.appModes["com.apple.mail"] = .email
    let encoded = try JSONEncoder().encode(backup)
    let decoded = try JSONDecoder().decode(Library.self, from: encoded)
    var local = Library()
    let localEntry = Transcript(original: "test", text: "test", source: "Mail", mode: .verbatim)
    local.history = [localEntry]
    local.restore(decoded)
    local.restore(decoded)
    #expect(Set(local.history.map(\.id)) == [entry.id, localEntry.id])
    #expect(local.history.count == 2)
    #expect(local.preferences.appModes["com.apple.mail"] == .email)
}

@Test func transcriptJoinsPunctuationAndSeparatesWords() {
    #expect(AppleModels.join("Hello", ", world") == "Hello, world")
    #expect(AppleModels.join("Hello", "world") == "Hello world")
    #expect(AppleModels.join("Hello", " world") == "Hello world")
}

@Test func quickTapsStartAndStopWithoutWaitingForSpeechSetup() {
    var gesture = DictationShortcutGesture()
    #expect(gesture.update(pressed: true, time: 0, canStart: true, isRecording: false) == .start)
    #expect(gesture.update(pressed: false, time: 0.12, canStart: false, isRecording: true) == .none)
    #expect(gesture.update(pressed: true, time: 0.50, canStart: false, isRecording: true) == .none)
    #expect(gesture.update(pressed: false, time: 0.59, canStart: false, isRecording: true) == .stop)
}

@Test func heldShortcutStopsOnReleaseAndIgnoresDuplicatePresses() {
    var gesture = DictationShortcutGesture()
    #expect(gesture.update(pressed: true, time: 0, canStart: true, isRecording: false) == .start)
    #expect(gesture.update(pressed: true, time: 0.4, canStart: false, isRecording: true) == .none)
    #expect(gesture.update(pressed: false, time: 0.6, canStart: false, isRecording: true) == .stop)
    #expect(gesture.update(pressed: false, time: 0.7, canStart: false, isRecording: false) == .none)
}

@Test func shortcutDecodesExistingPreferencesAndRoundTripsCustomKeys() throws {
    let decoder = JSONDecoder()
    let legacy = try decoder.decode(Shortcut.self, from: Data("\"⌃⇧Space\"".utf8))
    #expect(legacy == .controlShiftSpace)
    let custom = Shortcut(code: 40, modifiers: 0x900, keyLabel: "K")
    let encoded = try JSONEncoder().encode(custom)
    #expect(try decoder.decode(Shortcut.self, from: encoded) == custom)
    #expect(custom.label == "⌥⌘K")
}

@Test func modifierChordKeepsBothKeysUntilTheLastRelease() throws {
    let control = Shortcut.chordModifiers(for: .control)
    let both = Shortcut.chordModifiers(for: [.control, .option])
    let option = Shortcut.chordModifiers(for: .option)
    var capture = ModifierChordCapture()
    #expect(capture.modifiersChanged(control) == nil)
    #expect(capture.modifiersChanged(both) == nil)
    #expect(capture.modifiersChanged(option) == nil)
    let result = capture.modifiersChanged(0)
    let saved = try #require(result)
    #expect(saved.isModifierOnly)
    #expect(saved.label == "⌃⌥")
    #expect(try JSONDecoder().decode(Shortcut.self, from: JSONEncoder().encode(saved)) == saved)

    _ = capture.modifiersChanged(both)
    capture.ordinaryKeyDown()
    #expect(capture.modifiersChanged(0) == nil)
}
