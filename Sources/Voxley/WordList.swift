import Foundation

enum WordList {
    enum ImportError: LocalizedError {
        case empty, invalidQuotes
        case overLimit(newEntries: Int, available: Int)

        var errorDescription: String? {
            switch self {
            case .empty:
                "This file doesn’t contain any words or phrases."
            case .invalidQuotes:
                "Check the quotation marks in the word list and try again."
            case .overLimit(let newEntries, let available):
                "This file has \(newEntries) new entries, and \(available) will fit. Shorten the list or remove entries from your vocabulary."
            }
        }
    }

    static func key(for word: String) -> String {
        word.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    static func parse(_ text: String) throws -> [String] {
        var entries: [String] = []
        var field = ""
        var state = FieldState.unquoted
        var index = text.startIndex
        if text.first == "\u{FEFF}" { text.formIndex(after: &index) }

        func finishField() {
            let entry = field.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !entry.isEmpty { entries.append(entry) }
            field.removeAll(keepingCapacity: true)
            state = .unquoted
        }

        while index < text.endIndex {
            let character = text[index]
            text.formIndex(after: &index)
            if state == .quoted {
                if character != "\"" {
                    field.append(character)
                } else if index < text.endIndex, text[index] == "\"" {
                    field.append("\"")
                    text.formIndex(after: &index)
                } else {
                    state = .closedQuote
                }
            } else if character.isNewline || character == "," || character == ";" || character == "\t" {
                finishField()
            } else if state == .closedQuote {
                guard character.isWhitespace else { throw ImportError.invalidQuotes }
            } else if character == "\"", field.allSatisfy(\.isWhitespace) {
                state = .quoted
                field.removeAll(keepingCapacity: true)
            } else {
                field.append(character)
            }
        }
        guard state != .quoted else { throw ImportError.invalidQuotes }
        finishField()
        return entries
    }

    private enum FieldState { case unquoted, quoted, closedQuote }
}
