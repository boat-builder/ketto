import Foundation

/// What the recorder stores about typing. `shortcuts` keeps only key combinations (⌘S, ⇧⌘4, ⏎, arrows); plain
/// typing — which can be a password — is never written to the project unless the user chose `everything`.
enum KeystrokeCaptureMode: String, CaseIterable, Codable, Sendable {
    case off
    case shortcuts
    case everything
}

/// Turns raw key presses into the display form stored in `events.json`: modifier names in lower case and the key
/// as the symbol macOS menus use (`⏎`, `⌫`, `←`, `F5`, `space`) or the typed character in upper case.
enum KeystrokeMapping {
    /// Virtual key codes (Carbon `kVK_…`) that have a symbol rather than a character.
    static let specialKeyCodes: [UInt16: String] = [
        36: "⏎", 76: "⏎", 48: "⇥", 53: "⎋", 51: "⌫", 117: "⌦", 49: "space",
        123: "←", 124: "→", 125: "↓", 126: "↑", 116: "⇞", 121: "⇟", 115: "↖", 119: "↘",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    /// Modifier flag bits as `NSEvent.ModifierFlags` raw values, so this stays Foundation-only.
    struct Modifiers: OptionSet, Sendable {
        let rawValue: UInt
        static let shift = Modifiers(rawValue: 1 << 17)
        static let control = Modifiers(rawValue: 1 << 18)
        static let option = Modifiers(rawValue: 1 << 19)
        static let command = Modifiers(rawValue: 1 << 20)
        static let function = Modifiers(rawValue: 1 << 23)
    }

    /// The display string for a key press, or nil when nothing printable or symbolic was pressed.
    static func displayString(keyCode: UInt16, characters: String?) -> String? {
        if let special = specialKeyCodes[keyCode] { return special }
        guard let characters, let scalar = characters.unicodeScalars.first else { return nil }
        // Control characters (the Private Use Area arrows, dead keys) have no useful display form.
        guard scalar.value >= 0x20, !(0xF700...0xF8FF).contains(scalar.value) else { return nil }
        return characters.uppercased()
    }

    /// Modifier names in the order `KeyEvent` expects. `fn` is only reported for keys that are not function keys
    /// themselves (arrows and F-keys carry the flag on their own).
    static func modifierNames(_ flags: Modifiers, keyCode: UInt16) -> [String] {
        var names: [String] = []
        if flags.contains(.control) { names.append("ctrl") }
        if flags.contains(.option) { names.append("opt") }
        if flags.contains(.shift) { names.append("shift") }
        if flags.contains(.command) { names.append("cmd") }
        if flags.contains(.function), specialKeyCodes[keyCode] == nil { names.append("fn") }
        return names
    }

    /// The key event to store for a press, or nil when the mode says it should not be kept.
    static func keyEvent(t: Double, keyCode: UInt16, characters: String?, flags: Modifiers, mode: KeystrokeCaptureMode) -> KeyEvent? {
        guard mode != .off, let display = displayString(keyCode: keyCode, characters: characters) else { return nil }
        let event = KeyEvent(t: t, chars: display, modifiers: modifierNames(flags, keyCode: keyCode))
        if mode == .shortcuts, !event.isShortcut { return nil }
        return event
    }
}
