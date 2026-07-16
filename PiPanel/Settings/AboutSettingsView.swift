import SwiftUI

struct AboutSettingsView: View {
    @State private var isShowingResetConfirmation = false
    @State private var resetErrorMessage: String?

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
        ScrollView {
            HStack(alignment: .center, spacing: 18) {
                AboutIdentityCard(version: shortVersion)
                    .frame(minWidth: 170, maxWidth: 280)
                    .frame(height: 365)

                detailsColumn
                    .frame(minWidth: 190, maxWidth: 330)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.top, 22)
            .padding(.bottom, 26)
        }
        .confirmationDialog(
            "恢复所有设置到默认？",
            isPresented: $isShowingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("恢复默认", role: .destructive) {
                SettingsStore.shared.resetToDefaults()
                LaunchAtLoginManager.shared.resetToDefault()
                resetErrorMessage = LaunchAtLoginManager.shared.lastError
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("开机启动、画面参数、自动化、快捷键和外观等可配置项都会恢复到初始值；支持实时更新的设置会立即应用到已打开的画中画")
        }
        .alert(
            "部分设置未能恢复",
            isPresented: Binding(
                get: { resetErrorMessage != nil },
                set: { if !$0 { resetErrorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(resetErrorMessage ?? "")
        }
    }

    private var detailsColumn: some View {
        VStack(spacing: 12) {
            VStack(spacing: 11) {
                Image(nsImage: appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 76, height: 76)
                    .shadow(color: SettingsTheme.accent.opacity(0.20), radius: 13, y: 6)

                VStack(spacing: 3) {
                    Text("PiPanel")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("让每个窗口，都恰到好处地悬浮")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Divider().opacity(0.55)

                VStack(spacing: 8) {
                    aboutInfoRow("版本", value: shortVersion)
                    aboutInfoRow("构建版本", value: buildNumber)
                    aboutInfoRow("平台", value: "macOS")
                }
            }
            .padding(16)
            .background(aboutCardBackground)

            VStack(spacing: 0) {
                Button(action: checkForUpdates) {
                    HStack(spacing: 9) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(SettingsTheme.accent)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("检查更新")
                                .font(.system(size: 12.5, weight: .medium))
                            Text("每天自动检查并在后台安装")
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
                .buttonStyle(AboutActionButtonStyle())

                Divider().padding(.horizontal, 13).opacity(0.55)

                Button {
                    isShowingResetConfirmation = true
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.red)
                            .frame(width: 20)
                        Text("恢复所有设置")
                            .font(.system(size: 12.5, weight: .medium))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(AboutActionButtonStyle())
            }
            .background(aboutCardBackground)

            Text("© \(copyrightYear) PiPanel · Made for macOS")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.top, 1)
        }
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

private struct AboutIdentityCard: View {
    let version: String

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

                PiPanelCardArtwork(isHovering: isHovering)
                    .frame(height: proxy.size.height * 0.58)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(13)

                VStack(alignment: .leading, spacing: 0) {
                    Spacer()

                    Text("PiPanel")
                        .font(.system(size: 28, weight: .black, design: .rounded))
                        .tracking(-1)
                        .foregroundStyle(Color.aboutCardInk)

                    Text("FLOAT YOUR FOCUS")
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
            colors: colorScheme == .dark
                ? [Color(red: 0.18, green: 0.19, blue: 0.29), Color(red: 0.12, green: 0.14, blue: 0.22)]
                : [Color(red: 0.97, green: 0.97, blue: 0.88), Color(red: 0.90, green: 0.94, blue: 0.99)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func normalized(_ value: CGFloat, length: CGFloat) -> CGFloat {
        guard length > 0 else { return 0 }
        return max(-1, min(1, value / length * 2 - 1))
    }
}

private struct PiPanelCardArtwork: View {
    let isHovering: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                AboutBlobShape()
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.27, green: 0.36, blue: 0.98), Color(red: 0.83, green: 0.29, blue: 0.55)],
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
                            .foregroundStyle(Color(red: 0.30, green: 0.37, blue: 0.96))
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
