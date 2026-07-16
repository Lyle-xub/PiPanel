import AppKit
import AVKit
import SwiftUI

private enum WelcomePage {
    case hero
    case permissions
    case tutorial
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
                } else if page == .permissions {
                    PermissionWelcomePage(onContinue: showTutorial)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    OnboardingTutorialPage(onFinish: onContinue)
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

    private func showTutorial() {
        if reduceMotion {
            page = .tutorial
        } else {
            withAnimation(.spring(response: 0.66, dampingFraction: 0.9)) {
                page = .tutorial
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

private enum TutorialStep: Int, CaseIterable, Identifiable {
    case corner
    case resize
    case control
    case fullscreen
    case videos

    var id: Int { rawValue }

    var eyebrow: String {
        switch self {
        case .corner: "01  轻轻靠近"
        case .resize: "02  随手调整"
        case .control: "03  直接操作"
        case .fullscreen: "04  始终陪伴"
        case .videos: "完成  认识 PiPanel"
        }
    }

    var title: String {
        switch self {
        case .corner: "窗口右上角，藏着一个画中画按钮"
        case .resize: "拖动画中画边缘，尺寸刚刚好"
        case .control: "双击画中画，直接控制原来的软件"
        case .fullscreen: "其他软件全屏，它也依然留在身边"
        case .videos: "五个小技巧，让 PiPanel 更顺手"
        }
    }

    var detail: String {
        switch self {
        case .corner: "把指针移到桌面任意窗口的右上角，点击浮现的按钮，就能把这个窗口轻巧地带出来。"
        case .resize: "靠近任意边缘，看到调整尺寸的指针后拖动；画面和源窗口会同步适配。"
        case .control: "双击进入控制模式后，鼠标与键盘会回到源软件；移开指针即可退出。"
        case .fullscreen: "PiPanel 会跨桌面、跨空间悬浮。看视频、演示或专注工作时，重要内容不会被盖住。"
        case .videos: "选择下方主题，在中央窗口观看实际操作。你也可以稍后在菜单栏里继续探索。"
        }
    }

    var symbol: String {
        switch self {
        case .corner: "pip.enter"
        case .resize: "arrow.up.left.and.arrow.down.right"
        case .control: "cursorarrow.click.2"
        case .fullscreen: "rectangle.inset.filled.and.person.filled"
        case .videos: "play.rectangle.fill"
        }
    }
}

private struct TutorialVideo: Identifiable, Equatable {
    let id: String
    let title: String
    let caption: String
    let symbol: String

    static let all: [TutorialVideo] = [
        .init(id: "全屏控制", title: "全屏控制", caption: "全屏空间里仍能查看和操作", symbol: "rectangle.inset.filled"),
        .init(id: "文件拖拽", title: "文件拖拽", caption: "在窗口之间自然拖动文件", symbol: "doc.on.doc"),
        .init(id: "视频播放", title: "视频播放", caption: "边工作，边保留重要画面", symbol: "play.fill"),
        .init(id: "贴边隐藏", title: "贴边隐藏", caption: "暂时收起，需要时再唤回", symbol: "rectangle.lefthalf.inset.filled"),
        .init(id: "音乐控制", title: "音乐控制", caption: "悬浮查看歌词和播放状态", symbol: "music.note")
    ]
}

private struct OnboardingTutorialPage: View {
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: TutorialStep = .corner
    @State private var direction = 1
    @State private var selectedVideo = TutorialVideo.all[0]

    var body: some View {
        ZStack {
            Color.paperCream

            PaperTexture()
                .opacity(0.48)

            VStack(spacing: 0) {
                tutorialHeader
                    .padding(.horizontal, 34)
                    .padding(.top, 26)

                ZStack {
                    if step == .videos {
                        TutorialVideoGallery(selectedVideo: $selectedVideo)
                            .transition(pageTransition)
                    } else {
                        HStack(spacing: 42) {
                            TutorialCopy(step: step)
                                .frame(width: 330, alignment: .leading)

                            TutorialStage(step: step, reduceMotion: reduceMotion)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .padding(.horizontal, 48)
                        .padding(.vertical, 24)
                        .transition(pageTransition)
                        .id(step)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                tutorialFooter
                    .padding(.horizontal, 34)
                    .padding(.bottom, 24)
            }
        }
        .foregroundStyle(Color.inkBlue)
    }

    private var pageTransition: AnyTransition {
        let edge: Edge = direction > 0 ? .trailing : .leading
        return .asymmetric(
            insertion: .move(edge: edge).combined(with: .opacity),
            removal: .move(edge: edge == .trailing ? .leading : .trailing).combined(with: .opacity)
        )
    }

    private var tutorialHeader: some View {
        HStack(spacing: 14) {
            PiPanelVectorMark(strokeColor: .arcIndigo)
                .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text("PiPanel 小小上手课")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                Text("大约 40 秒 · 随时可以跳过")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.inkBlue.opacity(0.48))
            }

            Spacer()

            HStack(spacing: 7) {
                ForEach(TutorialStep.allCases) { item in
                    Capsule()
                        .fill(item == step ? Color.arcIndigo : Color.inkBlue.opacity(0.13))
                        .frame(width: item == step ? 28 : 8, height: 8)
                        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: step)
                }
            }

            Button("跳过", action: onFinish)
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.inkBlue.opacity(0.55))
                .padding(.leading, 18)
        }
    }

    private var tutorialFooter: some View {
        HStack {
            Button {
                move(by: -1)
            } label: {
                Label("上一步", systemImage: "arrow.left")
            }
            .buttonStyle(SketchSecondaryButtonStyle())
            .opacity(step == .corner ? 0 : 1)
            .disabled(step == .corner)

            Spacer()

            Text(step == .videos ? "准备好后，就从菜单栏开始吧" : "跟着图里的动作试一试")
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(Color.inkBlue.opacity(0.42))

            Spacer()

            Button {
                if step == .videos {
                    onFinish()
                } else {
                    move(by: 1)
                }
            } label: {
                HStack(spacing: 8) {
                    Text(step == .videos ? "开始使用" : "下一步")
                    Image(systemName: step == .videos ? "sparkles" : "arrow.right")
                }
            }
            .buttonStyle(SketchPrimaryButtonStyle())
        }
    }

    private func move(by offset: Int) {
        let target = min(max(step.rawValue + offset, 0), TutorialStep.allCases.count - 1)
        guard let newStep = TutorialStep(rawValue: target), newStep != step else { return }
        direction = offset
        if reduceMotion {
            step = newStep
        } else {
            withAnimation(.spring(response: 0.62, dampingFraction: 0.88)) {
                step = newStep
            }
        }
    }
}

private struct TutorialCopy: View {
    let step: TutorialStep

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(step.eyebrow)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .tracking(1.3)
                .foregroundStyle(Color.arcIndigo)

            Text(step.title)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .tracking(-0.8)
                .lineSpacing(2)
                .padding(.top, 14)

            DoodleUnderline()
                .stroke(Color.sunnyYellow, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .frame(width: 180, height: 15)
                .rotationEffect(.degrees(-1.4))
                .padding(.top, 4)

            Text(step.detail)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Color.inkBlue.opacity(0.68))
                .lineSpacing(6)
                .padding(.top, 20)

            HStack(spacing: 9) {
                Image(systemName: step.symbol)
                    .font(.system(size: 14, weight: .bold))
                Text(hint)
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
            }
            .foregroundStyle(Color.arcIndigo)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(Color.arcIndigo.opacity(0.08), in: Capsule())
            .overlay { Capsule().stroke(Color.arcIndigo.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
            .padding(.top, 26)
        }
    }

    private var hint: String {
        switch step {
        case .corner: "移到右上角 → 点击"
        case .resize: "靠近边缘 → 拖动"
        case .control: "快速双击两下"
        case .fullscreen: "放心进入全屏"
        case .videos: ""
        }
    }
}

private struct TutorialStage: View {
    let step: TutorialStep
    let reduceMotion: Bool

    @State private var animates = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(Color.white.opacity(0.72))
                .shadow(color: Color.inkBlue.opacity(0.08), radius: 24, y: 13)
                .overlay {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(Color.inkBlue.opacity(0.13), style: StrokeStyle(lineWidth: 1.5, dash: [8, 5]))
                }

            if step == .fullscreen {
                FullscreenBackdrop()
            } else {
                IllustratedDesktopWindow()
                    .frame(width: 560, height: 350)
                    .rotationEffect(.degrees(-0.35))
            }

            switch step {
            case .corner:
                CornerLessonOverlay(animates: animates)
            case .resize:
                ResizeLessonOverlay(animates: animates)
            case .control:
                ControlLessonOverlay(animates: animates)
            case .fullscreen:
                FullscreenLessonOverlay(animates: animates)
            case .videos:
                EmptyView()
            }
        }
        .padding(8)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                animates = true
            }
        }
    }
}

