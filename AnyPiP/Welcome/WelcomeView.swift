import SwiftUI

/// The two stages of the first-launch onboarding flow (AppDelegate shows WelcomeView exactly
/// once, gated by SettingsStore.hasCompletedWelcome): a looping demo of the app's two core
/// gestures, then the logo/name page with the "开始使用" action. rawValue doubles as each page's
/// horizontal slot in the pager.
private enum WelcomePage: Int, CaseIterable {
    case demo, start
}

/// The looping demo's phases — file-scope (not nested in GestureDemoScene) so WelcomeView can
/// read the same value to sync the caption text's emphasis to whichever gesture is currently
/// being demonstrated.
private enum DemoPhase: CaseIterable {
    case atRest, shaking, shrinking, floating, dragging, closing
}

/// A self-built horizontal pager rather than TabView(.page) — this needs a spring-driven, drag-
/// followable transition (matching macOS's own "What's New" onboarding sheets) that TabView's
/// page style doesn't expose control over. Both pages sit side by side in a fixed-width HStack;
/// changing `page` (via button, dot tap, or a committed drag) just animates that HStack's x-offset
/// with a spring, and an in-progress drag adds its live translation on top so the content visibly
/// follows the cursor before snapping.
///
/// Visual language borrows from ChatGPT's own product chrome rather than a generic macOS/iOS
/// onboarding look: a cool, near-grayscale surface with a single blue accent doing the color
/// work, a serif display face for headlines paired with plain system sans for body copy, and calm
/// rather than bouncy motion. The hero logo mark keeps the app icon's own red/green/blue identity
/// — everything *around* it (background, accent, type) is what shifted.
///
/// Every reveal animation here is driven by declarative `.animation(_:value:)` modifiers tied to
/// `page` or a single `hasEntered` flag set plainly in `.onAppear` — not imperative
/// `withAnimation{}` closures dispatched from secondary state. An earlier version used the latter
/// and content kept failing to actually reach the screen until an unrelated state change forced a
/// repaint; tying everything to state that's already proven to repaint reliably (page navigation)
/// avoided that class of bug entirely.
struct WelcomeView: View {
    let onContinue: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    @State private var page: WelcomePage = .demo
    @State private var dragTranslation: CGFloat = 0
    @State private var blobsDrifting = false
    @State private var hasEntered = false
    /// Owned here (not inside GestureDemoScene) so demoPage's caption text can react to the same
    /// phase the animation itself is in.
    @State private var demoPhase: DemoPhase = .atRest

    private let pageWidth: CGFloat = 460
    private let stageHeight: CGFloat = 340
    /// Vertical distance from center each demo caption line sits at — the "big" line moves to
    /// -captionSlotOffset (top slot), the "small" one to +captionSlotOffset (bottom slot), and
    /// they swap every time isShakeCaptionActive flips.
    private let captionSlotOffset: CGFloat = 12

