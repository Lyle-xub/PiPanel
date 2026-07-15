import SwiftUI

/// A "title — current value — slider — optional hint" row, meant to be used directly as a row
/// inside a `Form`'s `Section` (`.formStyle(.grouped)`) rather than as a standalone card — this
/// replaces the same block of boilerplate that used to be hand-copied into GeneralSettingsView/
/// AppearanceSettingsView more than a dozen times, each specifying its own font sizes. Deliberately
/// leaves font/color choices to the Form's own default row styling (aside from the secondary hint
/// text), so every slider row across every settings page stays visually consistent for free.
struct SliderSettingRow: View {
    let title: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(SettingsTheme.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(SettingsTheme.accent.opacity(0.09))
                    )
            }
            Slider(value: $value, in: range, step: step)
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