private struct IllustratedDesktopWindow: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(Color.red.opacity(0.65)).frame(width: 10, height: 10)
                Circle().fill(Color.orange.opacity(0.65)).frame(width: 10, height: 10)
                Circle().fill(Color.green.opacity(0.62)).frame(width: 10, height: 10)
                Spacer()
                RoundedRectangle(cornerRadius: 6).fill(Color.inkBlue.opacity(0.07)).frame(width: 190, height: 20)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(Color.inkBlue.opacity(0.035))

            HStack(spacing: 14) {
                VStack(spacing: 12) {
                    ForEach(0..<5, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 7)
                            .fill(index == 1 ? Color.arcIndigo.opacity(0.16) : Color.inkBlue.opacity(0.055))
                            .frame(height: 27)
                    }
                    Spacer()
                }
                .frame(width: 116)

                VStack(alignment: .leading, spacing: 13) {
                    RoundedRectangle(cornerRadius: 9).fill(Color.arcIndigo.opacity(0.12)).frame(width: 160, height: 22)
                    RoundedRectangle(cornerRadius: 8).fill(Color.inkBlue.opacity(0.065)).frame(height: 92)
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 10).fill(Color.sunnyYellow.opacity(0.35))
                        RoundedRectangle(cornerRadius: 10).fill(Color.arcSky.opacity(0.18))
                    }
                    .frame(height: 105)
                    Spacer()
                }
            }
            .padding(18)
        }
        .background(Color.white.opacity(0.86))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.inkBlue.opacity(0.42), style: StrokeStyle(lineWidth: 1.7, lineCap: .round, dash: [10, 3, 3, 4]))
        }
    }
}

