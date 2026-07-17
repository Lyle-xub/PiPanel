import SwiftUI

/// Applies the same Pro lock treatment to one or more Arc-style cards. Unlike the previous Form
/// implementation, this wrapper owns real spacing because Settings pages are now explicit card
/// stacks rather than Section children interpreted by SwiftUI's grouped Form renderer.
struct MembershipGate<Content: View>: View {
    @ObservedObject private var membership = MembershipManager.shared
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            content
                .disabled(!membership.isMember)
                .opacity(membership.isMember ? 1 : 0.42)

            if !membership.isMember {
                HStack(spacing: 12) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SettingsTheme.accent)
                        .frame(width: 32, height: 32)
                        .background(SettingsTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("需要专业版")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text("前往「专业版」页面开始试用、购买或输入激活码")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(14)
                .background(SettingsTheme.cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(SettingsTheme.cardBorder, lineWidth: 1)
                }
            }
        }
    }
}
