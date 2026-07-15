import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var launchAtLogin = LaunchAtLoginManager.shared
    @ObservedObject private var membership = MembershipManager.shared
    @State private var maximumDisplayFPS = DisplayRefreshRate.maximumPhysicalFPS()

    var body: some View {
        Form {
            Section {
                Toggle("开机启动", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))

                if let error = launchAtLogin.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("启动画中画") {
                Picker("启动方式", selection: activationMethodBinding) {
                    Text(PiPActivationMethod.cornerSwitch.displayName)
                        .tag(PiPActivationMethod.cornerSwitch)
                    Text(PiPActivationMethod.shake.displayName)
                        .tag(PiPActivationMethod.shake)
                }

                Text(activationMethodDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Choosing a non-default activation gesture is a Pro customization just like the
            // capture/appearance controls below. MembershipManager.isMember deliberately covers
            // both a live seven-day trial and a permanent license. Free users still *use* the
            // corner switch (observeActivationMethod resolves to it), but cannot change this row.
            .disabled(!membership.isMember)
            .opacity(membership.isMember ? 1 : 0.4)

            // Capture/appearance customization below still requires an active membership.
            MembershipGate {
                Section("画面") {
                    SliderSettingRow(
                        title: "画面帧率",
                        valueText: "\(settings.targetFPS) fps",
                        value: Binding(
                            get: { Double(settings.targetFPS) },
                            set: { settings.targetFPS = Int($0) }
                        ),
                        range: Double(DisplayRefreshRate.minimumSelectableFPS)...Double(maximumDisplayFPS),
                        step: 1,
                        hint: "最高可达当前显示器刷新率；每个画中画会按源窗口所在显示器自动限速"
                    )

                    SliderSettingRow(
                        title: "虚拟显示器分辨率",
                        valueText: {
                            let size = VirtualDisplayHost.pixelSize(forLongEdge: settings.virtualDisplayLongEdge)
                            return "\(size.width) × \(size.height)"
                        }(),
                        value: $settings.virtualDisplayLongEdge,
                        range: 1280...2560,
                        step: 128,
                        hint: "决定画中画窗口最大能拉伸到多大；对已打开的画中画立即生效"
                    )

                    SliderSettingRow(
                        title: "画面清晰度",
                        valueText: "\(Int(settings.captureOutputLongEdge)) px",
                        value: $settings.captureOutputLongEdge,
                        range: 640...2560,
                        step: 160,
                        hint: "数值越高画面越清晰，但更耗性能和带宽；对已打开的画中画立即生效"
                    )
                }

                Section("自动化") {
                    Toggle("源软件被激活时自动隐藏画中画", isOn: $settings.autoHideWhenSourceActive)
                    Toggle("点击/输入后自动归还键盘焦点", isOn: $settings.autoReturnEnabled)

                    if settings.autoReturnEnabled {
                        SliderSettingRow(
                            title: "归还延迟",
                            valueText: String(format: "%.1fs", settings.autoReturnIdleInterval),
                            value: $settings.autoReturnIdleInterval,
                            range: 0.5...5,
                            step: 0.5
                        )
                    }

                    Toggle("长时间无操作时自动堆叠贴边", isOn: $settings.autoStackOnIdleEnabled)

                    if settings.autoStackOnIdleEnabled {
                        SliderSettingRow(
                            title: "无操作时长",
                            valueText: idleIntervalLabel,
                            value: $settings.autoStackIdleInterval,
                            range: 10...300,
                            step: 10
                        )
                    }

                    Text("鼠标键盘长时间无任何操作后，自动把所有画中画堆叠到默认堆叠角落")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("画中画默认设置") {
                    SliderSettingRow(
                        title: "默认画中画宽度",
                        valueText: "\(Int(settings.defaultPanelWidth)) pt",
                        value: $settings.defaultPanelWidth,
                        range: 240...600,
                        step: 10,
                        hint: "仅影响新建的画中画，不会改变已打开的窗口"
                    )

                    Picker("默认堆叠角落", selection: $settings.defaultStackingCorner) {
                        ForEach(PanelCorner.allCases) { corner in
                            Text(corner.displayName).tag(corner)
                        }
                    }
                }

            }
        }
        .settingsPageFormStyle()
        .onAppear {
            refreshMaximumDisplayFPS()
        }
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

    /// "10秒到几分钟不等" — plain seconds reads fine at the low end of autoStackIdleInterval's
    /// range but turns unreadable past a minute or two (e.g. "180s"), so this switches to a
    /// minutes+seconds phrasing once it crosses 60, matching how the feature was actually asked
    /// for rather than just echoing the raw slider value like every other slider here does.
    private var idleIntervalLabel: String {
        let totalSeconds = Int(settings.autoStackIdleInterval)
        guard totalSeconds >= 60 else { return "\(totalSeconds)秒" }
        let minutes = totalSeconds / 60
        let remainder = totalSeconds % 60
        return remainder == 0 ? "\(minutes)分钟" : "\(minutes)分\(remainder)秒"
    }

    private var activationMethodBinding: Binding<PiPActivationMethod> {
        Binding(
            // If a previous trial saved Shake and then expired/cancelled, show the gesture that is
            // actually active instead of leaving a disabled Picker misleadingly displaying Shake.
            // The saved preference itself remains intact and becomes available again if Pro is
            // later activated.
            get: { effectiveActivationMethod },
            set: { method in
                guard membership.isMember else { return }
                settings.pipActivationMethod = method
            }
        )
    }

    private var effectiveActivationMethod: PiPActivationMethod {
        settings.pipActivationMethod.resolved(hasProAccess: membership.isMember)
    }

    private var activationMethodDescription: String {
        switch effectiveActivationMethod {
        case .cornerSwitch:
            return "将鼠标移到任意窗口右上角，悬停开关出现后点击即可进入画中画。"
        case .shake:
            return "拖住窗口快速来回摇动，即可将它转换为画中画。"
        }
    }
}
