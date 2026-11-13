import AppKit
import Carbon

struct Shortcut: Codable, Equatable, Sendable {
    let code: UInt32
    let modifiers: UInt32
    let keyLabel: String

    static let controlShiftSpace = Shortcut(
        code: UInt32(kVK_Space), modifiers: UInt32(controlKey | shiftKey), keyLabel: "Space"
    )

    // A modifier chord has no ordinary key code. Existing shortcut files keep their format.
    private static let modifierOnlyCode = UInt32.max
    private static let functionModifier: UInt32 = 1 << 24
    var isModifierOnly: Bool { code == Self.modifierOnlyCode }

    init?(modifierChord: UInt32) {
        guard modifierChord.nonzeroBitCount >= 2 else { return nil }
        self.init(code: Self.modifierOnlyCode, modifiers: modifierChord, keyLabel: "")
    }

    var label: String {
        Self.modifierLabel(modifiers) + keyLabel
    }

    private static func modifierLabel(_ modifiers: UInt32) -> String {
        let symbols = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
        let standard = symbols.compactMap { modifiers & UInt32($0.0) == 0 ? nil : $0.1 }.joined()
        return standard + (modifiers & functionModifier == 0 ? "" : "Fn")
    }

    static func modifierLabel(for flags: NSEvent.ModifierFlags) -> String {
        modifierLabel(chordModifiers(for: flags))
    }

    static func carbonModifiers(for flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        return modifiers
    }

    static func chordModifiers(for flags: NSEvent.ModifierFlags) -> UInt32 {
        carbonModifiers(for: flags) | (flags.contains(.function) ? functionModifier : 0)
    }

    var isStandardEditingShortcut: Bool {
        switch Int(code) {
        case kVK_ANSI_Z:
            modifiers == UInt32(cmdKey) || modifiers == UInt32(cmdKey | shiftKey)
        case kVK_ANSI_A, kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_X:
            modifiers == UInt32(cmdKey)
        default:
            false
        }
    }

    init(code: UInt32, modifiers: UInt32, keyLabel: String) {
        self.code = code
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    init(from decoder: Decoder) throws {
        if let old = try? decoder.singleValueContainer().decode(String.self) {
            switch old {
            case "⌃⇧Space": self = .controlShiftSpace
            case "⌃⌥D": self.init(code: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | optionKey), keyLabel: "D")
            case "F9": self.init(code: UInt32(kVK_F9), modifiers: 0, keyLabel: "F9")
            default:
                throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(),
                                                       debugDescription: "Unknown legacy shortcut")
            }
            return
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(code: try values.decode(UInt32.self, forKey: .code),
                  modifiers: try values.decode(UInt32.self, forKey: .modifiers),
                  keyLabel: try values.decode(String.self, forKey: .keyLabel))
    }

    @MainActor
    init?(event: NSEvent) {
        let modifiers = Self.carbonModifiers(for: event.modifierFlags)

        let code = Int(event.keyCode)
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        let functionKey = functionKeys.firstIndex(of: code)
        guard modifiers != 0 || functionKey != nil else { return nil }
        let specialKeys = [
            kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab", kVK_Delete: "Delete",
            kVK_ForwardDelete: "Forward Delete", kVK_Escape: "Esc", kVK_Home: "Home", kVK_End: "End",
            kVK_PageUp: "Page Up", kVK_PageDown: "Page Down", kVK_LeftArrow: "←", kVK_RightArrow: "→",
            kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_ANSI_KeypadEnter: "Enter"
        ]
        let characters = event.charactersIgnoringModifiers.flatMap { characters in
            characters.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) ? nil : characters.uppercased()
        }
        let name = functionKey.map { "F\($0 + 1)" } ?? specialKeys[code] ?? characters ?? "Key \(code)"
        self.init(code: UInt32(code), modifiers: modifiers, keyLabel: name.isEmpty ? "Key \(code)" : name)
    }
}

struct ModifierChordCapture {
    private var peak: UInt32 = 0
    private var usedOrdinaryKey = false

    var pending: Shortcut? { Shortcut(modifierChord: peak) }

    mutating func ordinaryKeyDown() {
        usedOrdinaryKey = true
        peak = 0
    }

    mutating func modifiersChanged(_ held: UInt32) -> Shortcut? {
        if held == 0 {
            let recorded = pending
            self = Self()
            return recorded
        }
        if !usedOrdinaryKey, held.nonzeroBitCount >= peak.nonzeroBitCount { peak = held }
        return nil
    }
}

struct DictationShortcutGesture {
    enum Action: Equatable {
        case start, stop, none
    }

    static let holdThreshold: TimeInterval = 0.30
    private var press: (time: TimeInterval, startedRecording: Bool)?

    mutating func interrupt() -> Bool {
        let started = press?.startedRecording == true
        press = nil
        return started
    }

    mutating func update(pressed: Bool, time: TimeInterval, canStart: Bool, isRecording: Bool) -> Action {
        if pressed {
            guard press == nil, canStart || isRecording else { return .none }
            press = (time, canStart)
            return canStart ? .start : .none
        }
        guard let press else { return .none }
        self.press = nil
        guard isRecording else { return .none }
        if !press.startedRecording || time - press.time >= Self.holdThreshold {
            return .stop
        }
        return .none
    }
}
