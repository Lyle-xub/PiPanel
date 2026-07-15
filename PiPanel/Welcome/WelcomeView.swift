import AppKit
import SwiftUI

private enum WelcomePage {
    case hero
    case permissions
}

struct WelcomeView: View {
    let onRequestCompact: (Bool) -> Void
    let onContinue: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var page: WelcomePage = .hero
    @State private var isCompact = false
    @State private var revealsHeroText = false
    @State private var hasStartedIntro = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if page == .hero {
                    RefractiveLightField(
                        isExpanded: !isCompact,
                        reduceMotion: reduceMotion
                    )
                    HeroWelcomePage(
                        revealsText: revealsHeroText,
                        showsChrome: isCompact,
                        onContinue: showPermissions
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
                } else {
                    PermissionWelcomePage(onContinue: onContinue)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: isCompact ? 28 : 0,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: isCompact ? 28 : 0,
                    style: .continuous
                )
                .strokeBorder(Color.white.opacity(isCompact ? 0.20 : 0), lineWidth: 0.8)
            }
        }
        .ignoresSafeArea()
        .task { await runOpeningSequence() }
    }

    @MainActor
    private func runOpeningSequence() async {
        guard !hasStartedIntro else { return }
        hasStartedIntro = true

        if reduceMotion {
            onRequestCompact(false)
            isCompact = true
            revealsHeroText = true
            return
        }

        try? await Task.sleep(nanoseconds: 700_000_000)
        guard !Task.isCancelled else { return }

        onRequestCompact(true)
        withAnimation(.easeInOut(duration: 1.45)) {
            isCompact = true
        }

        try? await Task.sleep(nanoseconds: 560_000_000)
        guard !Task.isCancelled else { return }
        revealsHeroText = true
    }

    private func showPermissions() {
        if reduceMotion {
            page = .permissions
        } else {
            withAnimation(.spring(response: 0.62, dampingFraction: 0.9)) {
                page = .permissions
            }
        }
    }
}

private struct HeroWelcomePage: View {
    let revealsText: Bool
    let showsChrome: Bool
    let onContinue: () -> Void

    var body: some View {
        ZStack {
            VStack(spacing: 25) {
                WaveRevealText(
                    text: "你的窗口，随心悬浮。",
                    isRevealed: revealsText
                )

                Text("PiPanel 将任何窗口变成轻巧、专注的画中画")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.76))
                    .blur(radius: revealsText ? 0 : 10)
                    .opacity(revealsText ? 1 : 0)
                    .offset(y: revealsText ? 0 : 18)
                    .animation(.easeOut(duration: 0.75).delay(0.35), value: revealsText)

                Button(action: onContinue) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Color.arcIndigo)
                        .frame(width: 62, height: 46)
                }
                .buttonStyle(ArcArrowButtonStyle())
                .blur(radius: revealsText ? 0 : 9)
                .opacity(revealsText ? 1 : 0)
                .offset(y: revealsText ? 0 : 16)
                .animation(.spring(response: 0.6, dampingFraction: 0.86).delay(0.58), value: revealsText)
            }

            if showsChrome {
                ArcWindowChrome()
                    .transition(.opacity)
            }
        }
    }
}

private struct WaveRevealText: View {
    let text: String
    let isRevealed: Bool

    private var characters: [(Int, Character)] {
        Array(text.enumerated())
    }

    var body: some View {
        HStack(spacing: -1.5) {
            ForEach(characters, id: \.0) { index, character in
                Text(String(character))
                    .font(.system(size: 50, weight: .bold, design: .rounded))
                    .tracking(-1.1)
                    .foregroundStyle(.white)
                    .blur(radius: isRevealed ? 0 : 14)
                    .opacity(isRevealed ? 1 : 0)
                    .offset(
                        x: isRevealed ? 0 : CGFloat(sin(Double(index) * 0.9)) * 5,
                        y: isRevealed ? 0 : 34 + CGFloat(sin(Double(index) * 1.25)) * 13
                    )
                    .animation(
                        .spring(response: 0.72, dampingFraction: 0.82)
                            .delay(Double(index) * 0.038),
                        value: isRevealed
                    )
            }
        }
        .shadow(color: .black.opacity(0.09), radius: 14, y: 8)
    }
}

