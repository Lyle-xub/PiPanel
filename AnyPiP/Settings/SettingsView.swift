import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
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
        }
    }
}
