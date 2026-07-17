import AppKit
import CoreMedia
import CoreImage

@MainActor
protocol PiPPanelControllerDelegate: AnyObject {
    func pipPanelControllerDidRequestClose(_ controller: PiPPanelController)
    /// This panel was clicked while part of PiPSessionManager's overlapping stack — see
    /// PiPVideoLayerView.isPartOfStack's doc comment. Session-manager-wide (unstacks every
    /// session, not just this one), same as clicking any single notification in a stack expands
    /// the whole group in Notification Center.
    func pipPanelControllerDidRequestUnstackAll(_ controller: PiPPanelController)
}

/// Chooses letterboxing only when the source application itself has stopped following the PiP.
/// Virtual-display capacity alone never triggers `.fit`; its projected target is considered only
/// to catch the case where uniform capacity scaling pulls another axis across an already-confirmed
/// app limit. A freely-resizable app therefore remains crop-free without gaining needless bars.
enum PiPContentScalingPolicy {
    static func shouldUseFit(
        sourceEquivalentSize size: CGSize,
        effectiveResizeTarget: CGSize? = nil,
        discoveredAppMinimum floor: CGSize,
        discoveredAppMaximum ceiling: CGSize,
        tolerance: CGFloat = 1
    ) -> Bool {
        let sizes = [size, effectiveResizeTarget].compactMap { $0 }
        return sizes.contains { candidate in
            candidate.width < floor.width - tolerance
                || candidate.height < floor.height - tolerance
                || candidate.width > ceiling.width + tolerance
                || candidate.height > ceiling.height + tolerance
        }
    }

    /// Terminal windows such as Ghostty resize in whole character-cell increments, so the real
    /// source commonly settles a few points away from the freely-dragged PiP aspect ratio. Cropping
    /// that tiny mismatch with aspect-fill visibly trims the left/right terminal columns. A small
    /// non-uniform correction is visually imperceptible and keeps every captured pixel on-screen;
    /// larger mismatches still use aspect-fill to hide genuine asynchronous resize catch-up.
    static func shouldStretchMinorAspectMismatch(
        containerSize: CGSize,
        capturedContentSize: CGSize,
        maximumRelativeAspectDifference: CGFloat = 0.03
    ) -> Bool {
        guard containerSize.width > 0, containerSize.height > 0,
              capturedContentSize.width > 0, capturedContentSize.height > 0 else { return false }
        let containerAspect = containerSize.width / containerSize.height
        let contentAspect = capturedContentSize.width / capturedContentSize.height
        return abs(contentAspect / containerAspect - 1) <= maximumRelativeAspectDifference
    }
}

enum PiPPanelAspectPolicy {
    /// Keeps the panel width stable while matching a newly-settled capture aspect, then uniformly
    /// fits that result inside the panel's legal size range. Used after virtual-display topology
    /// changes, where the source app may accept a different size/aspect than was requested.
    static func matchingSize(
        currentSize: CGSize,
        capturedContentSize: CGSize,
        minimumSize: CGSize,
        maximumSize: CGSize,
        tolerance: CGFloat = 0.03
    ) -> CGSize {
        guard currentSize.width > 0, currentSize.height > 0,
              capturedContentSize.width > 0, capturedContentSize.height > 0 else { return currentSize }
        let contentAspect = capturedContentSize.width / capturedContentSize.height
        let currentAspect = currentSize.width / currentSize.height
        guard abs(contentAspect / currentAspect - 1) > tolerance else { return currentSize }

        var result = CGSize(width: currentSize.width, height: currentSize.width / contentAspect)
        let downScale = min(
            1,
            maximumSize.width / max(result.width, 1),
            maximumSize.height / max(result.height, 1)
        )
        result.width *= downScale
        result.height *= downScale

        let upScale = max(
            1,
            minimumSize.width / max(result.width, 1),
            minimumSize.height / max(result.height, 1)
        )
        result.width *= upScale
        result.height *= upScale
        return result
    }
}

/// NSPanel defaults canBecomeKey to false for borderless windows — we need it true so the panel
/// can receive keyDown events to forward (InteractionForwarder), even though it never activates
/// the app (still .nonactivatingPanel).
private final class InteractivePiPPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Draws control feedback just outside the PiP boundary. A fixed, feathered rounded-rectangle mask
/// keeps the effect off the captured picture while a pastel conic gradient moves beneath it. Only
/// the colors rotate; the mask never does, so the effect cannot sweep through the PiP interior or
/// expose square corners.
private final class ControlModeOuterGlowView: NSView {
    /// Leaves enough room for the softened edge without letting the feedback spread too far from
    /// the PiP. This still exceeds the filter footprint so the child window cannot expose square
    /// corners by clipping the glow.
    static let padding: CGFloat = 16

