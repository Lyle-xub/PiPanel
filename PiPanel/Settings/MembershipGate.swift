import SwiftUI

/// Wraps a block of settings controls that require an active membership — dims and disables the
/// content when not a member, with a small lock hint pointing at the Membership sidebar section
/// rather than duplicating the activation UI inline in every gated section.
///
/// `content` is typically one or more `Section`s meant to sit directly inside a parent `Form` —
/// the wrapper here is a plain `Group`, not a `VStack`, specifically so it has no layout footprint
/// of its own: a `Form` looks at its *immediate* children to tell Sections apart, and a `VStack`
/// wrapping them would defeat that (the whole thing would render as a single opaque block instead
/// of the grouped boxes each Section is supposed to become). The "needs Pro" hint becomes its own
/// trailing `Section` for the same reason, rather than a plain line of text appended after content.
struct MembershipGate<Content: View>: View {
    @ObservedObject private var membership = MembershipManager.shared
    @ViewBuilder let content: Content

    var body: some View {
        Group {
            content
                .disabled(!membership.isMember)
                .opacity(membership.isMember ? 1 : 0.4)

            if !membership.isMember {
                Section {
                    Label("这些设置需要激活专业版，请前往「专业版」页面购买或输入激活码", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
