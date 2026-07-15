import SwiftUI

struct AdvancedSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        Form {
            MembershipGate {
                Section("画中画歌词") {
                    Toggle("为音乐类 App 启用歌词模式", isOn: $settings.panelLyricsEnabled)
                    Text("开启后，来自音乐类 App 的画中画会显示歌词切换按钮，可在视频画面与歌词面板之间切换。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("关闭画中画") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("关闭方式")
                        Picker("关闭方式", selection: $settings.panelCloseMethod) {
                            ForEach(PiPCloseMethod.allCases) { method in
                                Text(method.displayName).tag(method)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)

                        Text(closeMethodHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("全局快捷键") {
                    ShortcutSettingRow(
                        title: "堆叠 / 摊开所有画中画",
                        hint: "聚拢到默认角落；再次按下或点击堆叠区域即可摊开",
                        shortcut: $settings.stackShortcut
                    )
                    ShortcutSettingRow(
                        title: "关闭所有画中画",
                        hint: "一键关闭当前所有打开的画中画",
                        shortcut: $settings.closeAllShortcut
                    )
                    ShortcutSettingRow(
                        title: "画中画所有窗口并堆叠",
                        hint: "把所有未最小化、未全屏的窗口转为画中画并自动堆叠",
                        shortcut: $settings.pipAllShortcut
                    )
                }
            }
        }
        .settingsPageFormStyle()
    }

    private var closeMethodHint: String {
        switch settings.panelCloseMethod {
        case .dragToZone:
            return "拖动画中画时会出现红色目标圈，将窗口拖入其中即可关闭。"
        case .cornerButton:
            return "画中画左上角会显示一个圆形关闭按钮。"
        }
    }
}

private struct ShortcutSettingRow: View {
    let title: String
    let hint: String
    @Binding var shortcut: GlobalShortcut?

    private let shortcutTint = Color(red: 0.76, green: 0.20, blue: 0.92)

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "command")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(shortcutTint)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 185, alignment: .leading)

            ZStack(alignment: .trailing) {
                ShortcutRecorderView(shortcut: $shortcut)
                    .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34)

                if shortcut != nil {
                    Button {
                        shortcut = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.secondary.opacity(0.42))
                    }
                    .buttonStyle(.plain)
                    .help("清除快捷键")
                    .padding(.trailing, 9)
                }
            }
        }
        .padding(.vertical, 5)
    }
}
