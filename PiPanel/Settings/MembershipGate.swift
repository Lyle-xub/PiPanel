import SwiftUI

/// Wraps a block of settings controls that require an active membership — dims and disables the
/// content when not a member, with a small lock hint pointing at the Membership sidebar section
/// rather than duplicating the activation UI inline in every gated section.
struct MembershipGate<Content: View>: View {
    @ObservedObject private var membership = MembershipManager.shared
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
                .disabled(!membership.isMember)
                .opacity(membership.isMember ? 1 : 0.4)

            if !membership.isMember {
                Label("这些设置需要激活会员，请前往「会员」页面购买或输入激活码", systemImage: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