private struct CornerLessonOverlay: View {
    let animates: Bool

    var body: some View {
        ZStack {
            DoodleArrow()
                .trim(from: 0, to: animates ? 1 : 0.18)
                .stroke(Color.arcIndigo, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                .frame(width: 150, height: 100)
                .rotationEffect(.degrees(-18))
                .offset(x: 170, y: -120)

            Circle()
                .stroke(Color.sunnyYellow.opacity(animates ? 0.25 : 0.9), lineWidth: animates ? 14 : 3)
                .frame(width: animates ? 82 : 48, height: animates ? 82 : 48)
                .offset(x: 283, y: -179)

            Image(systemName: "pip.enter")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(Color.arcIndigo, in: Circle())
                .overlay { Circle().stroke(.white, lineWidth: 2) }
                .shadow(color: Color.arcIndigo.opacity(0.34), radius: 12, y: 6)
                .scaleEffect(animates ? 1.08 : 0.96)
                .offset(x: 283, y: -179)

            SketchNote(text: "就是这里！")
                .rotationEffect(.degrees(3))
                .offset(x: 188, y: -42)
        }
    }
}

private struct ResizeLessonOverlay: View {
    let animates: Bool

    var body: some View {
        ZStack {
            MiniPiPWindow()
                .frame(width: animates ? 360 : 300, height: animates ? 220 : 184)
                .offset(x: 110, y: 52)

            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 24, weight: .black))
                .foregroundStyle(Color.arcIndigo)
                .rotationEffect(.degrees(4))
                .offset(x: animates ? 294 : 258, y: animates ? 168 : 142)

            SketchNote(text: "抓住边缘拖一拖")
                .rotationEffect(.degrees(-3))
                .offset(x: 82, y: -108)
        }
    }
}

private struct ControlLessonOverlay: View {
    let animates: Bool

