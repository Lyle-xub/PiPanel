import SwiftUI

struct AppearanceSettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        MembershipGate {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("画面圆角")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text("\(Int(settings.panelCornerRadius)) pt")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.panelCornerRadius, in: 0...24, step: 1)
                }

                Divider()

                Toggle("显示阴影", isOn: $settings.panelShadowEnabled)
                    .font(.system(size: 12))
                    .toggleStyle(.switch)

                Text("仅影响新建的画中画，不会改变已打开的窗口")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
