import SwiftUI

struct PermissionsSettingsView: View {
    @EnvironmentObject private var permissionsManager: PermissionsManager

    var body: some View {
        Form {
            Section {
                Text("PiPanel 需要以下权限才能捕获并操作其他窗口")
                    .foregroundStyle(.secondary)

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
                if permissionsManager.needsRelaunchForScreenRecording {
                    RelaunchHintView()
                }
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
            }
        }
        .settingsPageFormStyle()
    }
}