    var body: some View {
        VStack(spacing: 0) {
            stage
            pageDots
                .padding(.top, 16)
            navigationBar
                .padding(.top, 18)
                .padding(.horizontal, 30)
                .padding(.bottom, 24)
        }
        .frame(width: pageWidth)
        .background(.ultraThinMaterial)
        .background(Color.welcomeBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(colorScheme == .dark ? 0.12 : 0.5), lineWidth: 0.75)
        )
        .overlay(alignment: .topTrailing) {
            closeButton.padding(12)
        }
        .onAppear {
            hasEntered = true
            withAnimation(.easeInOut(duration: 7).repeatForever(autoreverses: true)) {
                blobsDrifting = true
            }
        }
    }

    private var closeButton: some View {
        Button(action: onContinue) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(SubtleIconButtonStyle())
    }

    // MARK: - Stage (banner + paged content)

    private var stage: some View {
        // Offset math and per-page width are both derived from GeometryReader's *measured*
        // width rather than the pageWidth constant — a residual left-shift persisted even after
        // switching to .leading alignment, which points at the rendered width not actually
        // matching the pageWidth (460) the offset math assumed. Deriving both from the same
        // measured value makes them self-consistent regardless of what the real width turns out
        // to be, instead of two numbers that are supposed to agree but aren't guaranteed to.
        GeometryReader { proxy in
            let measuredWidth = proxy.size.width
            ZStack(alignment: .leading) {
                driftingBlobs(in: proxy.size)

                HStack(spacing: 0) {
                    demoPage.frame(width: measuredWidth)
                    startPage.frame(width: measuredWidth)
                }
                .frame(height: proxy.size.height)
                .offset(x: -CGFloat(page.rawValue) * measuredWidth + dragTranslation)
            }
        }
        .frame(width: pageWidth, height: stageHeight)
        .clipped()
        .contentShape(Rectangle())
        .gesture(pagingDragGesture)
    }

    /// Soft, low-saturation blobs drifting slowly and continuously behind frosted glass — this is
    /// the "liquid" half of glassmorphism: without something alive moving behind it, a blurred
    /// material surface has nothing to refract and just reads as a flat tint. Mostly blue plus one
    /// cool neutral gray, not a multicolor set — matching ChatGPT's restrained, near-monochrome
    /// use of color instead of reading like a marketing rainbow gradient.
    private func driftingBlobs(in size: CGSize) -> some View {
        ZStack {
            blob(color: .welcomeAccent, size: 240, x: blobsDrifting ? -90 : -130, y: blobsDrifting ? -50 : -20)
            blob(color: .welcomeAccentSoft, size: 210, x: blobsDrifting ? 110 : 150, y: blobsDrifting ? -30 : -70)
            blob(color: .welcomeNeutral, size: 220, x: blobsDrifting ? 40 : 80, y: blobsDrifting ? 120 : 90)
        }
        .blur(radius: 70)
        .opacity(colorScheme == .dark ? 0.35 : 0.3)
        .frame(width: size.width, height: size.height)
    }

    private func blob(color: Color, size: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        Circle()
            .fill(color.gradient)
            .frame(width: size, height: size)
            .offset(x: x, y: y)
    }

    private var pagingDragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                // Rubber-band at the ends instead of dragging past them, same as a real page
                // control — dividing the overshoot down makes it feel like it's resisting rather
                // than just stopping dead.
                let raw = value.translation.width
                let atStart = page == .demo && raw > 0
                let atEnd = page == .start && raw < 0
                dragTranslation = (atStart || atEnd) ? raw / 3.5 : raw
            }
            .onEnded { value in
                let threshold: CGFloat = 70
                if value.translation.width < -threshold, let next = WelcomePage(rawValue: page.rawValue + 1) {
                    commit(to: next)
                } else if value.translation.width > threshold, let previous = WelcomePage(rawValue: page.rawValue - 1) {
                    commit(to: previous)
                } else {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) { dragTranslation = 0 }
                }
            }
    }

    private func commit(to newPage: WelcomePage) {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.78)) {
            page = newPage
            dragTranslation = 0
        }
    }

    // MARK: - Page 1: Looping gesture demo

    /// Line 1 (shake-to-shrink) is emphasized for the phases that lead up to and through the
    /// shrink; line 2 (drag-to-close) takes over once the window is floating and headed for the
    /// close target — so the caption tracks whichever half of the loop is currently playing,
    /// rather than only flashing during the single instantaneous shake/drag phase.
    private var isShakeCaptionActive: Bool {
        switch demoPhase {
        case .atRest, .shaking, .shrinking: return true
        case .floating, .dragging, .closing: return false
        }
    }

    private var demoPage: some View {
        VStack(spacing: 30) {
            Spacer(minLength: 6)
            GestureDemoScene(phase: $demoPhase)
                .frame(width: 300, height: 210)
            // Font itself (size/weight) is deliberately held fixed and never animated — SwiftUI
            // doesn't continuously interpolate Font changes on Text the way it does real
            // transforms, so animating .font(size:weight:) directly snaps at some point
            // mid-transition instead of tracking the animation curve, which is what read as
            // "bold and size change happen at different times." Scale (a genuine animatable
            // transform) does the enlarging instead. Both lines live in a ZStack rather than a
            // VStack so the offset swap (the big one always on top) is a real position change,
            // not a structural reorder — reordering two views in a VStack would make SwiftUI
            // treat it as insert/remove rather than a smooth move.
            ZStack {
                Text("抓住窗口用力一甩，立即变成悬浮画中画")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .scaleEffect(isShakeCaptionActive ? 1.28 : 0.82)
                    .offset(y: isShakeCaptionActive ? -captionSlotOffset : captionSlotOffset)
                Text("拖到圆圈内松手，即可关闭画中画")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .scaleEffect(isShakeCaptionActive ? 0.82 : 1.28)
                    .offset(y: isShakeCaptionActive ? captionSlotOffset : -captionSlotOffset)
            }
            .frame(height: 50)
            .animation(.spring(response: 0.22, dampingFraction: 0.68), value: isShakeCaptionActive)
            .multilineTextAlignment(.center)
            Spacer(minLength: 6)
        }
        .padding(.horizontal, 30)
    }

    // MARK: - Page 2: Logo, name, start

    private var startPage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 4)
            WelcomeLogoMark(isVisible: hasEntered)
                .frame(width: 156, height: 156)
            Spacer(minLength: 18)
            Text("AnyPiP")
                .font(.system(size: 28, weight: .semibold, design: .serif))
                .opacity(hasEntered ? 1 : 0)
                .offset(y: hasEntered ? 0 : 10)
                .animation(.easeOut(duration: 0.4).delay(1.15), value: hasEntered)
            Text("将任意窗口悬浮成画中画")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
                .padding(.top, 7)
                .opacity(hasEntered ? 1 : 0)
                .offset(y: hasEntered ? 0 : 8)
                .animation(.easeOut(duration: 0.4).delay(1.3), value: hasEntered)
            Spacer(minLength: 24)
        }
    }

    // MARK: - Page dots

    private var pageDots: some View {
        HStack(spacing: 7) {
            ForEach(WelcomePage.allCases, id: \.self) { dot in
                Capsule()
                    .fill(dot == page ? Color.welcomeAccent : Color.primary.opacity(0.18))
                    .frame(width: dot == page ? 18 : 6, height: 6)
                    .animation(.spring(response: 0.4, dampingFraction: 0.75), value: page)
                    .onTapGesture { commit(to: dot) }
            }
        }
        .opacity(hasEntered ? 1 : 0)
        .animation(.easeOut(duration: 0.3).delay(1.3), value: hasEntered)
    }

    // MARK: - Navigation bar

    private var navigationBar: some View {
        HStack {
            if page != .demo {
                Button("上一步") {
                    if let previous = WelcomePage(rawValue: page.rawValue - 1) { commit(to: previous) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
                .transition(.opacity)
            }

            Spacer()

            primaryButton
        }
        .animation(.easeOut(duration: 0.2), value: page)
    }

    /// The one place this gets the real Liquid Glass material (macOS 26+'s .glassProminent
    /// button style) rather than an approximation — SwiftUI in this SDK only exposes Liquid Glass
    /// through button styles, not a general-purpose container modifier.
    @ViewBuilder
    private var primaryButton: some View {
        let label = page == .start ? "开始使用" : "下一步"
        let action: () -> Void = {
            if let next = WelcomePage(rawValue: page.rawValue + 1) {
                commit(to: next)
            } else {
                onContinue()
            }
        }
        if #available(macOS 26.0, *) {
            Button(label, action: action)
                .buttonStyle(.glassProminent)
                .tint(.welcomeAccent)
                .controlSize(.regular)
        } else {
            Button(action: action) {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .background(Capsule().fill(Color.welcomeAccent.gradient))
        }
    }
}

/// The logo's two-square-and-two-dots motif, built from real shapes with a trim-based "drawn by
/// hand" stroke animation (each rounded-rect outline animates from an empty trim to fully drawn)
/// rather than a plain scale/fade. Keeps the actual app icon's red/green/blue identity — this is
/// the one place on the page that stays saturated, everything around it is the muted palette.
private struct WelcomeLogoMark: View {
    let isVisible: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 7) {
                Circle().fill(Color.red).frame(width: 13, height: 13)
                Circle().fill(Color.green).frame(width: 13, height: 13)
            }
            .padding(.leading, 6)
            .padding(.top, 2)
            .scaleEffect(isVisible ? 1 : 0.3)
            .opacity(isVisible ? 1 : 0)
            .animation(.spring(response: 0.4, dampingFraction: 0.6).delay(0.35), value: isVisible)

            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .trim(from: 0, to: isVisible ? 1 : 0)
                .stroke(
                    LinearGradient(colors: [.red, .green], startPoint: .topLeading, endPoint: .bottomTrailing),
                    style: StrokeStyle(lineWidth: 13, lineCap: .round, lineJoin: .round)
                )
                .frame(width: 126, height: 106)
                .offset(x: 8, y: 30)
                .animation(.easeInOut(duration: 1.0), value: isVisible)

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .trim(from: 0, to: isVisible ? 1 : 0)
                .stroke(
                    LinearGradient(colors: [.blue.opacity(0.7), .cyan], startPoint: .topLeading, endPoint: .bottomTrailing),
                    style: StrokeStyle(lineWidth: 12, lineCap: .round, lineJoin: .round)
                )
                .frame(width: 80, height: 68)
                .offset(x: 60, y: 74)
                .animation(.easeInOut(duration: 0.9).delay(0.5), value: isVisible)
        }
    }
}

