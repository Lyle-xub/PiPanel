import SwiftUI

/// Everything that changes the PiP window itself lives here: initial geometry, visual treatment,
/// closing, edge affordance and stacked-window layout. Keeping those together mirrors how users
/// think about the floating object, rather than splitting one window across General/Appearance/
/// Advanced as the old settings hierarchy did.
struct AppearanceSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        SettingsPage {
            SettingsPageIntro(
                title: "窗口外观与行为",
                detail: "决定新画中画出现时的尺寸、样式，以及它被收起或关闭的方式。"
            )

            MembershipGate {
                layoutGroup
                appearanceGroup
                borderGroup
                effectsGroup
                edgeHandleGroup
                stackingGroup
            }
        }
    }

    private var layoutGroup: some View {
        SettingsGroup("窗口布局", detail: "新建画中画的默认状态", icon: "macwindow", tint: .blue) {
            SliderSettingRow(
                title: "默认画中画宽度",
                valueText: "\(Int(settings.defaultPanelWidth)) pt",
                icon: "arrow.left.and.right",
                tint: .blue,
                value: $settings.defaultPanelWidth,
                range: 240...600,
                step: 10,
                hint: "不会改变已经打开的画中画"
            )

            SettingsRowDivider()

            SettingsControlRow("默认堆叠角落", icon: "square.grid.2x2", tint: .blue) {
                SettingsPopupControl(
                    options: PanelCorner.allCases,
                    selection: $settings.defaultStackingCorner,
                    label: { $0.displayName }
                )
            }

            SettingsRowDivider()

            SettingsControlRow(
                "关闭方式",
                detail: closeMethodHint,
                icon: "xmark.circle",
                tint: .red
            ) {
                SettingsSegmentedControl(
                    options: PiPCloseMethod.allCases,
                    selection: $settings.panelCloseMethod,
                    label: { $0.displayName }
                )
            }
        }
    }

    private var appearanceGroup: some View {
        SettingsGroup("画中画外观", detail: "圆角、透明度与窗口信息", icon: "paintbrush.fill", tint: .purple) {
            SliderSettingRow(
                title: "画面圆角",
                valueText: "\(Int(settings.panelCornerRadius)) pt",
                icon: "square",
                tint: .purple,
                value: $settings.panelCornerRadius,
                range: 0...24,
                step: 1
            )
            SettingsRowDivider()
            SliderSettingRow(
                title: "画中画透明度",
                valueText: "\(Int(settings.panelOpacity * 100))%",
                icon: "circle.lefthalf.filled",
                tint: .purple,
                value: $settings.panelOpacity,
                range: 0.2...1.0,
                step: 0.05,
                hint: "对已打开的画中画立即生效"
            )
            SettingsRowDivider()
            SettingsToggleRow("显示阴影", icon: "shadow", tint: .indigo, isOn: $settings.panelShadowEnabled)
            SettingsRowDivider()
            SettingsToggleRow("显示源窗口标题", icon: "textformat", tint: .indigo, isOn: $settings.panelTitleEnabled)
            SettingsRowDivider()
            HexColorField(
                title: "背景颜色",
                icon: "paintpalette",
                tint: .purple,
                hex: $settings.panelBackgroundColorHex
            )
        }
    }

    private var borderGroup: some View {
        SettingsGroup("边框", detail: "普通、渐变或光效边框", icon: "square.dashed", tint: .orange) {
            SettingsControlRow("边框样式", icon: "square.dashed", tint: .orange) {
                SettingsPopupControl(
                    options: PanelBorderStyle.allCases,
                    selection: $settings.panelBorderStyle,
                    label: { $0.displayName }
                )
            }

            if settings.panelBorderStyle != .none {
                SettingsRowDivider()
                HexColorField(
                    title: settings.panelBorderStyle == .glow ? "光效颜色" : "边框颜色",
                    icon: "pencil.tip",
                    tint: .orange,
                    hex: $settings.panelBorderColorHex
                )

                if settings.panelBorderStyle == .gradient {
                    SettingsRowDivider()
                    HexColorField(
                        title: "渐变结束颜色",
                        icon: "circle.hexagongrid",
                        tint: .pink,
                        hex: $settings.panelBorderGradientEndColorHex
                    )
                }

                SettingsRowDivider()
                SliderSettingRow(
                    title: "边框粗细",
                    valueText: String(format: "%.1f pt", settings.panelBorderWidth),
                    icon: "line.3.horizontal",
                    tint: .orange,
                    value: $settings.panelBorderWidth,
                    range: 1...6,
                    step: 0.5
                )
            }
        }
    }

    private var effectsGroup: some View {
        SettingsGroup("内容与特效", detail: "进入画中画后的辅助显示", icon: "sparkles", tint: .pink) {
            SettingsToggleRow(
                "出现涟漪特效",
                detail: "创建画中画时显示短暂的扩散动画",
                icon: "water.waves",
                tint: .pink,
                isOn: $settings.panelAppearRippleEnabled
            )
            SettingsRowDivider()
            SettingsToggleRow(
                "鼠标操作光效",
                detail: "双击进入控制模式后，在画中画外沿显示白色呼吸柔光",
                icon: "cursorarrow.rays",
                tint: .blue,
                isOn: $settings.controlModeGlowEnabled
            )
            SettingsRowDivider()
            SettingsToggleRow(
                "为音乐类 App 启用歌词模式",
                detail: "在视频画面与歌词面板之间切换",
                icon: "music.note",
                tint: .purple,
                isOn: $settings.panelLyricsEnabled
            )
        }
    }

    private var edgeHandleGroup: some View {
        SettingsGroup("贴边把手", detail: "画中画隐藏到屏幕边缘后的召回区域", icon: "rectangle.lefthalf.inset.filled", tint: .teal) {
            HexColorField(
                title: "把手颜色",
                icon: "paintbrush.pointed",
                tint: .teal,
                hex: $settings.edgeHandleColorHex
            )
            SettingsRowDivider()
            SliderSettingRow(
                title: "把手宽度",
                valueText: "\(Int(settings.edgeHandleWidth)) pt",
                icon: "arrow.left.and.right",
                tint: .teal,
                value: $settings.edgeHandleWidth,
                range: 6...20,
                step: 1
            )
            SettingsRowDivider()
            SliderSettingRow(
                title: "把手高度",
                valueText: "\(Int(settings.edgeHandleHeight)) pt",
                icon: "arrow.up.and.down",
                tint: .teal,
                value: $settings.edgeHandleHeight,
                range: 40...120,
                step: 4
            )
        }
    }

    private var stackingGroup: some View {
        SettingsGroup("堆叠布局", detail: "多个画中画收拢时的排列方式", icon: "square.3.layers.3d", tint: .green) {
            SliderSettingRow(
                title: "层叠间距",
                valueText: "\(Int(settings.stackCascadeStep)) pt",
                icon: "square.2.layers.3d",
                tint: .green,
                value: $settings.stackCascadeStep,
                range: 0...30,
                step: 2
            )
            SettingsRowDivider()
            SliderSettingRow(
                title: "堆叠边距",
                valueText: "\(Int(settings.stackCascadeMargin)) pt",
                icon: "arrow.up.left.and.arrow.down.right",
                tint: .green,
                value: $settings.stackCascadeMargin,
                range: 8...48,
                step: 4
            )
            SettingsRowDivider()
            SliderSettingRow(
                title: "最大层叠数",
                valueText: "\(Int(settings.stackMaxVisibleDepth))",
                icon: "square.stack.3d.up",
                tint: .green,
                value: $settings.stackMaxVisibleDepth,
                range: 1...10,
                step: 1
            )
            SettingsRowDivider()
            SettingsHint("堆叠参数会立即应用；其他外观设置主要影响新建的画中画和把手。")
        }
    }

    private var closeMethodHint: String {
        switch settings.panelCloseMethod {
        case .dragToZone:
            "拖入红色关闭区域"
        case .cornerButton:
            "使用左上角关闭按钮"
        }
    }
}
