import SwiftUI

/// Small chromeless icon button — used for the settings-page back chevron and the window-list
/// refresh button, where a full bordered/bezeled button would be visually heavier than warranted.
struct SubtleIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.secondary)
            .padding(6)
            .background(
                Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.001))
            )
            .contentShape(Circle())
    }
}

/// Footer action buttons (设置/退出 AnyPiP) — icon + label with a hover/press background rather
/// than a bordered button, reading as a lightweight toolbar instead of a stack of form buttons.
struct FooterButtonStyle: ButtonStyle {
    var tint: Color = .primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.001))
            )
    }
}

/// Small filled capsule button for compact inline actions (授权 in the permissions banner).
struct PillButtonStyle: ButtonStyle {
    var tint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(configuration.isPressed ? 0.7 : 1)))
    }
}

/// Wraps list-style row content (window picker entries, active-session rows) with a hover
/// highlight, so the popover reads as a list of tappable items rather than plain stacked text.
struct HoverableRow<Content: View>: View {
    @State private var isHovering = false
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .onHover { isHovering = $0 }
    }
}