/// A small looping vector illustration demonstrating the app's two core gestures: grab-and-shake
/// a window to shrink it into a floating PiP, then drag that floating window onto a circular
/// target to close it. Runs continuously via `.task`, which SwiftUI auto-cancels when the view
/// leaves the hierarchy — no manual Timer bookkeeping needed. Each phase transition is a plain
/// state mutation; the visual animation comes entirely from declarative `.animation(value:)`
/// modifiers below, same reasoning as the rest of this file.
private struct GestureDemoScene: View {
    @Binding var phase: DemoPhase
    @State private var shakeAngle: Double = 0

    private var windowScale: CGFloat {
        switch phase {
        case .atRest, .shaking: return 1
        case .shrinking, .floating, .dragging: return 0.34
        case .closing: return 0.05
        }
    }

    private var windowOffset: CGSize {
        switch phase {
        case .atRest, .shaking: return CGSize(width: 0, height: -30)
        case .shrinking, .floating: return CGSize(width: 95, height: 40)
        case .dragging, .closing: return CGSize(width: 0, height: 68)
        }
    }

    private var windowOpacity: Double {
        phase == .closing ? 0 : 1
    }

    private var closeZoneVisible: Bool {
        switch phase {
        case .atRest, .shaking, .shrinking: return false
        case .floating, .dragging, .closing: return true
        }
    }

