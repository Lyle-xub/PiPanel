import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var launchAtLogin = LaunchAtLoginManager.shared

    var body: some View {
        SettingsPage {
            SettingsPageIntro(
                title: "从这里开始",
                detail: "设置 PiPanel 如何启动，以及你最常用的画中画触发方式。"
            )

            SettingsGroup("启动", detail: "登录 Mac 后随时可用", icon: "power", tint: .green) {
                SettingsToggleRow(
                    "开机启动",
                    detail: "登录后自动在菜单栏运行 PiPanel",
                    icon: "arrow.up.forward.app.fill",
                    tint: .green,
                    isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.setEnabled($0) }
                    )
                )

                if let error = launchAtLogin.lastError {
                    SettingsRowDivider()
                    Text(error)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 17)
                        .padding(.vertical, 10)
                }
            }

            MembershipGate {
                SettingsGroup(
                    "启动画中画",
                    detail: "选择把普通窗口变成画中画的动作",
                    icon: "pip.enter",
                    tint: SettingsTheme.indigo
                ) {
                    SettingsControlRow(
                        "启动方式",
                        detail: activationMethodDescription,
                        icon: "cursorarrow.click.2",
                        tint: SettingsTheme.indigo
                    ) {
                        SettingsSegmentedControl(
                            options: [.cornerSwitch, .shake],
                            selection: $settings.pipActivationMethod,
                            label: { $0.displayName }
                        )
                    }
                }
            }
        }
    }

    private var activationMethodDescription: String {
        switch settings.pipActivationMethod {
        case .cornerSwitch:
            "鼠标移到任意窗口右上角，点击浮现的按钮"
        case .shake:
            "拖住窗口快速来回摇动"
        }
    }
}

/// Capture quality has its own page: these controls all trade image fidelity for GPU, memory and
/// display bandwidth, so putting them beside startup/automation made the old General page hard to
/// scan and easy to misconfigure.
struct PictureSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @State private var maximumDisplayFPS = DisplayRefreshRate.maximumPhysicalFPS()

    var body: some View {
        SettingsPage {
            SettingsPageIntro(
                title: "画面质量与性能",
                detail: "较低设置更省电；较高设置让文字、视频和动画更加清晰流畅。"
            )

            MembershipGate {
                SettingsGroup(
                    "捕获质量",
                    detail: "对已打开的画中画立即生效",
                    icon: "display",
                    tint: .blue
                ) {
                    SliderSettingRow(
                        title: "画面帧率",
                        valueText: "\(settings.targetFPS) fps",
                        icon: "speedometer",
                        tint: .blue,
                        value: Binding(
                            get: { Double(settings.targetFPS) },
                            set: { settings.targetFPS = Int($0) }
                        ),
                        range: Double(DisplayRefreshRate.minimumSelectableFPS)...Double(maximumDisplayFPS),
                        step: 1,
                        hint: "最高匹配当前显示器刷新率"
                    )

                    SettingsRowDivider()

                    SliderSettingRow(
                        title: "虚拟显示器分辨率",
                        valueText: {
                            let size = VirtualDisplayHost.pixelSize(forLongEdge: settings.virtualDisplayLongEdge)
                            return "\(size.width) × \(size.height)"
                        }(),
                        icon: "display",
                        tint: .indigo,
                        value: $settings.virtualDisplayLongEdge,
                        range: SettingsStore.minimumVirtualDisplayLongEdge...SettingsStore.maximumVirtualDisplayLongEdge,
                        step: 128,
                        hint: "决定源窗口可用空间；必要时会自动扩展"
                    )

                    SettingsRowDivider()

                    SliderSettingRow(
                        title: "画面清晰度",
                        valueText: "\(Int(settings.captureOutputLongEdge)) px",
                        icon: "sparkles",
                        tint: .purple,
                        value: $settings.captureOutputLongEdge,
                        range: 640...2560,
                        step: 160,
                        hint: "提高数值会增加显存、带宽和编码开销"
                    )
                }

                SettingsHint("如果感觉电脑发热或掉帧，优先降低画面清晰度和虚拟显示器分辨率。")
            }
        }
        .onAppear { refreshMaximumDisplayFPS() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            refreshMaximumDisplayFPS()
        }
    }

    private func refreshMaximumDisplayFPS() {
        maximumDisplayFPS = max(
            DisplayRefreshRate.maximumPhysicalFPS(),
            DisplayRefreshRate.minimumSelectableFPS
        )
        settings.targetFPS = min(
            max(settings.targetFPS, DisplayRefreshRate.minimumSelectableFPS),
            maximumDisplayFPS
        )
    }
}