    private let backdropBlur = NSVisualEffectView()
    private let glowContainer = CALayer()
    private let glowClip = CALayer()
    private let glowMask = CALayer()
    private let pastelGradient = CAGradientLayer()
    private let maskContext = CIContext(options: [.cacheIntermediates: false])
    private var lastMaskSize: CGSize = .zero
    private var lastMaskRadius: CGFloat = -1
    private var isActive = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        backdropBlur.material = .popover
        backdropBlur.blendingMode = .behindWindow
        backdropBlur.state = .active
        backdropBlur.appearance = NSAppearance(named: .aqua)
        backdropBlur.wantsLayer = true
        backdropBlur.layer?.opacity = 0
        addSubview(backdropBlur)

        pastelGradient.type = .conic
        pastelGradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        pastelGradient.endPoint = CGPoint(x: 0.5, y: 0)
        pastelGradient.colors = [
            NSColor(calibratedRed: 0.78, green: 0.72, blue: 1.00, alpha: 0.90).cgColor,
            NSColor(calibratedRed: 0.67, green: 0.86, blue: 1.00, alpha: 0.88).cgColor,
            NSColor(calibratedRed: 0.70, green: 0.96, blue: 0.87, alpha: 0.86).cgColor,
            NSColor(calibratedRed: 1.00, green: 0.88, blue: 0.68, alpha: 0.86).cgColor,
            NSColor(calibratedRed: 1.00, green: 0.73, blue: 0.83, alpha: 0.88).cgColor,
            NSColor(calibratedRed: 0.78, green: 0.72, blue: 1.00, alpha: 0.90).cgColor
        ]
        pastelGradient.locations = [0, 0.20, 0.40, 0.60, 0.80, 1]

        // The raster mask already contains the Gaussian feather. This avoids running a full-panel
        // blur filter on every animation frame and keeps the moving feedback inexpensive.
        glowClip.mask = glowMask
        glowClip.addSublayer(pastelGradient)
        glowContainer.addSublayer(glowClip)

        glowContainer.opacity = 0
        layer?.addSublayer(glowContainer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        if active {
            needsLayout = true
            layoutSubtreeIfNeeded()
            startPastelFlowAnimation()
            animateOpacity(
                of: glowContainer,
                to: 1,
                duration: 0.16,
                key: "controlModeGlowOpacityTransition"
            )
            if let blurLayer = backdropBlur.layer {
                animateOpacity(
                    of: blurLayer,
                    to: 0.70,
                    duration: 0.18,
                    key: "controlModeBackdropOpacityTransition"
                )
            }
        } else {
            // Keep the colors moving during the fade so the edge leaves a short, natural-looking
            // afterglow instead of freezing and vanishing on the mouse-exit frame.
            animateOpacity(
                of: glowContainer,
                to: 0,
                duration: 0.34,
                key: "controlModeGlowOpacityTransition"
            )
            if let blurLayer = backdropBlur.layer {
                animateOpacity(
                    of: blurLayer,
                    to: 0,
                    duration: 0.26,
                    key: "controlModeBackdropOpacityTransition"
                )
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { [weak self] in
                guard let self, !self.isActive else { return }
                self.pastelGradient.removeAnimation(forKey: "controlModePastelFlow")
            }
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdropBlur.frame = bounds
        glowContainer.frame = bounds
        glowClip.frame = bounds
        glowMask.frame = bounds

        let panelRect = bounds.insetBy(dx: Self.padding, dy: Self.padding)
        let radius = CGFloat(SettingsStore.shared.panelCornerRadius)

        // Keep the rotating gradient large enough to cover the fixed rectangular mask at every
        // angle. Rotating only this oversized color field is what prevents the rounded border itself
        // from rotating into the PiP content.
        let gradientSide = ceil(hypot(bounds.width, bounds.height))
        pastelGradient.bounds = CGRect(x: 0, y: 0, width: gradientSide, height: gradientSide)
        pastelGradient.position = CGPoint(x: bounds.midX, y: bounds.midY)

        // A raster alpha mask is blurred before it reaches NSVisualEffectView. Applying a filter
        // directly to a CALayer used as another layer's mask leaves a hard compositing boundary on
        // some WindowServer paths; baking the Gaussian into the mask image is deterministic.
        if lastMaskSize != bounds.size || lastMaskRadius != radius {
            if let mask = makeFeatheredRingMask(
                size: bounds.size,
                panelRect: panelRect,
                radius: radius
            ) {
                backdropBlur.maskImage = mask.image
                glowMask.contents = mask.cgImage
                glowMask.contentsScale = 2
                glowMask.contentsGravity = .resize
            }
            lastMaskSize = bounds.size
            lastMaskRadius = radius
        }
        CATransaction.commit()
    }

    private func makeFeatheredRingMask(
        size: CGSize,
        panelRect: CGRect,
        radius: CGFloat
    ) -> (image: NSImage, cgImage: CGImage)? {
        guard size.width > 0, size.height > 0 else { return nil }
        let scale: CGFloat = 2
        let pixelWidth = Int(ceil(size.width * scale))
        let pixelHeight = Int(ceil(size.height * scale))
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.scaleBy(x: scale, y: scale)
        // Put the stroke's inner edge exactly on the PiP boundary. The final clear pass below
        // removes the inward half of the Gaussian, leaving an outside-only halo that still touches
        // the panel instead of appearing as a detached ring.
        let lineWidth: CGFloat = 5
        let haloOffset = lineWidth / 2
        let haloRect = panelRect.insetBy(dx: -haloOffset, dy: -haloOffset)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(lineWidth)
        context.addPath(CGPath(
            roundedRect: haloRect,
            cornerWidth: radius + haloOffset,
            cornerHeight: radius + haloOffset,
            transform: nil
        ))
        context.strokePath()
        guard let baseImage = context.makeImage() else { return nil }

        let input = CIImage(cgImage: baseImage)
        let blurred = input
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 2.0])
            .cropped(to: input.extent)
        guard let blurredOutput = maskContext.createCGImage(blurred, from: input.extent),
              let outsideOnlyContext = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        outsideOnlyContext.draw(
            blurredOutput,
            in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
        )
        outsideOnlyContext.scaleBy(x: scale, y: scale)
        outsideOnlyContext.setBlendMode(.clear)
        // Clear precisely through the panel boundary: no captured pixel is tinted, while the first
        // outside pixel remains part of the halo so there is no visible gap.
        outsideOnlyContext.addPath(CGPath(
            roundedRect: panelRect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        ))
        outsideOnlyContext.fillPath()

        guard let output = outsideOnlyContext.makeImage() else { return nil }
        return (NSImage(cgImage: output, size: size), output)
    }

