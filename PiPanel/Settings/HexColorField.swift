import SwiftUI
import AppKit

/// A labeled row pairing a plain hex-code text field with a live color swatch preview — the shared
/// control behind every color setting in AppearanceSettingsView (background, handle, border,
/// border gradient end). Deliberately a plain text field rather than SwiftUI's native ColorPicker,
/// per how the user described wanting this: type a hex code, see what it looks like next to it.
///
/// The swatch only updates for a *parseable* hex string (NSColor(hex:) succeeds) — while the text
/// is mid-edit and momentarily invalid (e.g. "12" while typing "1234FF"), the swatch just keeps
/// showing whatever the last valid color was rather than flashing to black/some fallback, and the
/// text field itself is never forcibly corrected, so the user can keep typing uninterrupted.
struct HexColorField: View {
    let title: String
    let icon: String
    let tint: Color
    @Binding var hex: String

    init(title: String, icon: String, tint: Color = SettingsTheme.accent, hex: Binding<String>) {
        self.title = title
        self.icon = icon
        self.tint = tint
        _hex = hex
    }

    private var previewColor: Color {
        guard let color = NSColor(hex: hex) else { return .clear }
        return Color(color)
    }

    var body: some View {
        HStack(spacing: 12) {
            SettingsRowIcon(icon: icon, tint: tint)

            Text(title)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)

            SettingsTrailingControl {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(previewColor)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                        )
                        .frame(width: 24, height: 24)
                    TextField("RRGGBB", text: $hex)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 92)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding(.horizontal, SettingsLayout.rowHorizontalPadding)
        .padding(.vertical, 10)
    }
}
