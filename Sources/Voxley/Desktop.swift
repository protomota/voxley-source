import AppKit
import ApplicationServices
import Carbon


@MainActor
final class GlobalShortcut {
    var onEvent: ((Bool, TimeInterval) -> Void)?
    var onInterrupted: (() -> Void)?
    private var handler: EventHandlerRef?
    private var hotkey: EventHotKeyRef?
    private var registration: Shortcut?
    private var nextID: UInt32 = 0
    private var activeID: UInt32?
    private var down = false
    private var modifierTap: CFMachPort?
    private var modifierSource: CFRunLoopSource?
    private var lastModifiers: UInt32 = 0
    private var modifierPressTime: TimeInterval?
    private var modifierDelay: Task<Void, Never>?

    func register(_ shortcut: Shortcut) -> Bool {
        guard !shortcut.isStandardEditingShortcut else { return false }
        if let registration, registration.code == shortcut.code, registration.modifiers == shortcut.modifiers,
           !shortcut.isModifierOnly || modifierTap.map(CGEvent.tapIsEnabled) == true {
            return true
        }
        if shortcut.isModifierOnly { return registerModifierChord(shortcut) }
        guard let dispatcher = GetEventDispatcherTarget() else { return false }
        if handler == nil {
            var events = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed)),
                          EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyReleased))]
            let result = InstallEventHandler(dispatcher, shortcutCallback, events.count, &events,
                                             Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard result == noErr else { return false }
        }
        nextID &+= 1
        let id = EventHotKeyID(signature: 0x56584C59, id: nextID)
        var newHotkey: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.code, shortcut.modifiers, id, dispatcher,
                                         UInt32(kEventHotKeyExclusive), &newHotkey)
        guard status == noErr, let newHotkey else { return false }
        suspend()
        hotkey = newHotkey
        registration = shortcut
        activeID = id.id
        return true
    }

    func suspend() {
        if let hotkey { UnregisterEventHotKey(hotkey) }
        hotkey = nil
        registration = nil
        activeID = nil
        down = false
        modifierDelay?.cancel()
        modifierDelay = nil
        modifierPressTime = nil
        lastModifiers = 0
        if let modifierSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), modifierSource, .commonModes) }
        if let modifierTap { CFMachPortInvalidate(modifierTap) }
        modifierSource = nil
        modifierTap = nil
    }

    func receive(_ pressed: Bool, at time: TimeInterval, id: UInt32) {
        guard id == activeID, pressed != down else { return }
        down = pressed
        onEvent?(pressed, time)
    }

    private func registerModifierChord(_ shortcut: Shortcut) -> Bool {
        let events: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: events, callback: modifierShortcutCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        suspend()
        registration = shortcut
        modifierTap = tap
        modifierSource = source
        lastModifiers = Shortcut.chordModifiers(for: NSEvent.modifierFlags)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func receiveModifierEvent(_ type: CGEventType, modifiers: UInt32, at time: TimeInterval) {
        guard let modifierTap, let registration, registration.isModifierOnly else { return }
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            interruptModifierPress()
            lastModifiers = Shortcut.chordModifiers(for: NSEvent.modifierFlags)
            CGEvent.tapEnable(tap: modifierTap, enable: true)
        case .keyDown:
            // A modifier chord used as the prefix of another shortcut should type normally.
            interruptModifierPress()
        case .flagsChanged:
            let required = registration.modifiers
            let previouslyHeld = lastModifiers & required == required
            lastModifiers = modifiers
            if modifiers == required, !previouslyHeld {
                modifierPressTime = time
                modifierDelay = Task { [weak self] in
                    // Wait briefly to distinguish the chord from a longer key combination.
                    do { try await Task.sleep(for: .milliseconds(120)) }
                    catch { return }
                    guard let self, self.modifierPressTime == time else { return }
                    self.down = true
                    self.onEvent?(true, time)
                }
            } else if modifiers & required != required, let pressTime = modifierPressTime {
                modifierPressTime = nil
                modifierDelay?.cancel()
                modifierDelay = nil
                if !down { onEvent?(true, pressTime) }
                down = false
                onEvent?(false, time)
            } else if modifiers != required {
                interruptModifierPress()
            }
        default: break
        }
    }

    private func interruptModifierPress() {
        modifierDelay?.cancel()
        modifierDelay = nil
        modifierPressTime = nil
        if down {
            down = false
            onInterrupted?()
        }
    }
}

