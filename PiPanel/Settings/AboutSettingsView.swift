import SwiftUI

struct AboutSettingsView: View {
    @State private var isShowingResetConfirmation = false

    private var appIcon: NSImage {
        NSImage(named: "AppIcon") ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }

    private var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    private var copyrightYear: String {
        String(Calendar.current.component(.year, from: Date()))
    }

    var body: some View {
        SettingsPage {
            productHero

            HStack(alignment: .top, spacing: 14) {
                versionCard
                actionsCard
            }

            Text("© \(copyrightYear) PiPanel · Made for macOS")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
        }
        .confirmationDialog(
            "恢复所有设置到默认？",
            isPresented: $isShowingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("恢复默认", role: .destructive) {
                SettingsStore.shared.resetToDefaults()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("画面参数、自动化、快捷键和外观等可配置项都会恢复到初始值；开机启动保持当前状态，支持实时更新的设置会立即应用到已打开的画中画")
        }
    }

    private var productHero: some View {
        HStack(spacing: 17) {
            Image(nsImage: appIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 72, height: 72)
                .shadow(color: SettingsTheme.accent.opacity(0.22), radius: 14, y: 7)

            VStack(alignment: .leading, spacing: 5) {
                Text("PiPanel")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("让每个窗口，都恰到好处地悬浮")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("专为 macOS 打造")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundStyle(SettingsTheme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(SettingsTheme.accent.opacity(0.10), in: Capsule())
                    .padding(.top, 2)
            }

            Spacer()

            Button("检查更新", action: checkForUpdates)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [SettingsTheme.cardFill, SettingsTheme.accent.opacity(0.075)],
                startPoint: .leading,
                endPoint: .trailing
            ),
            in: RoundedRectangle(cornerRadius: 17, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(SettingsTheme.cardBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.045), radius: 10, y: 4)
    }

    private var versionCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("版本信息", systemImage: "shippingbox.fill")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(SettingsTheme.accent)

            Divider()

            aboutInfoRow("当前版本", value: shortVersion)
            aboutInfoRow("构建版本", value: buildNumber)
            aboutInfoRow("运行平台", value: "macOS")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(aboutCardBackground)
    }

    private var actionsCard: some View {
        VStack(spacing: 0) {
            Button(action: checkForUpdates) {
                aboutActionLabel(
                    title: "软件更新",
                    detail: "检查是否有新的 PiPanel 版本",
                    icon: "arrow.triangle.2.circlepath",
                    tint: SettingsTheme.accent
                )
            }
            .buttonStyle(AboutActionButtonStyle())

            Divider().padding(.leading, 49).opacity(0.55)

            Button {
                isShowingResetConfirmation = true
            } label: {
                aboutActionLabel(
                    title: "恢复所有设置",
                    detail: "保留当前的开机启动状态",
                    icon: "arrow.counterclockwise",
                    tint: .red
                )
            }
            .buttonStyle(AboutActionButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .background(aboutCardBackground)
    }

    private func aboutActionLabel(title: String, detail: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                Text(detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func aboutInfoRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
        .font(.system(size: 11.5))
    }

    private var aboutCardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(SettingsTheme.cardFill)
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(SettingsTheme.cardBorder, lineWidth: 0.7)
            }
    }

    private func checkForUpdates() {
        UpdateManager.shared.checkForUpdates()
    }
}

struct PiPanelIdentityCard: View {
    let version: String
    var title = "PiPanel"
    var tagline = "FLOAT YOUR FOCUS"
    var variant = 0

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false
    @State private var hoverLocation = CGPoint.zero

    var body: some View {
        GeometryReader { proxy in
            let horizontal = normalized(hoverLocation.x, length: proxy.size.width)
            let vertical = normalized(hoverLocation.y, length: proxy.size.height)
            let tiltAmount = isHovering ? min(5.5, hypot(horizontal, vertical) * 5.5) : 0

            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(cardGradient)

                PiPanelCardArtwork(isHovering: isHovering, variant: variant)
                    .frame(height: proxy.size.height * 0.58)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(13)

                VStack(alignment: .leading, spacing: 0) {
                    Spacer()

                    Text(title)
                        .font(.system(size: 28, weight: .black, design: .rounded))
                        .tracking(-1)
                        .foregroundStyle(Color.aboutCardInk)

                    Text(tagline)
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .tracking(1.35)
                        .foregroundStyle(Color.aboutCardInk.opacity(0.76))
                        .padding(.top, 1)

                    HStack {
                        Label("macOS", systemImage: "apple.logo")
                        Spacer()
                        Text("V\(version)")
                    }
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.aboutCardInk.opacity(0.70))
                    .padding(.top, 20)
                }
                .padding(18)

                LinearGradient(
                    colors: [.clear, .white.opacity(0.32), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(width: 72)
                .rotationEffect(.degrees(18))
                .offset(x: isHovering ? proxy.size.width * 0.8 : -proxy.size.width * 0.8)
                .blendMode(.screen)
                .animation(.easeOut(duration: 0.72), value: isHovering)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.white.opacity(colorScheme == .dark ? 0.12 : 0.52), lineWidth: 0.8)
            }
            .rotation3DEffect(
                .degrees(tiltAmount),
                axis: (x: -vertical, y: horizontal, z: 0),
                perspective: 0.62
            )
            .scaleEffect(isHovering ? 1.018 : 1)
            .offset(y: isHovering ? -6 : 0)
            .shadow(
                color: .black.opacity(isHovering ? 0.18 : 0.10),
                radius: isHovering ? 20 : 12,
                y: isHovering ? 13 : 7
            )
            .animation(.spring(response: 0.42, dampingFraction: 0.78), value: isHovering)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoverLocation = location
                    if !isHovering { isHovering = true }
                case .ended:
                    isHovering = false
                    hoverLocation = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
                }
            }
        }
    }

    private var cardGradient: LinearGradient {
        LinearGradient(
            colors: cardColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var cardColors: [Color] {
        if colorScheme == .dark {
            switch variant % 4 {
            case 1: return [Color(red: 0.23, green: 0.16, blue: 0.27), Color(red: 0.12, green: 0.12, blue: 0.21)]
            case 2: return [Color(red: 0.12, green: 0.24, blue: 0.24), Color(red: 0.09, green: 0.14, blue: 0.20)]
            case 3: return [Color(red: 0.25, green: 0.20, blue: 0.12), Color(red: 0.16, green: 0.12, blue: 0.17)]
            default: return [Color(red: 0.18, green: 0.19, blue: 0.29), Color(red: 0.12, green: 0.14, blue: 0.22)]
            }
        }

        switch variant % 4 {
        case 1: return [Color(red: 1.00, green: 0.92, blue: 0.91), Color(red: 0.94, green: 0.90, blue: 1.00)]
        case 2: return [Color(red: 0.89, green: 0.98, blue: 0.93), Color(red: 0.88, green: 0.94, blue: 1.00)]
        case 3: return [Color(red: 1.00, green: 0.96, blue: 0.82), Color(red: 0.95, green: 0.89, blue: 0.95)]
        default: return [Color(red: 0.97, green: 0.97, blue: 0.88), Color(red: 0.90, green: 0.94, blue: 0.99)]
        }
    }

    private func normalized(_ value: CGFloat, length: CGFloat) -> CGFloat {
        guard length > 0 else { return 0 }
        return max(-1, min(1, value / length * 2 - 1))
    }
}

private struct PiPanelCardArtwork: View {
    let isHovering: Bool
    let variant: Int

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                AboutBlobShape()
                    .fill(
                        LinearGradient(
                            colors: artworkColors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .scaleEffect(isHovering ? 1.06 : 1, anchor: .topLeading)
                    .offset(x: isHovering ? 5 : 0, y: isHovering ? -3 : 0)

                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(.white.opacity(0.72), lineWidth: 3.5)
                    .frame(width: proxy.size.width * 0.50, height: proxy.size.height * 0.34)
                    .offset(x: proxy.size.width * 0.13, y: proxy.size.height * 0.12)

                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.white.opacity(0.90))
                    .frame(width: proxy.size.width * 0.31, height: proxy.size.height * 0.21)
                    .overlay {
                        Image(systemName: "pip.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(artworkColors[0])
                    }
                    .offset(
                        x: isHovering ? proxy.size.width * 0.26 : proxy.size.width * 0.20,
                        y: isHovering ? proxy.size.height * 0.24 : proxy.size.height * 0.20
                    )
                    .shadow(color: .black.opacity(0.16), radius: 8, y: 4)

                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(.white.opacity(0.75 - Double(index) * 0.16))
                        .frame(width: 7 - CGFloat(index), height: 7 - CGFloat(index))
                        .offset(
                            x: -proxy.size.width * 0.34 + CGFloat(index) * 15,
                            y: -proxy.size.height * 0.36 + (isHovering ? CGFloat(index) * -3 : 0)
                        )
                }
            }
            .animation(.spring(response: 0.55, dampingFraction: 0.72), value: isHovering)
            .animation(.easeInOut(duration: 0.28), value: variant)
        }
    }

    private var artworkColors: [Color] {
        switch variant % 4 {
        case 1:
            return [Color(red: 0.92, green: 0.28, blue: 0.47), Color(red: 0.49, green: 0.28, blue: 0.91)]
        case 2:
            return [Color(red: 0.08, green: 0.62, blue: 0.58), Color(red: 0.10, green: 0.43, blue: 0.96)]
        case 3:
            return [Color(red: 0.96, green: 0.54, blue: 0.13), Color(red: 0.76, green: 0.27, blue: 0.65)]
        default:
            return [Color(red: 0.27, green: 0.36, blue: 0.98), Color(red: 0.83, green: 0.29, blue: 0.55)]
        }
    }
}

private struct AboutBlobShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX * 0.37, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: rect.maxX * 0.52, y: rect.maxY * 0.45),
            control1: CGPoint(x: rect.maxX * 0.62, y: rect.minY),
            control2: CGPoint(x: rect.maxX * 0.27, y: rect.maxY * 0.28)
        )
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY * 0.68),
            control1: CGPoint(x: rect.maxX * 0.72, y: rect.maxY * 0.62),
            control2: CGPoint(x: rect.maxX * 0.82, y: rect.maxY * 0.42)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct AboutActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background(Color.primary.opacity(configuration.isPressed ? 0.075 : 0.001))
    }
}

private extension Color {
    static let aboutCardInk = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(red: 0.88, green: 0.90, blue: 1, alpha: 1)
            : NSColor(red: 0.24, green: 0.25, blue: 0.47, alpha: 1)
    })
}