    private func startPastelFlowAnimation() {
        // Preserve the current color position when the pointer briefly exits and comes back during
        // the afterglow; restarting the animation here would create a visible color jump.
        guard pastelGradient.animation(forKey: "controlModePastelFlow") == nil else { return }
        let flow = CABasicAnimation(keyPath: "transform.rotation.z")
        flow.fromValue = 0
        flow.toValue = CGFloat.pi * 2
        flow.duration = 5.4
        flow.repeatCount = .infinity
        flow.timingFunction = CAMediaTimingFunction(name: .linear)
        pastelGradient.add(flow, forKey: "controlModePastelFlow")
    }

    private func animateOpacity(
        of targetLayer: CALayer,
        to targetOpacity: Float,
        duration: CFTimeInterval,
        key: String
    ) {
        let currentOpacity = targetLayer.presentation()?.opacity ?? targetLayer.opacity
        targetLayer.removeAnimation(forKey: key)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        targetLayer.opacity = targetOpacity
        CATransaction.commit()

        let transition = CABasicAnimation(keyPath: "opacity")
        transition.fromValue = currentOpacity
        transition.toValue = targetOpacity
        transition.duration = duration
        transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
        targetLayer.add(transition, forKey: key)
    }

}

/// A floating, non-activating panel that stays visible above other apps' full-screen Spaces.
/// Level/collectionBehavior combination verified in Spikes/FullScreenOverlaySpike.
@MainActor
final class PiPPanelController: NSObject {
    weak var delegate: PiPPanelControllerDelegate?
    /// Keeps capture cadence aligned with the screen that actually presents this panel. A PiP may
    /// be dragged from a 120/144 Hz display onto a 60 Hz display (or the reverse) after creation.
    var onPresentationDisplayMaximumFPSChanged: ((Int) -> Void)? {
        didSet { reportPresentationDisplayMaximumFPSIfNeeded(force: true) }
    }
    /// Setting this wires it up with the geometry (panel/videoView) it needs for cursor-capture
    /// coordinate math — see InteractionForwarder.attach(videoView:panel:) — and subscribes to
    /// CaptureSession discovering the source app's real minimum/maximum size (see
    /// CaptureSession.onSourceMinSizeDiscovered/onSourceMaxSizeDiscovered's doc comments).
    var interactionForwarder: InteractionForwarder? {
        didSet {
            interactionForwarder?.attach(videoView: videoView, panel: panel)
            interactionForwarder?.onCaptureEnded = { [weak self] in
                self?.videoView.resetToMoveMode()
            }
            interactionForwarder?.captureSession?.onSourceMinSizeDiscovered = { [weak self] discoveredSize in
                guard let self else { return }
                self.discoveredSourceMinSize = discoveredSize
                self.updateContentScalingMode()
            }
            interactionForwarder?.captureSession?.onSourceMaxSizeDiscovered = { [weak self] discoveredSize in
                guard let self else { return }
                self.discoveredSourceMaxSize = discoveredSize
                self.updateContentScalingMode()
            }
            interactionForwarder?.captureSession?.onDeliverableSizeChanged = { [weak self] in
                self?.refreshPanelMaxSize()
            }
        }
    }

