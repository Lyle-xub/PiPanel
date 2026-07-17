import SwiftUI

struct AutomationSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        SettingsPage {
            SettingsPageIntro(
                title: "让窗口自己归位",
                detail: "按应用切换和空闲状态自动处理画中画，减少重复整理。"
            )

            MembershipGate {
                SettingsGroup("应用切换", detail: "减少画中画遮挡与焦点打断", icon: "arrow.triangle.2.circlepath", tint: .blue) {
                    SettingsToggleRow(
                        "源软件被激活时自动隐藏画中画",
                        detail: "回到原应用时暂时隐藏它的画中画",
                        icon: "eye.slash.fill",
                        tint: .blue,
                        isOn: $settings.autoHideWhenSourceActive
                    )
                    SettingsRowDivider()
                    SettingsToggleRow(
                        "点击或输入后自动归还键盘焦点",
                        detail: "操作画中画后回到之前使用的软件",
                        icon: "keyboard.badge.ellipsis",
                        tint: .indigo,
                        isOn: $settings.autoReturnEnabled
                    )

                    if settings.autoReturnEnabled {
                        SettingsRowDivider()
                        SliderSettingRow(
                            title: "归还延迟",
                            valueText: String(format: "%.1f 秒", settings.autoReturnIdleInterval),
                            icon: "timer",
                            tint: .indigo,
                            value: $settings.autoReturnIdleInterval,
                            range: 0.5...5,
                            step: 0.5
                        )
                    }
                }

                SettingsGroup("空闲整理", detail: "长时间不操作时自动收拢", icon: "square.3.layers.3d.down.right", tint: .orange) {
                    SettingsToggleRow(
                        "自动堆叠贴边",
                        detail: "将所有画中画收拢到默认堆叠角落",
                        icon: "rectangle.stack.fill",
                        tint: .orange,
                        isOn: $settings.autoStackOnIdleEnabled
                    )

                    if settings.autoStackOnIdleEnabled {
                        SettingsRowDivider()
                        SliderSettingRow(
                            title: "无操作时长",
                            valueText: idleIntervalLabel,
                            icon: "clock",
                            tint: .orange,
                            value: $settings.autoStackIdleInterval,
                            range: 10...300,
                            step: 10
                        )
                    }
                }
            }
        }
    }

    private var idleIntervalLabel: String {
        let totalSeconds = Int(settings.autoStackIdleInterval)
        guard totalSeconds >= 60 else { return "\(totalSeconds) 秒" }
        let minutes = totalSeconds / 60
        let remainder = totalSeconds % 60
        return remainder == 0 ? "\(minutes) 分钟" : "\(minutes) 分 \(remainder) 秒"
    }
}

struct ShortcutsSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @State private var searchText = ""

    var body: some View {
        SettingsPage {
            MembershipGate {
                HStack(alignment: .top, spacing: 16) {
                    shortcutList
                        .frame(maxWidth: .infinity)
                        .layoutPriority(1)

                    shortcutDescription
                        .frame(width: 215)
                }
                .frame(maxWidth: .infinity, minHeight: 320)
            }
        }
    }

    private var shortcutList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)

                TextField("搜索功能或快捷键", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 48)

            Divider()

            Text("默认快捷键")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .frame(height: 36)

            Divider()

            if filteredActions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 22))
                    Text("没有匹配的快捷键")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(filteredActions.enumerated()), id: \.element.id) { index, action in
                        ShortcutSettingRow(
                            title: action.title,
                            hint: action.hint,
                            shortcut: binding(for: action)
                        )

                        if index < filteredActions.count - 1 {
                            Divider().padding(.leading, 16)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 320)
        .background(SettingsTheme.cardFill, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(SettingsTheme.cardBorder, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private var shortcutDescription: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ShortcutKeycap(symbol: "command")
                ShortcutKeycap(symbol: "pip")
            }

            Text("自定义快捷键")
                .font(.system(size: 17, weight: .bold))
                .padding(.top, 22)

            Text("为常用的画中画操作重新分配快捷键。修改保存后会立即在所有软件中生效。")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            Spacer(minLength: 24)

            HStack(spacing: 8) {
                Button("恢复默认快捷键") {
                    settings.resetShortcutsToDefaults()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(settings.shortcutsAreDefault)

                Menu {
                    Button("清空全部快捷键", role: .destructive) {
                        settings.stackShortcut = nil
                        settings.closeAllShortcut = nil
                        settings.pipAllShortcut = nil
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("更多快捷键操作")
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var filteredActions: [ShortcutAction] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return ShortcutAction.allCases }
        return ShortcutAction.allCases.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.hint.localizedCaseInsensitiveContains(query)
                || (binding(for: $0).wrappedValue?.displayString.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private func binding(for action: ShortcutAction) -> Binding<GlobalShortcut?> {
        switch action {
        case .stack:
            $settings.stackShortcut
        case .closeAll:
            $settings.closeAllShortcut
        case .pictureAll:
            $settings.pipAllShortcut
        }
    }
}

private struct ShortcutSettingRow: View {
    let title: String
    let hint: String
    @Binding var shortcut: GlobalShortcut?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(hint)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ShortcutRecorderView(shortcut: $shortcut)
                .frame(width: 112)
                .frame(minHeight: 34, maxHeight: 34)
                .contextMenu {
                    Button("清除此快捷键", role: .destructive) {
                        shortcut = nil
                    }
                }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 68, maxHeight: 68)
        .clipped()
    }
}

private struct ShortcutKeycap: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(SettingsTheme.accent)
            .frame(width: 52, height: 52)
            .background(
                LinearGradient(
                    colors: [SettingsTheme.accent.opacity(0.12), SettingsTheme.accent.opacity(0.22)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(SettingsTheme.accent.opacity(0.72), lineWidth: 2)
            }
            .shadow(color: SettingsTheme.accent.opacity(0.18), radius: 5, y: 3)
    }
}

private enum ShortcutAction: CaseIterable, Identifiable {
    case stack
    case closeAll
    case pictureAll

    var id: Self { self }

    var title: String {
        switch self {
        case .stack: "堆叠 / 摊开所有画中画"
        case .closeAll: "关闭所有画中画"
        case .pictureAll: "画中画所有窗口并堆叠"
        }
    }

    var hint: String {
        switch self {
        case .stack: "聚拢到默认角落，再次按下即可摊开"
        case .closeAll: "一键关闭当前所有画中画"
        case .pictureAll: "转换所有可用窗口并自动收拢"
        }
    }
}