    var body: some View {
        ZStack {
            MiniPiPWindow()
                .frame(width: 350, height: 216)
                .offset(x: 100, y: 46)

            Image(systemName: "cursorarrow")
                .font(.system(size: 43, weight: .medium))
                .foregroundStyle(Color.inkBlue)
                .shadow(color: .white, radius: 1)
                .offset(x: 88, y: 48)

            ForEach(0..<2, id: \.self) { index in
                Circle()
                    .stroke(Color.sunnyYellow.opacity(animates ? 0.15 : 0.85), lineWidth: 3)
                    .frame(width: animates ? 80 + CGFloat(index * 18) : 32, height: animates ? 80 + CGFloat(index * 18) : 32)
                    .offset(x: 68, y: 27)
            }

            SketchNote(text: "双击后，直接点里面")
                .rotationEffect(.degrees(2))
                .offset(x: 105, y: -112)
        }
    }
}

private struct FullscreenBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.inkBlue, Color.arcDeepBlue], startPoint: .topLeading, endPoint: .bottomTrailing)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

            VStack(spacing: 18) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 76))
                    .foregroundStyle(.white.opacity(0.72))
                Text("其他软件正在全屏")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
        .padding(20)
    }
}

private struct FullscreenLessonOverlay: View {
    let animates: Bool

    var body: some View {
        ZStack {
            MiniPiPWindow()
                .frame(width: 260, height: 160)
                .rotationEffect(.degrees(animates ? 1.2 : -1.2))
                .offset(x: animates ? 205 : 190, y: animates ? -100 : -88)

            SketchNote(text: "全屏也不会消失 ✦")
                .rotationEffect(.degrees(-4))
                .offset(x: 112, y: 132)
        }
    }
}

private struct MiniPiPWindow: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.arcIndigo.opacity(0.94), Color.arcSky.opacity(0.82)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            PiPanelVectorMark(strokeColor: .white)
                .frame(width: 62, height: 62)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white, lineWidth: 2)
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.inkBlue.opacity(0.48), style: StrokeStyle(lineWidth: 1.5, dash: [9, 4]))
                .padding(-4)
        }
        .shadow(color: Color.inkBlue.opacity(0.25), radius: 18, y: 10)
    }
}

private struct SketchNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(Color.inkBlue)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(Color.sunnyYellow.opacity(0.88), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.inkBlue.opacity(0.42), style: StrokeStyle(lineWidth: 1.2, dash: [6, 3]))
            }
            .shadow(color: Color.inkBlue.opacity(0.08), radius: 5, y: 3)
    }
}

private struct TutorialVideoGallery: View {
    @Binding var selectedVideo: TutorialVideo

    var body: some View {
        HStack(spacing: 32) {
            VStack(alignment: .leading, spacing: 0) {
                Text(TutorialStep.videos.eyebrow)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .tracking(1.3)
                    .foregroundStyle(Color.arcIndigo)
                Text(TutorialStep.videos.title)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .tracking(-0.7)
                    .padding(.top, 10)
                Text(TutorialStep.videos.detail)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.inkBlue.opacity(0.62))
                    .lineSpacing(5)
                    .padding(.top, 12)

                VStack(spacing: 8) {
                    ForEach(TutorialVideo.all) { video in
                        Button {
                            selectedVideo = video
                        } label: {
                            HStack(spacing: 11) {
                                Image(systemName: video.symbol)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(video.title).font(.system(size: 12.5, weight: .bold, design: .rounded))
                                    Text(video.caption).font(.system(size: 9.5, weight: .medium, design: .rounded)).opacity(0.58)
                                }
                                Spacer()
                                if selectedVideo == video {
                                    Image(systemName: "play.fill").font(.system(size: 9, weight: .bold))
                                }
                            }
                            .foregroundStyle(selectedVideo == video ? Color.white : Color.inkBlue)
                            .padding(.horizontal, 12)
                            .frame(height: 48)
                            .background(
                                selectedVideo == video ? Color.arcIndigo : Color.white.opacity(0.58),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.inkBlue.opacity(selectedVideo == video ? 0 : 0.1), lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 18)
            }
            .frame(width: 310)

            TutorialVideoPlayer(video: selectedVideo)
                .frame(maxWidth: 610, maxHeight: 390)
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 20)
    }
}

private struct TutorialVideoPlayer: View {
    let video: TutorialVideo

