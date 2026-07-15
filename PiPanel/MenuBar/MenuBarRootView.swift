import SwiftUI

struct MenuBarRootView: View {
    @EnvironmentObject private var permissionsManager: PermissionsManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if !permissionsManager.hasAllPermissions {
                    PermissionsBannerView()
                } else {
                    ActiveSessionsView()
                }
            }
            .padding(14)

            Divider()
            footer
        }
        .frame(width: 340)
        // Opening this menu bar dropdown never makes PiPanel "the active application" — that's
        // deliberate for any menu-bar utility (it shouldn't steal focus from whatever you were
        // just doing), but it also means neither NSApplication.didBecomeActiveNotification nor
        // NSWorkspace.didActivateApplicationNotification (PermissionsManager's other two refresh
        // triggers) ever fire just from clicking the status item again after granting a
        // permission in System Settings and clicking back here — this is the one place users
        // actually see/act on permission status before ever opening the full Settings window, so
        // it needs its own direct, guaranteed trigger rather than depending on app-activation
        // semantics that a menu-bar utility was never going to send in the first place.
        .onAppear { permissionsManager.refresh() }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Button {
                // MenuBarExtra(.window) has no SwiftUI-native "dismiss" handle — the standard,
                // widely-used workaround is closing whichever window is currently key, which at
                // the moment this button's own click is being handled is guaranteed to be this
                // popover's own hosting window (nothing else could have been key for the click to
                // have reached here at all). Closing it before showing Settings avoids leaving the
                // dropdown visibly stuck open behind the new window.
                NSApp.keyWindow?.close()
                SettingsWindowController.shared.show()
            } label: {
                Label("设置", systemImage: "gearshape")
            }
            .buttonStyle(FooterButtonStyle())
            Spacer()
            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("退出 PiPanel", systemImage: "power")
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
            Label("需要以下权限才能使用 PiPanel", systemImage: "lock.shield")
                .font(.system(size: 12, weight: .semibold))
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
                }
            )
        }
    }
}