    let panel: NSPanel
    let videoView: PiPVideoLayerView
    /// Set only by PiPVideoLayerView receiving a real drag. Do not derive this from panel.frame:
    /// registering a CGVirtualDisplay can make WindowServer relocate an untouched NSPanel.
    private(set) var hasUserAdjustedFrameSinceCreation = false
    /// The source app's own minimum size, once CaptureSession has discovered it by having a
    /// shrink request rejected — nil until then, meaning "unknown, so keep trying to resize the
    /// source for now." See updateContentScalingMode's doc comment for how this is used.
    private var discoveredSourceMinSize: CGSize?
    /// The mirror image, for a growth request rejected — nil until then, same "unknown" meaning.
    private var discoveredSourceMaxSize: CGSize?
    /// True while this panel is meant to be invisible — either M3's "source app is frontmost" state
    /// (setLive(false)) or edge-docked-behind-the-handle (setFullyHidden(true)). updateOpacity
    /// checks this before touching alpha, so a live SettingsStore.panelOpacity change never
    /// un-hides a panel that's currently supposed to be hidden — it just takes effect the next
    /// time this panel actually becomes visible again.
    private var isCurrentlyHidden = false
    private var isControlModeGlowRequested = false
    private var controlModeGlowPanel: NSPanel?
    /// The source window's own bundle identifier, used to filter NowPlayingMonitor updates down
    /// to just the ones that actually belong to this session's own app — MediaRemote reports one
    /// system-wide "now playing" app at a time, so without this check a session showing lyrics
    /// mode for App A would start showing App B's lyrics the moment the user switches playback to
    /// a different music app while A's PiP is still open.
    private let sourceBundleIdentifier: String?
    private let sourceWindowTitle: String
    private let isMusicApp: Bool
    private let isVideoApp: Bool
    private var lyricsController: LyricsController?
    private var nowPlayingObserverId: UUID?
    /// Keeps the playback bar's icon/availability current for both music and video sessions.
    /// Registered once at init so the state is already correct the instant hover reveals it.
    private var playbackControlsObserverId: UUID?
    private var hasMatchingVideoPlayback = false
    private var lastReportedPresentationDisplayMaximumFPS: Int?

    init(initialFrame: NSRect, nativeSize: CGSize, windowTitle: String, sourceBundleIdentifier: String?) {
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.sourceWindowTitle = windowTitle
        self.isMusicApp = WindowEnumerator.isKnownMusicApp(bundleIdentifier: sourceBundleIdentifier)
        self.isVideoApp = WindowEnumerator.isKnownVideoApp(bundleIdentifier: sourceBundleIdentifier)
        // No .resizable here — PiPVideoLayerView implements the entire drag-to-resize gesture
        // itself (edge detection, live tracking, min/maxSize clamping) via window.setFrame calls
        // that don't need it. Diagnostic logging (traced via a live session) found .resizable
        // was actively harmful: AppKit still installs its own native edge/corner resize hit-
        // testing for a *borderless* resizable window, and that native handling intercepted
        // mouseDown before it ever reached PiPVideoLayerView — so every PiP-panel resize was
        // silently going through macOS's own resize machinery instead of this app's, which never
        // calls PiPVideoLayerViewDelegate.didResizeTo and therefore never told CaptureSession to
        // resize the source window. The panel still visibly resized (native resize obviously
        // works), which is exactly what made this so hard to track down — it looked like our own
        // resize code was running and just not reaching the source window, when actually our
        // resize code was never running at all.
        panel = InteractivePiPPanel(
            contentRect: initialFrame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        videoView = PiPVideoLayerView(frame: NSRect(origin: .zero, size: initialFrame.size))

        super.init()

        panel.delegate = self
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = SettingsStore.shared.panelShadowEnabled
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // A plain hover over the content hands control to InteractionForwarder's cursor capture,
        // so it can't also move the panel — PiPVideoLayerView implements Option+drag to move
        // (dragging mostly off-screen or into the screen's lower half closes it) and edge-drag
        // to resize instead.
        panel.isMovableByWindowBackground = false
        panel.minSize = NSSize(width: 160, height: 100)
        // Caps the panel at what CaptureSession.clampToDeliverableSize can actually deliver on the
        // virtual display (maxPixelsWide/High minus the same edgeMargin/menuBarInset placement
        // insets it itself subtracts) — without this, nothing stopped PiPVideoLayerView's custom
        // edge-drag from growing the panel past that ceiling: the real source window would
        // silently get clamped there while the panel kept growing, so the mirror stopped matching
        // the panel's shape the further past it you dragged.
        //
        // This is only an *aspirational* value — the virtual display doesn't exist yet at panel-
        // creation time, so there's nothing more specific to go on. It gets corrected downward
        // once the display's real (possibly smaller — see CaptureSession.deliverableMaxSize's doc
        // comment) live bounds are known; see didResizeTo below.
        let virtualDisplaySize = VirtualDisplayHost.pixelSize(forLongEdge: CGFloat(SettingsStore.shared.virtualDisplayLongEdge))
        panel.maxSize = NSSize(
            width: CGFloat(virtualDisplaySize.width) - CaptureSession.edgeMargin * 2,
            height: CGFloat(virtualDisplaySize.height) - VirtualDisplayHost.menuBarInset - CaptureSession.edgeMargin
        )
        // Needed for PiPVideoLayerView.mouseMoved to fire at all — that's what detects a plain
        // hover and hands it to cursor capture.
        panel.acceptsMouseMovedEvents = true

        videoView.autoresizingMask = [.width, .height]
        videoView.interactionDelegate = self
        videoView.titleText = windowTitle
        videoView.isMusicApp = isMusicApp
        videoView.isVideoApp = isVideoApp
        panel.contentView = videoView
        videoView.onControlModeAppearanceChanged = { [weak self] shouldShow in
            self?.setControlModeGlowRequested(shouldShow)
        }

        if isMusicApp || isVideoApp {
            playbackControlsObserverId = NowPlayingMonitor.shared.addObserver { [weak self] info in
                guard let self else { return }
                if self.isMusicApp {
                    let playing = info?.bundleIdentifier == self.sourceBundleIdentifier ? (info?.playing ?? false) : false
                    self.videoView.musicControlsBar.setPlaying(playing)
                } else {
                    let matches = WindowEnumerator.videoPlaybackMatches(
                        info,
                        sourceBundleIdentifier: self.sourceBundleIdentifier,
                        windowTitle: self.sourceWindowTitle
                    )
                    self.hasMatchingVideoPlayback = matches
                    self.videoView.setVideoPlaybackAvailable(matches, playing: info?.playing ?? false)
                }
            }
        }

        animateEntrance(to: initialFrame)
    }

    /// Pops the panel in by sliding it from off past the right edge of its screen to
    /// `finalFrame` — chosen over animating anything about the real source window (tried:
    /// shrinking/translating/fading it via a burst of manual Accessibility frame/alpha updates —
    /// reverted, since each step is a real IPC round-trip to a different process rather than a
    /// GPU-composited animation, and was visibly janky). Sliding the panel is our own NSView/
    /// CALayer being animated by AppKit directly, so it's smooth regardless of what the source
    /// app is doing. Finishes with a one-shot ripple flourish on the video view itself (see
    /// PiPVideoLayerView.playAppearRipple).
    private func animateEntrance(to finalFrame: NSRect) {
        let screen = NSScreen.screens.first { $0.frame.intersects(finalFrame) } ?? NSScreen.main
        let offscreenX = (screen?.frame.maxX ?? finalFrame.maxX) + finalFrame.width
        let startFrame = NSRect(x: offscreenX, y: finalFrame.origin.y, width: finalFrame.width, height: finalFrame.height)

        panel.setFrame(startFrame, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(finalFrame, display: true)
            panel.animator().alphaValue = CGFloat(SettingsStore.shared.panelOpacity)
        }, completionHandler: { [weak self] in
            self?.videoView.playAppearRipple()
        })
    }

