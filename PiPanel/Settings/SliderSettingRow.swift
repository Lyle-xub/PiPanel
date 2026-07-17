import SwiftUI

/// A restrained value slider used inside an Arc-style settings card. SwiftUI's macOS slider draws
/// one tick for every discrete step, which becomes visual noise on wide ranges. This control keeps
/// the native, accessible track but snaps in the binding instead, preserving the setting's exact
/// step without rendering dozens of tick marks.
struct SliderSettingRow: View {
    let title: String
    let valueText: String
    let icon: String
    let tint: Color
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var hint: String?

    init(
        title: String,
        valueText: String,
        icon: String,
        tint: Color = SettingsTheme.accent,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        hint: String? = nil
    ) {
        self.title = title
        self.valueText = valueText
        self.icon = icon
        self.tint = tint
        _value = value
        self.range = range
        self.step = step
        self.hint = hint
    }

    var body: some View {
        HStack(spacing: 12) {
            SettingsRowIcon(icon: icon, tint: tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                if let hint {
                    Text(hint)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            SettingsTrailingControl {
                HStack(spacing: 10) {
                    Slider(value: snappedValue, in: range)
                        .controlSize(.mini)
                        .tint(tint)
                        .frame(width: 136)

                    Text(valueText)
                        .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(width: 88, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, SettingsLayout.rowHorizontalPadding)
        .padding(.vertical, hint == nil ? 11 : 9)
    }

    private var snappedValue: Binding<Double> {
        Binding(
            get: { value },
            set: { proposedValue in
                let stepCount = ((proposedValue - range.lowerBound) / step).rounded()
                let snapped = range.lowerBound + stepCount * step
                value = min(max(snapped, range.lowerBound), range.upperBound)
            }
        )
    }
}