    private var closeZoneHighlighted: Bool {
        phase == .dragging || phase == .closing
    }

    var body: some View {
        ZStack {
            closeZoneCircle
                .opacity(closeZoneVisible ? 1 : 0)
                .scaleEffect(closeZoneHighlighted ? 1.18 : 1)
                .animation(.spring(response: 0.4, dampingFraction: 0.7), value: phase)

            MockWindow()
                .frame(width: 170, height: 110)
                .rotationEffect(.degrees(shakeAngle))
                .animation(.easeInOut(duration: 0.08).repeatCount(8, autoreverses: true), value: shakeAngle)
                .scaleEffect(windowScale)
                .offset(windowOffset)
                .opacity(windowOpacity)
                .animation(.spring(response: 0.5, dampingFraction: 0.72), value: phase)
        }
        .task { await runLoop() }
    }

    private var closeZoneCircle: some View {
        ZStack {
            Circle()
                .fill(.regularMaterial)
                .frame(width: 52, height: 52)
            Circle()
                .strokeBorder(closeZoneHighlighted ? Color.red.opacity(0.6) : Color.primary.opacity(0.2), lineWidth: 1.5)
                .frame(width: 52, height: 52)
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(closeZoneHighlighted ? .red : .secondary)
        }
        .offset(y: 68)
    }

    private func runLoop() async {
        while !Task.isCancelled {
            phase = .atRest
            shakeAngle = 0
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }

            phase = .shaking
            shakeAngle = 7
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            shakeAngle = 0

            phase = .shrinking
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled else { return }

            phase = .floating
            try? await Task.sleep(nanoseconds: 950_000_000)
            guard !Task.isCancelled else { return }

            phase = .dragging
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }

            phase = .closing
            try? await Task.sleep(nanoseconds: 550_000_000)
            guard !Task.isCancelled else { return }
        }
    }
}

/// A generic little app-window mockup (traffic lights included — this is illustrative content
/// standing in for *some other app's* window being converted, not this welcome window's own
/// chrome, which deliberately has none).
private struct MockWindow: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Circle().fill(Color.red.opacity(0.65)).frame(width: 6, height: 6)
                Circle().fill(Color.yellow.opacity(0.65)).frame(width: 6, height: 6)
                Circle().fill(Color.green.opacity(0.65)).frame(width: 6, height: 6)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.06))

            Rectangle()
                .fill(Color.welcomeAccent.opacity(0.12))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.3), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }
}

/// A small, neutral, "ChatGPT-like" palette — cool near-grayscale surfaces (not warm paper tones)
/// with a single blue accent doing almost all of the color work, rather than the user's system
/// accent color (which could be anything from purple to pink and wouldn't read as an intentional
/// brand choice here). Built with a dynamic NSColor provider so each stays correct across
/// Light/Dark Mode without needing separate call sites for each appearance.
private extension Color {
    /// A clean, modern blue, lightened slightly for dark mode so it still pops against a
    /// near-black background instead of going muddy.
    static let welcomeAccent = Color.adaptive(
        light: Color(red: 0.145, green: 0.388, blue: 0.922),
        dark: Color(red: 0.408, green: 0.596, blue: 0.976)
    )
    static let welcomeAccentSoft = Color.adaptive(
        light: Color(red: 0.376, green: 0.576, blue: 0.965),
        dark: Color(red: 0.573, green: 0.729, blue: 0.988)
    )
    /// A cool neutral gray rather than a second hue — this palette stays close to grayscale and
    /// leans on the one accent color, so this is here for variety in the background blobs without
    /// competing with welcomeAccent for attention.
    static let welcomeNeutral = Color.adaptive(
        light: Color(red: 0.573, green: 0.612, blue: 0.647),
        dark: Color(red: 0.463, green: 0.502, blue: 0.541)
    )
    static let welcomeBackground = Color.adaptive(
        light: Color(red: 0.968, green: 0.968, blue: 0.973),
        dark: Color(red: 0.129, green: 0.133, blue: 0.141)
    )

    static func adaptive(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
    }
}

#Preview {
    WelcomeView(onContinue: {})
}