    /// Instant removal, deliberately — a shrink-toward-the-circle animation was tried for the
    /// dropped-onto-CloseDropZoneOverlay case specifically (converging the panel into the circle's
    /// center rather than just vanishing), but it still read as an unwanted extra flourish stacked
    /// on top of the drag gesture that triggered it. Both the panel and the close target now leave
    /// immediately, in that order, as soon as the drop is confirmed.
    func close() {
        // Cursor capture uses the real system pointer on a private display. Always return it before
        // hiding the panel or destroying that display, including failed startup and app shutdown.
        interactionForwarder?.stop()
        setLyricsMode(false)
        if let playbackControlsObserverId {
            NowPlayingMonitor.shared.removeObserver(playbackControlsObserverId)
        }
        playbackControlsObserverId = nil
        setControlModeGlowRequested(false)
        panel.orderOut(nil)
    }

    /// Fades the panel in/out — used when the source app becomes frontmost (M3): showing a
    /// thumbnail of the window the user is already looking at directly is pointless, so it
    /// hides itself until they switch away again. ignoresMouseEvents keeps a hidden (alpha 0)
    /// panel from swallowing clicks meant for whatever's actually behind it.
    func setLive(_ live: Bool, animated: Bool = true) {
        debugTrace("live: setLive(\(live)) called, panel currently alphaValue=\(panel.alphaValue) frame=\(panel.frame)")
        isCurrentlyHidden = !live
        panel.ignoresMouseEvents = !live
        if live { panel.orderFrontRegardless() }
        refreshControlModeGlowVisibility()
        let targetAlpha = live ? CGFloat(SettingsStore.shared.panelOpacity) : 0
        let applyAlpha = { self.panel.animator().alphaValue = targetAlpha }
        guard animated else {
            panel.alphaValue = targetAlpha
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            applyAlpha()
        }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer, nativeSize: CGSize) {
        videoView.enqueue(sampleBuffer, nativeSize: nativeSize)
    }

    func sourceWindowWillMoveOntoVirtualDisplay() {
        videoView.sourceWindowWillMoveOntoVirtualDisplay()
    }

    func sourceWindowDidMoveOntoVirtualDisplay() {
        videoView.sourceWindowDidMoveOntoVirtualDisplay()
    }

    private func reportPresentationDisplayMaximumFPSIfNeeded(force: Bool = false) {
        let screen = panel.screen
            ?? NSScreen.screens.first(where: { $0.frame.intersects(panel.frame) })
            ?? NSScreen.main
        let fps = DisplayRefreshRate.fps(for: screen)
        guard force || fps != lastReportedPresentationDisplayMaximumFPS else { return }
        lastReportedPresentationDisplayMaximumFPS = fps
        onPresentationDisplayMaximumFPSChanged?(fps)
    }