    @State private var player = AVPlayer()
    @State private var didLoad = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(Color.red.opacity(0.7)).frame(width: 9, height: 9)
                Circle().fill(Color.orange.opacity(0.7)).frame(width: 9, height: 9)
                Circle().fill(Color.green.opacity(0.65)).frame(width: 9, height: 9)
                Spacer()
                Text(video.title)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.inkBlue.opacity(0.6))
                Spacer()
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.arcIndigo)
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(Color.white.opacity(0.84))

            ZStack {
                Color.inkBlue
                VideoPlayer(player: player)
                if !didLoad {
                    VStack(spacing: 12) {
                        Image(systemName: "film.stack")
                            .font(.system(size: 34))
                        Text("正在准备操作视频…")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.inkBlue.opacity(0.54), style: StrokeStyle(lineWidth: 1.7, dash: [10, 4, 2, 4]))
        }
        .shadow(color: Color.inkBlue.opacity(0.18), radius: 22, y: 12)
        .rotationEffect(.degrees(0.35))
        .onAppear { load(video) }
        .onChange(of: video) { _, newValue in load(newValue) }
        .onDisappear { player.pause() }
    }

    private func load(_ video: TutorialVideo) {
        let url = Bundle.main.url(forResource: video.id, withExtension: "mp4", subdirectory: "TutorialVideos")
            ?? Bundle.main.url(forResource: video.id, withExtension: "mp4")
        guard let url else {
            didLoad = false
            return
        }
        didLoad = true
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.play()
    }
}

private struct PaperTexture: View {
    var body: some View {
        Canvas { context, size in
            for x in stride(from: CGFloat(24), through: size.width, by: 42) {
                for y in stride(from: CGFloat(18), through: size.height, by: 38) {
                    let dot = CGRect(x: x, y: y, width: 1.5, height: 1.5)
                    context.fill(Path(ellipseIn: dot), with: .color(Color.inkBlue.opacity(0.09)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct DoodleUnderline: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 3, y: rect.midY + 2))
        path.addCurve(
            to: CGPoint(x: rect.maxX - 3, y: rect.midY - 1),
            control1: CGPoint(x: rect.width * 0.28, y: rect.minY - 1),
            control2: CGPoint(x: rect.width * 0.68, y: rect.maxY + 2)
        )
        return path
    }
}

private struct DoodleArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 4, y: rect.maxY - 8))
        path.addCurve(
            to: CGPoint(x: rect.maxX - 16, y: rect.minY + 14),
            control1: CGPoint(x: rect.width * 0.28, y: rect.maxY + 3),
            control2: CGPoint(x: rect.width * 0.62, y: rect.minY - 9)
        )
        path.move(to: CGPoint(x: rect.maxX - 38, y: rect.minY + 10))
        path.addLine(to: CGPoint(x: rect.maxX - 13, y: rect.minY + 13))
        path.addLine(to: CGPoint(x: rect.maxX - 21, y: rect.minY + 37))
        return path
    }
}

private struct SketchPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .frame(height: 42)
            .background(Color.arcIndigo.opacity(configuration.isPressed ? 0.78 : 1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.inkBlue.opacity(0.42), style: StrokeStyle(lineWidth: 1.2, dash: [8, 3]))
                    .padding(-2)
            }
            .rotationEffect(.degrees(configuration.isPressed ? 0 : -0.5))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

private struct SketchSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(Color.inkBlue.opacity(0.66))
            .padding(.horizontal, 16)
            .frame(height: 40)
            .background(Color.white.opacity(configuration.isPressed ? 0.48 : 0.72), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(Color.inkBlue.opacity(0.18), style: StrokeStyle(lineWidth: 1.1, dash: [6, 3]))
            }
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
    static let inkBlue = Color(red: 0.075, green: 0.10, blue: 0.22)
    static let paperCream = Color(red: 0.975, green: 0.957, blue: 0.91)
    static let sunnyYellow = Color(red: 1.0, green: 0.79, blue: 0.20)
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
