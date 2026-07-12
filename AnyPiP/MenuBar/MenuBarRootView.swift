import SwiftUI

struct MenuBarRootView: View {
    @EnvironmentObject private var permissionsManager: PermissionsManager
    @EnvironmentObject private var sessionManager: PiPSessionManager
    @State private var showingSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            Group {
                if showingSettings {
                    SettingsView()
                } else if !permissionsManager.hasAllPermissions {
                    PermissionsBannerView()
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        WindowPickerView()
                        ActiveSessionsView()
                    }
                }
            }
            .padding(14)

            Divider()
            footer
        }
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.gradient)
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: "pip.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: 1) {
                Text("AnyPiP")
                    .font(.system(size: 13, weight: .semibold))
                Text(headerSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if showingSettings {
                Button {
                    showingSettings = false
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(SubtleIconButtonStyle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var headerSubtitle: String {
        if showingSettings { return "设置" }
        if sessionManager.sessions.isEmpty { return "将任意窗口变为画中画" }
        return "\(sessionManager.sessions.count) 个画中画正在运行"
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if !showingSettings {
                Button {
                    showingSettings = true
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
                .buttonStyle(FooterButtonStyle())
            }
            Spacer()
            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("退出 AnyPiP", systemImage: "power")
            }
            .buttonStyle(FooterButtonStyle(tint: .red))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private struct PermissionsBannerView: View {
    @EnvironmentObject private var permissionsManager: PermissionsManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("需要以下权限才能使用 AnyPiP", systemImage: "lock.shield")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            permissionRow(
                granted: permissionsManager.hasScreenRecordingAccess,
                icon: "rectangle.on.rectangle",
                title: "屏幕录制",
                action: {
                    permissionsManager.requestScreenRecordingAccess()
                    permissionsManager.openScreenRecordingSettings()
                }
            )
            permissionRow(
                granted: permissionsManager.hasAccessibilityAccess,
                icon: "hand.point.up.left",
                title: "辅助功能",
                action: {
                    permissionsManager.requestAccessibilityAccess()
                    permissionsManager.openAccessibilitySettings()
                }
            )
        }
    }

    @ViewBuilder
    private func permissionRow(granted: Bool, icon: String, title: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title)
                .font(.system(size: 12))
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("授权", action: action)
                    .buttonStyle(PillButtonStyle())
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.5)))
    }
}