    /// PiPSessionManager.stackAllSessions/unstackSessions call this on every session's controller
    /// to keep videoView.isPartOfStack in sync — see that property's doc comment for what it gates.
    func setStacked(_ stacked: Bool) {
        videoView.isPartOfStack = stacked
    }

    /// PiPSessionManager calls this to make an edge-docked panel disappear/reappear completely —
    /// see EdgeHandleWindow's own doc comment for why a docked group is now represented by that
    /// entirely separate, always-fully-on-screen window instead of this panel being left mostly
    /// off-screen with a hoverable sliver of itself (the previous design, abandoned after repeated
    /// failed attempts to make that sliver actually render). ignoresMouseEvents keeps a hidden
    /// (alpha 0, ordered out) panel from swallowing clicks meant for whatever's behind it, same
    /// guard setLive already uses for the same reason.
    func setFullyHidden(_ hidden: Bool) {
        isCurrentlyHidden = hidden
        panel.ignoresMouseEvents = hidden
        refreshControlModeGlowVisibility()
        if hidden {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                self?.panel.orderOut(nil)
            }
        } else {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().alphaValue = CGFloat(SettingsStore.shared.panelOpacity)
            }
        }
    }

    /// SettingsStore.panelOpacity changed live (PiPSessionManager.observeLiveSettings) — applies
    /// immediately to a panel that's currently visible; a panel currently hidden (isCurrentlyHidden)
    /// stays at alpha 0 regardless, and simply picks up the new value the next time setLive/
    /// setFullyHidden reveals it again.
    func updateOpacity() {
        guard !isCurrentlyHidden else { return }
        panel.animator().alphaValue = CGFloat(SettingsStore.shared.panelOpacity)
    }

    /// Applies the control-feedback preference to an already-open panel. PiPVideoLayerView keeps
    /// track of whether this particular session is currently controlling its source.
    func updateControlModeGlowPreference() {
        videoView.refreshControlModeGlowPreference()
    }

    private func setControlModeGlowRequested(_ requested: Bool) {
        isControlModeGlowRequested = requested
        refreshControlModeGlowVisibility()
    }

    private func refreshControlModeGlowVisibility() {
        let shouldShow = isControlModeGlowRequested && !isCurrentlyHidden
        guard shouldShow else {
            (controlModeGlowPanel?.contentView as? ControlModeOuterGlowView)?.setActive(false)
            if let controlModeGlowPanel {
                if controlModeGlowPanel.parent === panel {
                    panel.removeChildWindow(controlModeGlowPanel)
                }
                controlModeGlowPanel.orderOut(nil)
            }
            return
        }

        let glowPanel = ensureControlModeGlowPanel()
        syncControlModeGlowFrame()
        if glowPanel.parent == nil {
            panel.addChildWindow(glowPanel, ordered: .above)
        }
        glowPanel.orderFrontRegardless()
        (glowPanel.contentView as? ControlModeOuterGlowView)?.setActive(true)
    }

    private func ensureControlModeGlowPanel() -> NSPanel {
        if let controlModeGlowPanel { return controlModeGlowPanel }

        let padding = ControlModeOuterGlowView.padding
        let glowFrame = panel.frame.insetBy(dx: -padding, dy: -padding)
        let glowPanel = NSPanel(
            contentRect: glowFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        glowPanel.isOpaque = false
        glowPanel.backgroundColor = .clear
        glowPanel.hasShadow = false
        glowPanel.ignoresMouseEvents = true
        glowPanel.hidesOnDeactivate = false
        glowPanel.level = panel.level
        glowPanel.collectionBehavior = panel.collectionBehavior
        glowPanel.contentView = ControlModeOuterGlowView(frame: NSRect(origin: .zero, size: glowFrame.size))
        controlModeGlowPanel = glowPanel
        return glowPanel
    }

    private func syncControlModeGlowFrame() {
        guard let controlModeGlowPanel else { return }
        let padding = ControlModeOuterGlowView.padding
        controlModeGlowPanel.setFrame(
            panel.frame.insetBy(dx: -padding, dy: -padding),
            display: true
        )
    }

    /// Swaps this panel between the mirrored video and the PiP-lyrics panel (PiPVideoLayerView.
    /// lyricsView) — a no-op unless this session's source app is actually a known music app
    /// (isMusicApp, computed at init from the window's own bundle identifier). Registers/
    /// unregisters with NowPlayingMonitor.shared to receive system-wide now-playing updates,
    /// filtered down to just this session's own app (sourceBundleIdentifier) so a session showing
    /// lyrics for one app doesn't start showing another app's lyrics if the user switches which
    /// music app is actually playing while this PiP stays open.
    ///
    /// Requires an active membership when turning lyrics mode *on* (not when turning it off, so a
    /// membership that lapses mid-session still lets the panel cleanly fall back to video rather
    /// than getting stuck showing lyrics) — the toggle button itself is already hidden for
    /// non-members (PiPVideoLayerView.updateLyricsToggleButton), but this is the actual point of
    /// action, so it's checked again here rather than trusting the UI alone to enforce it.
    func setLyricsMode(_ active: Bool) {
        guard isMusicApp, videoView.isLyricsModeActive != active else { return }
        guard !active || MembershipManager.shared.isMember else { return }
        videoView.setLyricsModeActive(active)
        videoView.displayLayer.isHidden = active
        videoView.lyricsView.isHidden = !active

        if active {
            let controller = LyricsController()
            controller.delegate = self
            lyricsController = controller
            nowPlayingObserverId = NowPlayingMonitor.shared.addObserver { [weak self] info in
                guard let self, let info, info.bundleIdentifier == self.sourceBundleIdentifier else { return }
                self.lyricsController?.update(with: info)
                if let artworkData = info.artworkData {
                    self.videoView.lyricsView.setArtwork(NSImage(data: artworkData))
                }
            }
        } else {
            if let id = nowPlayingObserverId {
                NowPlayingMonitor.shared.removeObserver(id)
            }
            nowPlayingObserverId = nil
            lyricsController = nil
        }
    }

    /// Deliberately a *different* condition than applyPanelResize's own both-dimensions check for
    /// whether to skip touching the source window at all (CaptureSession.applyPanelResize's doc
    /// comment) — those two decisions look similar but aren't the same question. Skipping AX calls
    /// entirely is only worth doing once *neither* axis has anywhere left to go (both pinned), so
    /// the other axis's still-live tracking isn't interrupted. But the *visual* mode only needs one
    /// axis to be pinned to matter: once any axis is stuck at a discovered bound — including an
    /// app whose window is genuinely locked to a single fixed width while its height stays fully
    /// adjustable (observed: a settings-pane window where discoveredMinWidth and discoveredMaxWidth
    /// converged on the exact same value) — .fill would crop that one axis to hide the mismatch
    /// instead of showing it, which reads as "doesn't fit" even though the crop is quietly doing
    /// its job. .fit shows the whole picture on every axis that isn't currently able to track,
    /// letterboxing/pillarboxing just that axis while any axis that's still actively resizing stays
    /// crop-free. Called both when a bound is first discovered and on every subsequent resize tick,
    /// so crossing back and forth over any threshold mid-drag switches modes live.
    private func updateContentScalingMode() {
        // discoveredSourceMinSize/MaxSize are in the source window's own point-space, not the
        // panel's — CaptureSession.panelToSourceScale converts panel.frame.size (the panel starts
        // life at a fixed default thumbnail width, entirely decoupled from however big the real
        // source window is — see resizeSourceWindow's doc comment) onto that same footing before
        // comparing. Falls back to 1:1 if no resize has happened yet to establish the scale.
        let scale = interactionForwarder?.captureSession?.panelToSourceScale ?? 1
        let size = CGSize(width: panel.frame.width * scale, height: panel.frame.height * scale)
        let effectiveTarget = interactionForwarder?.captureSession?
            .projectedSourceResizeTarget(forPanelSize: panel.frame.size)
        let floor = discoveredSourceMinSize ?? .zero
        let appCeiling = discoveredSourceMaxSize
            ?? CGSize(width: CGFloat.infinity, height: CGFloat.infinity)
        let shouldUseFit = PiPContentScalingPolicy.shouldUseFit(
            sourceEquivalentSize: size,
            effectiveResizeTarget: effectiveTarget,
            discoveredAppMinimum: floor,
            discoveredAppMaximum: appCeiling
        )
        videoView.setContentScalingMode(shouldUseFit ? .fit : .fill)
    }

    /// Called when CaptureSession.onDeliverableSizeChanged fires — a live virtualDisplayLongEdge
    /// resize (SettingsStore's "虚拟显示器分辨率" slider, applied to an already-open session) just
    /// succeeded. Unlike didResizeTo's own maxSize update (which only ever tightens it via `min`,
    /// since an app-imposed ceiling can't un-discover itself), this sets panel.maxSize straight to
    /// the new deliverableMaxSize: the virtual display's own capacity is the one ceiling that can
    /// legitimately go back up, and nothing else will ever raise panel.maxSize back to match if
    /// this doesn't.
    private func refreshPanelMaxSize() {
        guard let captureSession = interactionForwarder?.captureSession,
              let deliverableMax = captureSession.deliverableMaxSize else { return }
        panel.maxSize = NSSize(width: deliverableMax.width, height: deliverableMax.height)

        // NSWindow.maxSize only constrains future interactive resize operations; lowering it does
        // not pull an already-larger panel back inside the new limit. Apply that correction now,
        // preserving the panel's aspect ratio and top-left anchor so a live settings change feels
        // stable instead of making the window jump across the screen.
        let currentFrame = panel.frame
        let newSize = PiPPanelAspectPolicy.matchingSize(
            currentSize: currentFrame.size,
            capturedContentSize: captureSession.currentCapturedContentSize(),
            minimumSize: panel.minSize,
            maximumSize: deliverableMax
        )
        if abs(newSize.width - currentFrame.width) > 0.5
            || abs(newSize.height - currentFrame.height) > 0.5 {
            let resizedFrame = CGRect(
                x: currentFrame.minX,
                y: currentFrame.maxY - newSize.height,
                width: newSize.width,
                height: newSize.height
            )
            panel.setFrame(resizedFrame, display: true)
        }

        // Re-run the normal panel→source resize pipeline even if the panel itself did not need to
        // shrink. The source window may still be larger than a newly-reduced virtual workspace;
        // this clamps it to the new capacity and refreshes the crop instead of leaving stale or
        // partially-outside content visible until the user next drags an edge.
        updateContentScalingMode()
        captureSession.resizeSourceWindow(to: panel.frame.size)
    }
}

