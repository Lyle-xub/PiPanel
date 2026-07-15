import AppKit

/// A single global keyboard shortcut — currently just "gather all open PiP panels into a stack"
/// (PiPSessionManager.stackAllSessions, triggered via GlobalHotkeyManager), but kept as its own
/// small value type rather than two loose UserDefaults values so SettingsStore, the recorder UI,
/// and the monitor that matches live NSEvents against it all share one definition of equality and
/// display formatting.
struct GlobalShortcut: Equatable {
    var keyCode: UInt16
    var modifierFlags: NSEvent.ModifierFlags

    /// The only modifier keys a shortcut is ever compared on. NSEvent.modifierFlags also carries
    /// incidental bits (.function, .numericPad, .help, etc. — commonly set by laptop Fn/arrow/media
    /// keys) that have nothing to do with what the user actually recorded; intersecting a live
    /// event's flags with this mask before comparing is what keeps one of those from silently
    /// making an otherwise-matching combination fail to match.
    static let relevantModifierMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    var displayString: String {
        var parts = ""
        if modifierFlags.contains(.control) { parts += "⌃" }
        if modifierFlags.contains(.option) { parts += "⌥" }
        if modifierFlags.contains(.shift) { parts += "⇧" }
        if modifierFlags.contains(.command) { parts += "⌘" }
        parts += Self.keyCodeDisplayNames[keyCode] ?? "?"
        return parts
    }

    /// Virtual key codes describe a physical key position, not a layout-aware character — the same
    /// approach every other macOS global-shortcut recorder uses (System Settings' own included),
    /// since a global shortcut has to keep working regardless of which app, and therefore which
    /// input context, is currently frontmost. Covers what's realistic to record as a global
    /// shortcut (letters, digits, function/arrow keys), not an exhaustive keyboard map.
    private static let keyCodeDisplayNames: [UInt16: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J",
        40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T",
        32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12"
    ]
}
