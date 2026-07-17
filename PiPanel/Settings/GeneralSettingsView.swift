import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject private var launchAtLogin = LaunchAtLoginManager.shared

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
                Label("将鼠标移到窗口右上角，点击出现的画中画按钮", systemImage: "pip.enter")
                Text("开源免费版固定使用右上角悬停按钮，最多同时打开一个画中画。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("默认行为") {
                LabeledContent("画面帧率", value: "15 fps")
                LabeledContent("画面清晰度", value: "960 px")
                LabeledContent("关闭方式", value: "左上角关闭按钮")
                Text("这些默认值优先降低资源消耗，并保留窗口裁切、坐标校准、全屏悬浮和退出恢复等核心能力。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .settingsPageFormStyle()
    }
}