extension PiPPanelController: NSWindowDelegate {
    func windowDidChangeScreen(_ notification: Notification) {
        reportPresentationDisplayMaximumFPSIfNeeded()
    }

    func windowDidMove(_ notification: Notification) {
        syncControlModeGlowFrame()
    }

    func windowDidResize(_ notification: Notification) {
        syncControlModeGlowFrame()
    }
}

extension PiPPanelController: PiPVideoLayerViewDelegate {
    func videoView(_ view: PiPVideoLayerView, didHoverContentAt localPoint: CGPoint) {
        interactionForwarder?.beginCaptureIfNeeded(atLocalPoint: localPoint)
    }

    func videoView(_ view: PiPVideoLayerView, didReceiveKeyEvent event: NSEvent) {
        interactionForwarder?.forwardKeyEvent(event)
    }

    func videoViewDidBeginUserGeometryChange(_ view: PiPVideoLayerView) {
        hasUserAdjustedFrameSinceCreation = true
    }

    func videoView(_ view: PiPVideoLayerView, didResizeTo size: CGSize) {
        debugTrace("grow: didResizeTo panelSize=\(size)")
        // Corrects the aspirational maxSize set at panel-creation time down to whatever the
        // virtual display's real live bounds can actually deliver, once known — see
        // CaptureSession.deliverableMaxSize's doc comment for why this can be smaller than
        // expected. This is deliberately applied *unscaled*, straight in the panel's own
        // point-space, as just a generous ceiling on how big the floating panel window itself can
        // be dragged — not an attempt to keep the panel capped at exactly what the mirrored source
        // can currently follow it to (those are no longer the same space once
        // CaptureSession.panelToSourceScale is anything other than 1:1). Dividing this by that
        // scale was tried and reverted: it choked the panel down to a tiny fraction of
        // deliverableMax (e.g. ~380x230 out of a 1200x716 budget, for a source that started out
        // ~3x bigger than the default thumbnail panel), and there was no need for it — once the
        // panel's scaled-up equivalent actually outgrows what the source can be resized to,
        // updateContentScalingMode already switches the mirror to letterboxed .fit on its own, so
        // the panel stays freely draggable and the picture just increasingly pillarboxes instead.
        // Only ever tightens (min), since a legitimately-behaving virtual display can't exceed
        // what was requested, and re-checking every tick means this takes effect live, mid-drag,
        // the moment the real bounds become known.
        if let deliverableMax = interactionForwarder?.captureSession?.deliverableMaxSize {
            panel.maxSize = NSSize(
                width: min(panel.maxSize.width, deliverableMax.width),
                height: min(panel.maxSize.height, deliverableMax.height)
            )
        }
        // Establishes panelToSourceScale synchronously on the first resize. Updating the visual
        // mode afterward lets it compare against the same projected source target that the async
        // resize pipeline will actually use, including virtual-display clamping.
        interactionForwarder?.captureSession?.resizeSourceWindow(to: size)
        updateContentScalingMode()
    }