private struct ArcWindowChrome: View {
    var body: some View {
        VStack {
            HStack(spacing: 9) {
                Circle().fill(.black.opacity(0.12)).frame(width: 12, height: 12)
                Circle().fill(.black.opacity(0.10)).frame(width: 12, height: 12)
                Circle().fill(.black.opacity(0.08)).frame(width: 12, height: 12)
                Spacer()
            }
            .padding(.top, 19)
            .padding(.leading, 20)
            Spacer()
        }
        .allowsHitTesting(false)
    }
}

private struct PermissionWelcomePage: View {
    let onContinue: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RefractiveLightField(isExpanded: false, reduceMotion: reduceMotion)

                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: proxy.size.width * 0.47)

                    PiPanelVectorShowcase()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                PermissionSetupPanel(onContinue: onContinue)
                    .frame(width: proxy.size.width * 0.49, height: proxy.size.height)
                    .clipShape(WavyTrailingPanelShape())
            }
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 9) {
                Circle().fill(.red.opacity(0.70)).frame(width: 12, height: 12)
                Circle().fill(.yellow.opacity(0.70)).frame(width: 12, height: 12)
                Circle().fill(.green.opacity(0.70)).frame(width: 12, height: 12)
            }
            .padding(.top, 19)
            .padding(.leading, 20)
        }
    }
}

private struct PermissionSetupPanel: View {
    let onContinue: () -> Void

    @ObservedObject private var permissions = PermissionsManager.shared

    private var canFinish: Bool {
        permissions.hasAccessibilityAccess
            && (permissions.hasScreenRecordingAccess || permissions.didRequestScreenRecordingAccess)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 58)

            PiPanelVectorMark()
                .frame(width: 54, height: 54)

            Text("为 PiPanel 做好准备")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .tracking(-0.5)
                .padding(.top, 18)

            Text("只需两项系统权限，用于读取画面并操作窗口。\nPiPanel 不会保存或上传屏幕内容。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.top, 9)

            VStack(spacing: 10) {
                OnboardingPermissionRow(
                    icon: "rectangle.inset.filled",
                    title: "屏幕录制",
                    detail: permissions.needsRelaunchForScreenRecording
                        ? "已请求，重启后生效"
                        : "读取窗口画面",
                    isGranted: permissions.hasScreenRecordingAccess,
                    isPending: permissions.needsRelaunchForScreenRecording
                ) {
                    permissions.requestScreenRecordingAccess()
                    permissions.openScreenRecordingSettings()
                }

                OnboardingPermissionRow(
                    icon: "hand.point.up.left.fill",
                    title: "辅助功能",
                    detail: "定位并操作窗口",
                    isGranted: permissions.hasAccessibilityAccess,
                    isPending: false
                ) {
                    permissions.requestAccessibilityAccess()
                    permissions.openAccessibilitySettings()
                }
            }
            .padding(.top, 25)
            .frame(maxWidth: 370)

            Button(action: onContinue) {
                HStack(spacing: 7) {
                    Text("开始使用")
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .bold))
                }
            }
            .buttonStyle(ArcPrimaryButtonStyle(enabled: canFinish))
            .disabled(!canFinish)
            .padding(.top, 22)

            Button("稍后设置", action: onContinue)
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.top, 12)

            Spacer(minLength: 38)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 34)
        .background(Color.arcPanel)
    }
}

private struct OnboardingPermissionRow: View {
    let icon: String
    let title: String
    let detail: String
    let isGranted: Bool
    let isPending: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isGranted ? Color.green : Color.arcIndigo)
                .frame(width: 34, height: 34)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill((isGranted ? Color.green : Color.arcIndigo).opacity(0.10))
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.green)
            } else {
                Button(isPending ? "已请求" : "获取权限", action: action)
                    .buttonStyle(ArcPermissionButtonStyle(isPending: isPending))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 62)
        .background {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.065), lineWidth: 0.7)
        }
    }
}

