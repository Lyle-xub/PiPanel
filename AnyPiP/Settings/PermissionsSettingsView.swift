import SwiftUI

struct PermissionsSettingsView: View {
    @EnvironmentObject private var permissionsManager: PermissionsManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AnyPiP 需要以下权限才能捕获并操作其他窗口")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            PermissionRow(
                granted: permissionsManager.hasScreenRecordingAccess,
                icon: "rectangle.on.rectangle",
                title: "屏幕录制",
                action: {
                    permissionsManager.requestScreenRecordingAccess()
                    permissionsManager.openScreenRecordingSettings()
                }
            )
            PermissionRow(
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
}
