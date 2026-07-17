import SwiftUI

struct PermissionsSettingsView: View {
    @EnvironmentObject private var permissionsManager: PermissionsManager

    var body: some View {
        SettingsPage {
            SettingsPageIntro(
                title: "系统权限",
                detail: "PiPanel 只读取窗口画面并操作窗口位置，不会保存或上传屏幕内容。"
            )

            SettingsGroup("必要权限", detail: "缺少任意一项都会影响画中画操作", icon: "lock.shield.fill", tint: .teal) {
                PermissionRow(
                    granted: permissionsManager.hasScreenRecordingAccess,
                    icon: "rectangle.on.rectangle",
                    title: "屏幕录制",
                    action: {
                        permissionsManager.requestScreenRecordingAccess()
                        permissionsManager.openScreenRecordingSettings()
                    },
                    showsBackground: false
                )
                .padding(.horizontal, 17)
                .padding(.vertical, 6)

                if permissionsManager.needsRelaunchForScreenRecording {
                    SettingsRowDivider()
                    RelaunchHintView()
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                }

                SettingsRowDivider()

                PermissionRow(
                    granted: permissionsManager.hasAccessibilityAccess,
                    icon: "hand.point.up.left",
                    title: "辅助功能",
                    action: {
                        permissionsManager.requestAccessibilityAccess()
                        permissionsManager.openAccessibilitySettings()
                    },
                    showsBackground: false
                )
                .padding(.horizontal, 17)
                .padding(.vertical, 6)
            }

            SettingsHint("授权状态由 macOS 管理。修改屏幕录制权限后通常需要重新启动 PiPanel。")
        }
    }
}