private struct PiPanelVectorShowcase: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let raw = (sin(time * 0.72 - .pi / 2) + 1) / 2
            let progress = reduceMotion ? 0.72 : smoothStep(raw)

            VStack(spacing: 21) {
                VStack(spacing: 6) {
                    Text("一甩，即刻悬浮")
                        .font(.system(size: 27, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("窗口从桌面轻盈地来到你身边")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.68))
                }

                ZStack {
                    VectorDesktopWindow()
                        .frame(width: 430, height: 280)

                    FlightArc()
                        .trim(from: 0, to: progress)
                        .stroke(
                            Color.white.opacity(0.34),
                            style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [5, 7])
                        )
                        .frame(width: 300, height: 170)

                    VectorPiPWindow()
                        .frame(
                            width: mix(126, 192, progress),
                            height: mix(78, 118, progress)
                        )
                        .rotationEffect(.degrees(mix(-4, 1.5, progress)))
                        .offset(
                            x: mix(-58, 164, progress),
                            y: mix(22, -103, progress)
                        )
                        .shadow(color: .black.opacity(0.20), radius: 16, y: 10)
                }
                .frame(width: 560, height: 360)
            }
            .padding(.leading, 12)
        }
    }
}

private struct VectorDesktopWindow: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(.white.opacity(0.52)).frame(width: 8, height: 8)
                Circle().fill(.white.opacity(0.40)).frame(width: 8, height: 8)
                Circle().fill(.white.opacity(0.30)).frame(width: 8, height: 8)
                Spacer()
                Capsule().fill(.white.opacity(0.12)).frame(width: 120, height: 13)
                Spacer()
            }
            .padding(.horizontal, 15)
            .frame(height: 38)
            .background(.white.opacity(0.08))

            HStack(spacing: 0) {
                VStack(spacing: 14) {
                    ForEach(0..<4, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 5)
                            .fill(.white.opacity(index == 1 ? 0.24 : 0.09))
                            .frame(height: 24)
                    }
                    Spacer()
                }
                .padding(13)
                .frame(width: 105)
                .background(.black.opacity(0.07))

                LazyVGrid(columns: [.init(), .init()], spacing: 10) {
                    ForEach(0..<4, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(.white.opacity(index == 0 ? 0.20 : 0.095))
                            .frame(height: 92)
                    }
                }
                .padding(14)
            }
        }
        .background(.ultraThinMaterial.opacity(0.34))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.26), lineWidth: 1)
        }
    }
}

private struct VectorPiPWindow: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
            LinearGradient(
                colors: [.white.opacity(0.28), .white.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            PiPanelVectorMark(strokeColor: .white)
                .padding(24)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.48), lineWidth: 1.1)
        }
    }
}

private struct PiPanelVectorMark: View {
    var strokeColor: Color = .arcIndigo

    @State private var draws = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .trim(from: 0, to: draws ? 1 : 0.02)
                .stroke(strokeColor, style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                .frame(width: 42, height: 34)
                .offset(x: -4, y: -4)

            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .trim(from: 0, to: draws ? 1 : 0.02)
                .stroke(strokeColor.opacity(0.72), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .frame(width: 29, height: 23)
                .offset(x: 9, y: 9)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
                draws = true
            }
        }
    }
}

private struct WavyTrailingPanelShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: rect.width - 14, y: 0))

        let step: CGFloat = 18
        var y: CGFloat = 0
        while y <= rect.height {
            let x = rect.width - 14 + sin(y / step * .pi) * 5.5
            path.addLine(to: CGPoint(x: x, y: y))
            y += 4
        }

        path.addLine(to: CGPoint(x: 0, y: rect.height))
        path.closeSubpath()
        return path
    }
}

private struct FlightArc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 45, y: rect.maxY - 30))
        path.addCurve(
            to: CGPoint(x: rect.maxX - 25, y: rect.minY + 28),
            control1: CGPoint(x: rect.midX - 40, y: rect.maxY + 8),
            control2: CGPoint(x: rect.midX + 28, y: rect.minY - 18)
        )
        return path
    }
}

