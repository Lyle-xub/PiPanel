import SwiftUI

/// One permission's status row — icon, title, and either a green checkmark (granted) or an
/// "授权" pill button (not yet granted) that both requests the TCC prompt and opens the relevant
/// System Settings pane. Shared by MenuBarRootView's blocking PermissionsBannerView (shown
/// instead of the picker until every permission is granted) and Settings' always-reachable
/// PermissionsSettingsView (a review/re-authorize page), so the two don't fork the same row UI.
struct PermissionRow: View {
    let granted: Bool
    let icon: String
    let title: String
    let action: () -> Void
    /// True (the default) draws this row's own rounded background — needed for
    /// MenuBarRootView's PermissionsBannerView, which is a floating popover with no other
    /// grouping of its own. PermissionsSettingsView passes false: it places this row inside a
    /// Form/Section instead, which already supplies the grouped-row background, so drawing a
    /// second one here would double up and look like a box nested inside a box.
    var showsBackground: Bool = true

    var body: some View {
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
        .padding(.horizontal, showsBackground ? 10 : 0)
        .background {
            if showsBackground {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.5))
            }
        }
    }
}

/// Screen Recording grants made after launch don't take effect for the running process — shown
/// next to that row once a grant has been requested but still isn't visible to this process.
struct RelaunchHintView: View {
    @EnvironmentObject private var permissionsManager: PermissionsManager

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.clockwise.circle")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text("已授权的话，需要重启 PiPanel 才能生效")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button("重启", action: permissionsManager.relaunch)
                .buttonStyle(PillButtonStyle())
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
    }
}
