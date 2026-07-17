import AppKit

/// Hex-string round-tripping for the appearance settings that store colors as plain "RRGGBB"
/// strings (SettingsStore.panelBackgroundColorHex and friends) rather than an archived NSColor —
/// keeps UserDefaults storage human-readable and matches the plain-value convention every other
/// setting in this app already follows.
extension NSColor {
    /// Accepts "RRGGBB" or "#RRGGBB" (case-insensitive, whitespace-trimmed). Returns nil for
    /// anything else so callers can fall back to a known-good default instead of silently
    /// rendering black or some other wrong color for malformed input (e.g. a user mid-edit in a
    /// settings text field).
    convenience init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
        let red = CGFloat((rgb >> 16) & 0xFF) / 255
        let green = CGFloat((rgb >> 8) & 0xFF) / 255
        let blue = CGFloat(rgb & 0xFF) / 255
        self.init(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    /// Always 6 hex digits, no leading "#" — the canonical form stored in SettingsStore/
    /// UserDefaults and shown back in HexColorField's text field.
    var hexString: String {
        guard let converted = usingColorSpace(.sRGB) else { return "000000" }
        let red = Int((converted.redComponent * 255).rounded())
        let green = Int((converted.greenComponent * 255).rounded())
        let blue = Int((converted.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", red, green, blue)
    }
}
