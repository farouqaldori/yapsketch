import AppKit
import Carbon

/// A global shortcut you can change in Settings, stored as `shortcut.<action>`.
enum ShortcutAction: String, CaseIterable, Identifiable {
    case record, draw, clear, dictate
    var id: String { rawValue }

    var title: String {
        switch self {
        case .record: "Start / stop recording"
        case .draw: "Draw on screen"
        case .clear: "Clear drawings"
        case .dictate: "Dictate"
        }
    }

    var standard: Shortcut {
        switch self {
        case .record: Shortcut(keyCode: kVK_ANSI_R, modifiers: controlKey | optionKey)
        case .draw: Shortcut(keyCode: kVK_ANSI_D, modifiers: controlKey | optionKey)
        case .clear: Shortcut(keyCode: kVK_ANSI_X, modifiers: controlKey | optionKey)
        case .dictate: .fn
        }
    }
}

/// A key with Carbon modifiers (what RegisterEventHotKey takes), or fn on its own.
struct Shortcut: Codable, Equatable {
    let keyCode: Int
    let modifiers: Int

    /// Holding fn (🌐): not a Carbon hotkey, `FnKey` listens for it. Dictation only.
    static let fn = Shortcut(keyCode: kVK_Function, modifiers: 0)
    var isFn: Bool { self == .fn }

    /// "⌃⌥R": the modifiers in the system's order, then the key.
    var display: String { modifierSymbols + keyName }

    var modifierSymbols: String {
        var s = ""
        if modifiers & controlKey != 0 { s += "⌃" }
        if modifiers & optionKey != 0 { s += "⌥" }
        if modifiers & shiftKey != 0 { s += "⇧" }
        if modifiers & cmdKey != 0 { s += "⌘" }
        return s
    }

    var keyName: String {
        if let special = Self.special[keyCode] { return special }
        return Self.character(for: keyCode)?.uppercased() ?? "#\(keyCode)"
    }

    var menuKey: String { Self.special[keyCode] == nil ? (Self.character(for: keyCode) ?? "") : "" }
    var menuModifiers: NSEvent.ModifierFlags {
        var m: NSEvent.ModifierFlags = []
        if modifiers & controlKey != 0 { m.insert(.control) }
        if modifiers & optionKey != 0 { m.insert(.option) }
        if modifiers & shiftKey != 0 { m.insert(.shift) }
        if modifiers & cmdKey != 0 { m.insert(.command) }
        return m
    }

    init?(event: NSEvent) {
        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var m = 0
        if f.contains(.control) { m |= controlKey }
        if f.contains(.option) { m |= optionKey }
        if f.contains(.shift) { m |= shiftKey }
        if f.contains(.command) { m |= cmdKey }
        // A global shortcut needs ⌃, ⌥ or ⌘ (⇧ alone would take a letter from typing), or is an
        // F-key, which types nothing on its own.
        guard m & (controlKey | optionKey | cmdKey) != 0 || Self.functionKeys.contains(Int(event.keyCode)) else { return nil }
        self.init(keyCode: Int(event.keyCode), modifiers: m)
    }

    init(keyCode: Int, modifiers: Int) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// F1 to F20.
    static let functionKeys: Set<Int> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

    private static let special: [Int: String] = [
        63: "fn", 36: "↩", 76: "⌤", 48: "⇥", 49: "Space", 51: "⌫", 117: "⌦", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    /// The character a key types on the current layout, without modifiers.
    private static func character(for keyCode: Int) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}

enum Shortcuts {
    static func get(_ action: ShortcutAction) -> Shortcut {
        guard let data = UserDefaults.standard.data(forKey: "shortcut.\(action.rawValue)"),
            let s = try? JSONDecoder().decode(Shortcut.self, from: data)
        else { return action.standard }
        return s
    }

    /// `nil` goes back to the default.
    static func set(_ action: ShortcutAction, _ shortcut: Shortcut?) {
        if let shortcut, shortcut != action.standard, let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: "shortcut.\(action.rawValue)")
        } else {
            UserDefaults.standard.removeObject(forKey: "shortcut.\(action.rawValue)")
        }
        NotificationCenter.default.post(name: .yapSketchShortcutsChanged, object: nil)
    }

    static func clash(_ shortcut: Shortcut, besides action: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first { $0 != action && get($0) == shortcut }
    }

    /// Actions whose shortcut another app already holds (set by the app when registering).
    nonisolated(unsafe) static var unavailable: Set<ShortcutAction> = []

    /// While a shortcut is being typed in Settings, the hotkeys are off (else typing the
    /// current one would start a recording).
    static func suspend(_ on: Bool) {
        NotificationCenter.default.post(name: .yapSketchShortcutsSuspended, object: on)
    }
}

extension Notification.Name {
    static let yapSketchShortcutsChanged = Notification.Name("yapSketchShortcutsChanged")
    static let yapSketchShortcutsSuspended = Notification.Name("yapSketchShortcutsSuspended")
}
