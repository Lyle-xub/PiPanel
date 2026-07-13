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
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.5)))
    }
}
