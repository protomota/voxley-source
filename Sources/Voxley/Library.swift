import Foundation

struct Transcript: Codable, Identifiable, Sendable {
    var id = UUID()
    var date = Date()
    var original: String
    var text: String
    var source: String
    var mode: WritingMode
}

enum WritingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case verbatim = "Verbatim"
    case clean = "Clean up"
    case notes = "Notes"
    case email = "Email"

    var id: Self { self }

    var instruction: String {
        switch self {
        case .verbatim: ""
        case .clean: "Remove obvious filler, fix punctuation and casing, and preserve the original meaning and voice."
        case .notes: "Turn the dictation into concise notes. Use bullets where helpful. Preserve all facts, names, and action items."
        case .email: "Format the dictation as a clear email body. Keep the tone and facts; do not invent a subject, greeting, or signature."
        }
    }
}

struct WordReplacement: Codable, Identifiable, Sendable {
    var id = UUID()
    var spoken = ""
    var written = ""
}

struct Preferences: Codable, Sendable {
    static let vocabularyLimit = 100

    var locale = "en-US"
    var mode = WritingMode.verbatim
    var shortcutKey = Shortcut.controlShiftSpace
    var retainHistory = true
    var vocabulary = ""
    var replacements: [WordReplacement] = []
    var appModes: [String: WritingMode] = [:]

    var vocabularyEntries: [String] {
        var seen = Set<String>()
        return vocabulary.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert(WordList.key(for: $0)).inserted }
    }

    var contextWords: [String] { Array(vocabularyEntries.prefix(Self.vocabularyLimit)) }

    mutating func importVocabulary(_ text: String) throws -> Int {
        let existing = vocabularyEntries
        var seen = Set(existing.map(WordList.key))
        let entries = try WordList.parse(text)
        guard !entries.isEmpty else { throw WordList.ImportError.empty }
        let additions = entries.filter { seen.insert(WordList.key(for: $0)).inserted }
        guard !additions.isEmpty else { return 0 }
        let available = max(0, Self.vocabularyLimit - existing.count)
        guard additions.count <= available else {
            throw WordList.ImportError.overLimit(newEntries: additions.count, available: available)
        }
        if !vocabulary.isEmpty, vocabulary.last?.isNewline != true { vocabulary += "\n" }
        vocabulary += additions.joined(separator: "\n")
        return additions.count
    }

    func applyingReplacements(to input: String) -> String {
        replacements.reduce(input) { result, rule in
            let word = rule.spoken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { return result }
            let pattern = "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: word)
                + "(?![\\p{L}\\p{N}_])"
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return result
            }
            return expression.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: rule.written)
            )
        }
    }
}

struct Library: Codable, Sendable {
    static let currentVersion = 1
    var version = currentVersion
    var preferences = Preferences()
    var history: [Transcript] = []

    static func read(_ url: URL) throws -> Library {
        let data = try Data(contentsOf: url)
        let library = try JSONDecoder().decode(Library.self, from: data)
        guard library.version == currentVersion else { throw VoxleyError.backupVersion }
        return library
    }

    func write(_ url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    mutating func restore(_ backup: Library) {
        preferences = backup.preferences
        var seen = Set(history.map(\.id))
        history.append(contentsOf: backup.history.filter { seen.insert($0.id).inserted })
        history.sort { $0.date > $1.date }
    }
}

enum VoxleyError: LocalizedError {
    case backupVersion, microphone, microphoneInput, speechUnavailable, unsupportedLocale, emptyAudio, noSpeech
    case audioOverrun

    var errorDescription: String? {
        switch self {
        case .backupVersion: "This backup was created by a different version of Voxley."
        case .microphone: "Allow Voxley in System Settings → Privacy & Security → Microphone to dictate."
        case .microphoneInput: "Voxley could not start the microphone. Check your input device in Sound settings."
        case .speechUnavailable: "Apple Speech transcription is unavailable on this Mac."
        case .unsupportedLocale: "Apple Speech does not support that dictation language on this Mac."
        case .emptyAudio: "No audio was captured. Hold the shortcut a little longer and try again."
        case .noSpeech: "Apple Speech did not detect any words."
        case .audioOverrun: "The speech model could not keep up with the microphone."
        }
    }
}