    func videoViewDidRequestCloseByDragging(_ view: PiPVideoLayerView) {
        delegate?.pipPanelControllerDidRequestClose(self)
    }

    func videoViewDidRequestClose(_ view: PiPVideoLayerView) {
        delegate?.pipPanelControllerDidRequestClose(self)
    }

    func videoViewDidRequestUnstack(_ view: PiPVideoLayerView) {
        delegate?.pipPanelControllerDidRequestUnstackAll(self)
    }

    func videoViewDidToggleLyricsMode(_ view: PiPVideoLayerView) {
        setLyricsMode(!videoView.isLyricsModeActive)
    }

    func videoView(_ view: PiPVideoLayerView, didRequestMusicCommand command: PiPMusicControlsBar.Command) {
        guard isMusicApp || (isVideoApp && hasMatchingVideoPlayback) else { return }
        if isVideoApp {
            guard case .togglePlayPause = command else { return }
        }
        let mrCommand: NowPlayingMonitor.Command
        switch command {
        case .previous: mrCommand = .previousTrack
        case .togglePlayPause: mrCommand = .togglePlayPause
        case .next: mrCommand = .nextTrack
        }
        NowPlayingMonitor.shared.send(mrCommand)
    }
}

extension PiPPanelController: LyricsControllerDelegate {
    func lyricsController(_ controller: LyricsController, didLoadLines lines: [LyricLine]) {
        videoView.lyricsView.setLines(lines)
    }

    func lyricsController(_ controller: LyricsController, didUpdateHighlightedIndex index: Int?) {
        videoView.lyricsView.setHighlightedIndex(index)
    }
}