private struct RefractiveLightField: View {
    let isExpanded: Bool
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion)) { context in
            let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate

            Canvas(rendersAsynchronously: true) { graphics, size in
                graphics.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .linearGradient(
                        Gradient(colors: [Color.arcDeepBlue, Color.arcIndigo, Color.arcSky]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: size.width, y: size.height)
                    )
                )

                graphics.blendMode = .plusLighter
                for index in 0..<7 {
                    let phase = time * (0.22 + Double(index) * 0.025) + Double(index) * 0.9
                    let center = CGPoint(
                        x: size.width * (0.5 + cos(phase) * (isExpanded ? 0.24 : 0.16)),
                        y: size.height * (0.5 + sin(phase * 1.17) * (isExpanded ? 0.27 : 0.18))
                    )
                    let diameter = min(size.width, size.height)
                        * (isExpanded ? 0.62 : 0.52)
                        * (0.72 + CGFloat(index) * 0.07)
                    let rect = CGRect(
                        x: center.x - diameter / 2,
                        y: center.y - diameter / 2,
                        width: diameter * (1 + 0.13 * sin(phase * 1.4)),
                        height: diameter * (1 + 0.16 * cos(phase * 1.1))
                    )
                    let path = LiquidOrbPath.make(in: rect, phase: phase, lobes: 6 + index)
                    graphics.fill(
                        path,
                        with: .radialGradient(
                            Gradient(colors: [
                                Color.white.opacity(index.isMultiple(of: 2) ? 0.24 : 0.12),
                                Color.arcViolet.opacity(0.12),
                                Color.clear
                            ]),
                            center: center,
                            startRadius: 0,
                            endRadius: diameter * 0.58
                        )
                    )
                }
            }
            .blur(radius: isExpanded ? 22 : 34)
            .scaleEffect(isExpanded ? 1.13 : 1)
            .overlay {
                RadialGradient(
                    colors: [.white.opacity(isExpanded ? 0.15 : 0.07), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: 520
                )
                .blendMode(.screen)
            }
        }
        .background(Color.arcDeepBlue)
        .animation(.easeInOut(duration: 1.45), value: isExpanded)
    }
}

private enum LiquidOrbPath {
    static func make(in rect: CGRect, phase: Double, lobes: Int) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radiusX = rect.width / 2
        let radiusY = rect.height / 2
        let points = 96

        for index in 0...points {
            let angle = Double(index) / Double(points) * .pi * 2
            let distortion = 1
                + sin(angle * Double(lobes) + phase * 1.7) * 0.055
                + cos(angle * 3 - phase) * 0.035
            let point = CGPoint(
                x: center.x + cos(angle) * radiusX * distortion,
                y: center.y + sin(angle) * radiusY * distortion
            )
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

private struct ArcArrowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(.white.opacity(configuration.isPressed ? 0.76 : 0.92))
            }
            .shadow(color: .black.opacity(0.12), radius: 12, y: 7)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

private struct ArcPermissionButtonStyle: ButtonStyle {
    let isPending: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(isPending ? Color.secondary : Color.white)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background {
                Capsule().fill(
                    isPending
                        ? Color.primary.opacity(0.07)
                        : Color.arcIndigo.opacity(configuration.isPressed ? 0.78 : 1)
                )
            }
    }
}

private struct ArcPrimaryButtonStyle: ButtonStyle {
    let enabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 220, height: 42)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.arcIndigo.opacity(enabled ? (configuration.isPressed ? 0.78 : 1) : 0.34))
            }
            .scaleEffect(configuration.isPressed && enabled ? 0.98 : 1)
    }
}

private func smoothStep(_ value: Double) -> CGFloat {
    let clamped = max(0, min(1, value))
    return CGFloat(clamped * clamped * (3 - 2 * clamped))
}

private func mix(_ start: CGFloat, _ end: CGFloat, _ progress: CGFloat) -> CGFloat {
    start + (end - start) * progress
}

private extension Color {
    static let arcDeepBlue = Color(red: 0.07, green: 0.10, blue: 0.72)
    static let arcIndigo = Color(red: 0.20, green: 0.24, blue: 0.98)
    static let arcSky = Color(red: 0.35, green: 0.65, blue: 1.0)
    static let arcViolet = Color(red: 0.56, green: 0.31, blue: 1.0)
    static let arcPanel = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1)
            : NSColor(red: 0.985, green: 0.985, blue: 0.99, alpha: 1)
    })
}

#Preview {
    WelcomeView(onRequestCompact: { _ in }, onContinue: {})
        .frame(width: 1120, height: 700)
}
