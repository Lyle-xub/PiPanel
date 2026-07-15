import SwiftUI

struct AppearanceSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        Form {
            MembershipGate {
                appearanceSections
            }
        }
        .settingsPageFormStyle()
    }

    @ViewBuilder
    private var appearanceSections: some View {
        Group {
            Section("画面外观") {
                SliderSettingRow(
                    title: "画面圆角",
                    valueText: "\(Int(settings.panelCornerRadius)) pt",
                    value: $settings.panelCornerRadius,
                    range: 0...24,
                    step: 1
                )
                Toggle("显示阴影", isOn: $settings.panelShadowEnabled)
                HexColorField(title: "背景颜色", hex: $settings.panelBackgroundColorHex)
                SliderSettingRow(
                    title: "画中画透明度",
                    valueText: "\(Int(settings.panelOpacity * 100))%",
                    value: $settings.panelOpacity,
                    range: 0.2...1.0,
                    step: 0.05,
                    hint: "调整画中画悬浮窗的整体透明度；对已打开的画中画立即生效"
                )
            }

            Section("边框") {
                Picker("边框样式", selection: $settings.panelBorderStyle) {
                    ForEach(PanelBorderStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }

                if settings.panelBorderStyle != .none {
                    HexColorField(
                        title: settings.panelBorderStyle == .glow ? "光效颜色" : "边框颜色",
                        hex: $settings.panelBorderColorHex
                    )

                    if settings.panelBorderStyle == .gradient {
                        HexColorField(title: "渐变结束颜色", hex: $settings.panelBorderGradientEndColorHex)
                    }

                    SliderSettingRow(
                        title: "边框粗细",
                        valueText: String(format: "%.1f pt", settings.panelBorderWidth),
                        value: $settings.panelBorderWidth,
                        range: 1...6,
                        step: 0.5
                    )
                }
            }

            Section("特效") {
                Toggle("出现涟漪特效", isOn: $settings.panelAppearRippleEnabled)
                Toggle("显示源窗口标题", isOn: $settings.panelTitleEnabled)
            }

            Section("贴边把手") {
                HexColorField(title: "把手颜色", hex: $settings.edgeHandleColorHex)
                SliderSettingRow(
                    title: "把手宽度",
                    valueText: "\(Int(settings.edgeHandleWidth)) pt",
                    value: $settings.edgeHandleWidth,
                    range: 6...20,
                    step: 1
                )
                SliderSettingRow(
                    title: "把手高度",
                    valueText: "\(Int(settings.edgeHandleHeight)) pt",
                    value: $settings.edgeHandleHeight,
                    range: 40...120,
                    step: 4
                )
            }

            Section("堆叠") {
                SliderSettingRow(
                    title: "层叠间距",
                    valueText: "\(Int(settings.stackCascadeStep)) pt",
                    value: $settings.stackCascadeStep,
                    range: 0...30,
                    step: 2
                )
                SliderSettingRow(
                    title: "堆叠边距",
                    valueText: "\(Int(settings.stackCascadeMargin)) pt",
                    value: $settings.stackCascadeMargin,
                    range: 8...48,
                    step: 4
                )
                SliderSettingRow(
                    title: "最大层叠数",
                    valueText: "\(Int(settings.stackMaxVisibleDepth))",
                    value: $settings.stackMaxVisibleDepth,
                    range: 1...10,
                    step: 1
                )
                Text("以上设置对已打开的画中画立即生效；其余外观设置仅影响新建的画中画/把手")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