private func modifierShortcutCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                                      _ context: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let context {
        let shortcut = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
        let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        let modifiers = Shortcut.chordModifiers(for: flags)
        let time = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async { shortcut.receiveModifierEvent(type, modifiers: modifiers, at: time) }
    }
    return Unmanaged.passUnretained(event)
}

private func shortcutCallback(_ handler: EventHandlerCallRef?, _ event: EventRef?,
                              _ context: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let context else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    guard GetEventParameter(event, OSType(kEventParamDirectObject), OSType(typeEventHotKeyID), nil,
                            MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
          id.signature == 0x56584C59 else { return OSStatus(eventNotHandledErr) }
    let shortcut = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
    let pressed = GetEventKind(event) == OSType(kEventHotKeyPressed)
    let registration = id.id
    let time = GetEventTime(event)
    DispatchQueue.main.async { shortcut.receive(pressed, at: time, id: registration) }
    return noErr
}

@MainActor
struct Destination {
    enum Delivery {
        case inserted, pasteRequested, copiedBecausePermissionIsOff, copiedBecauseFocusChanged, copied

        var status: String {
            switch self {
            case .inserted: "Paste confirmed"
            case .pasteRequested: "Paste sent; check the field"
            case .copiedBecausePermissionIsOff: "Automatic paste permission is off"
            case .copiedBecauseFocusChanged: "Focus moved before paste"
            case .copied: "Paste didn’t run"
            }
        }

        var needsAttention: Bool {
            switch self {
            case .inserted, .pasteRequested: false
            default: true
            }
        }

        var message: String? {
            switch self {
            case .inserted: nil
            case .pasteRequested: nil
            case .copiedBecausePermissionIsOff:
                "Transcript copied. Enable Automatic Paste in Voxley Settings to insert it at the cursor."
            case .copiedBecauseFocusChanged:
                "Transcript copied because the original text field lost focus."
            case .copied:
                "Voxley couldn’t insert the transcript. It’s on the clipboard."
            }
        }
    }

    let app: NSRunningApplication?
    let windowFrame: NSRect?
    private let focusedElement: AXUIElement?
    private let focusedWindow: AXUIElement?
    private let elementID: String?
    private weak var practiceWindow: NSWindow?
    private weak var practiceEditor: NSTextView?

    init(practiceWindow: NSWindow? = nil, explicitPractice: Bool = false) {
        let usePractice = practiceWindow?.isVisible == true &&
            (explicitPractice || (NSApp.isActive && NSApp.keyWindow === practiceWindow))
        app = usePractice ? NSRunningApplication.current : NSWorkspace.shared.frontmostApplication
        let isOwnApp = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        if usePractice, let practiceWindow {
            self.practiceWindow = practiceWindow
            practiceEditor = practiceWindow.firstResponder as? NSTextView
        }
        focusedElement = isOwnApp ? nil : app.flatMap { Self.focus(in: $0.processIdentifier) }
        focusedWindow = isOwnApp ? nil : app.flatMap { Self.focusedWindow(in: $0.processIdentifier) }
        elementID = focusedElement.flatMap(Self.identifier(of:))
        windowFrame = self.practiceWindow?.frame ?? app.flatMap { Self.frontWindowFrame(for: $0.processIdentifier) }
    }

    var name: String { app?.localizedName ?? "Dictation" }
    var identifier: String? { app?.bundleIdentifier }
    var isPractice: Bool { practiceWindow != nil }
    var practiceFieldReady: Bool { practiceEditor != nil }

    static func requestAccessibility() {
        if AXIsProcessTrusted(), !CGPreflightPostEventAccess() {
            _ = CGRequestPostEventAccess()
            return
        }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private static func focus(in pid: pid_t) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        if let focus = focusedElement(of: app) { return focus }
        guard let focus = focusedElement(of: AXUIElementCreateSystemWide()) else { return nil }
        var owner: pid_t = 0
        return AXUIElementGetPid(focus, &owner) == .success && owner == pid ? focus : nil
    }

    private static func focusedElement(of parent: AXUIElement) -> AXUIElement? {
        elementAttribute(kAXFocusedUIElementAttribute, of: parent)
    }

    private static func focusedWindow(in pid: pid_t) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        return elementAttribute(kAXFocusedWindowAttribute, of: AXUIElementCreateApplication(pid))
    }

    private static func elementAttribute(_ name: String, of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func identifier(of element: AXUIElement) -> String? {
        guard let id = stringAttribute(kAXIdentifierAttribute, of: element), !id.isEmpty else { return nil }
        return id
    }

    private func stillFocused(in pid: pid_t) -> Bool {
        if pid == ProcessInfo.processInfo.processIdentifier {
            guard let practiceWindow, let practiceEditor else { return false }
            return practiceWindow.isVisible && practiceWindow.firstResponder === practiceEditor
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        if let focusedWindow, Self.focusedWindow(in: pid).map({ CFEqual(focusedWindow, $0) }) != true {
            return false
        }
        if focusedWindow == nil, let windowFrame, Self.frontWindowFrame(for: pid) != windowFrame {
            return false
        }
        let current = Self.focus(in: pid)
        if let current, Self.stringAttribute(kAXSubroleAttribute, of: current) == kAXSecureTextFieldSubrole {
            return false
        }
        guard let focusedElement else { return true }
        guard let current else { return false }
        if CFEqual(focusedElement, current) { return true }
        // A web editor can rebuild its accessibility element while leaving the same field focused.
        return focusedWindow != nil && elementID != nil && elementID == Self.identifier(of: current)
    }

    private static func frontWindowFrame(for pid: pid_t) -> NSRect? {
        guard let primaryTop = NSScreen.screens.first?.frame.maxY,
              let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
              ) as? [[String: Any]] else { return nil }
        for window in windows where window[kCGWindowOwnerPID as String] as? pid_t == pid {
            guard window[kCGWindowLayer as String] as? Int == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.width >= 80, frame.height >= 80 else { continue }
            return NSRect(x: frame.minX, y: primaryTop - frame.maxY, width: frame.width, height: frame.height)
        }
        return nil
    }

    static func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }

    func deliver(_ text: String) async -> Delivery {
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            Self.copy(text)
            return .copiedBecausePermissionIsOff
        }
        guard let pid = app?.processIdentifier, stillFocused(in: pid) else {
            Self.copy(text)
            return .copiedBecauseFocusChanged
        }
        guard let source = CGEventSource(stateID: .privateState),
              let commandDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: true),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false),
              let commandUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: false) else {
            Self.copy(text)
            return .copied
        }

        let board = NSPasteboard.general
        let prior = (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        board.clearContents()
        guard board.setString(text, forType: .string) else { return .copied }
        let expectedCount = board.changeCount
        // Give the shortcut modifiers and clipboard time to settle before delivering Cmd+V.
        try? await Task.sleep(for: .milliseconds(85))
        guard board.changeCount == expectedCount else { return .copied }
        guard !Task.isCancelled, stillFocused(in: pid) else { return .copiedBecauseFocusChanged }
        let originalSelection = selectedRange(in: pid)

        if let practiceEditor {
            // The local practice editor can handle its own standard Paste action.
            practiceEditor.paste(nil)
        } else {
            commandDown.flags = .maskCommand
            down.flags = .maskCommand
            up.flags = .maskCommand
            commandUp.flags = []
            commandDown.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(12))
            guard !Task.isCancelled, board.changeCount == expectedCount, stillFocused(in: pid) else {
                commandUp.post(tap: .cghidEventTap)
                return .copiedBecauseFocusChanged
            }
            down.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(12))
            up.post(tap: .cghidEventTap)
            commandUp.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(550))
        }

        guard stillFocused(in: pid), let originalSelection, let updated = selectedRange(in: pid),
              updated.length == 0, updated.location == originalSelection.location + text.utf16.count else {
            return .pasteRequested
        }
        if board.changeCount == expectedCount {
            board.clearContents()
            let restored: [NSPasteboardItem] = prior.compactMap { values in
                guard !values.isEmpty else { return nil }
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            if !restored.isEmpty { board.writeObjects(restored) }
        }
        return .inserted
    }

    private func selectedRange(in pid: pid_t) -> CFRange? {
        if let practiceEditor {
            let range = practiceEditor.selectedRange()
            return CFRange(location: range.location, length: range.length)
        }
        return Self.focus(in: pid).flatMap(Self.selectedRange)
    }

    private static func selectedRange(_ element: AXUIElement) -> CFRange? {
        var attribute: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &attribute) == .success,
              let attribute, CFGetTypeID(attribute) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(attribute as! AXValue, .cfRange, &range) ? range : nil
    }
}
