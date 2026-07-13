import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var launchAtLogin = LaunchAtLoginManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("开机启动", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                .font(.system(size: 12))
                .toggleStyle(.switch)

                if let error = launchAtLogin.lastError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }

            Divider()

            // Everything below requires an active membership — Launch at Login above is the one
            // setting deliberately kept free.
            MembershipGate {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("画面帧率")
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text("\(settings.targetFPS) fps")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { Double(settings.targetFPS) },
                            set: { settings.targetFPS = Int($0) }
                        ), in: 5...30, step: 1)
                        Text("更低帧率更省电，更高帧率更流畅")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("源软件被激活时自动隐藏画中画", isOn: $settings.autoHideWhenSourceActive)
                            .font(.system(size: 12))
                        Toggle("点击/输入后自动归还键盘焦点", isOn: $settings.autoReturnEnabled)
                            .font(.system(size: 12))

                        if settings.autoReturnEnabled {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("归还延迟")
                                        .font(.system(size: 12))
                                    Spacer()
                                    Text("\(settings.autoReturnIdleInterval, specifier: "%.1f")s")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                                Slider(value: $settings.autoReturnIdleInterval, in: 0.5...5, step: 0.5)
                            }
                            .padding(.leading, 4)
                        }
                    }
                    .toggleStyle(.switch)

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("默认画中画宽度")
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text("\(Int(settings.defaultPanelWidth)) pt")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.defaultPanelWidth, in: 240...600, step: 10)
                        Text("仅影响新建的画中画，不会改变已打开的窗口")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("默认堆叠角落")
                            .font(.system(size: 12, weight: .semibold))
                        Picker("", selection: $settings.defaultStackingCorner) {
                            ForEach(PanelCorner.allCases) { corner in
                                Text(corner.displayName).tag(corner)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }
            }
        }
    }
}
