import AppKit
import AVFoundation
import CoreImage
import CoreMedia

/// A material-independent transition glass. CALayer's background filter blurs the already-rendered
/// PiP behind this transparent view, so there is no snapshot/copy and no system material tint that
/// can turn colorful content gray or muddy. Returning nil keeps every gesture on the host view.
private final class ResizeGlassOverlayView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.025).cgColor
        layer?.allowsGroupOpacity = true

        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setDefaults()
            blur.setValue(14.0, forKey: kCIInputRadiusKey)
            layer?.backgroundFilters = [blur]
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A depth-one handoff between ScreenCaptureKit's sample queue and AppKit's main thread.
///
/// At high refresh rates, creating one unbounded MainActor task per captured frame lets old frames
/// sit behind unrelated UI work. AVSampleBufferDisplayLayer then receives those buffers after their
/// presentation timestamps have passed and drops them as late. This mailbox schedules at most one
/// main-thread delivery at a time and replaces only a frame that has not reached the renderer yet,
/// keeping the displayed stream live without building latency.
final class LatestVideoFramePresenter: @unchecked Sendable {
    private struct PendingFrame {
        let sampleBuffer: CMSampleBuffer
        let nativeSize: CGSize
    }

    private let lock = NSLock()
    private var pendingFrame: PendingFrame?
    private var deliveryScheduled = false
    private var isInvalidated = false
    private let presentOnMain: (CMSampleBuffer, CGSize) -> Void

    @MainActor
    init(panelController: PiPPanelController) {
        presentOnMain = { [weak panelController] sampleBuffer, nativeSize in
            panelController?.enqueue(sampleBuffer, nativeSize: nativeSize)
        }
    }

    func submit(_ sampleBuffer: CMSampleBuffer, nativeSize: CGSize) {
        lock.lock()
        guard !isInvalidated else {
            lock.unlock()
            return
        }
        pendingFrame = PendingFrame(sampleBuffer: sampleBuffer, nativeSize: nativeSize)
        let shouldSchedule = !deliveryScheduled
        if shouldSchedule { deliveryScheduled = true }
        lock.unlock()

        guard shouldSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            self?.deliverLatestFrame()
        }
    }

    func invalidate() {
        lock.lock()
        isInvalidated = true
        pendingFrame = nil
        lock.unlock()
    }

    private func deliverLatestFrame() {
        lock.lock()
        let frame = pendingFrame
        pendingFrame = nil
        deliveryScheduled = false
        let shouldPresent = !isInvalidated
        lock.unlock()

        guard shouldPresent, let frame else { return }
        presentOnMain(frame.sampleBuffer, frame.nativeSize)
    }
}

@MainActor
protocol PiPVideoLayerViewDelegate: AnyObject {
    /// The real cursor moved somewhere within the content area that isn't a resize edge and
    /// isn't an Option-drag — see InteractionForwarder.beginCaptureIfNeeded for what happens
    /// next (the real cursor gets moved onto the virtual display to directly control the source).
    func videoView(_ view: PiPVideoLayerView, didHoverContentAt localPoint: CGPoint)
    func videoView(_ view: PiPVideoLayerView, didReceiveKeyEvent event: NSEvent)
    /// Fires once an actual mouse-drag begins changing the floating panel's frame. WindowServer
    /// also moves panels while a virtual display is registered, so callers must use this explicit
    /// user-interaction signal instead of inferring intent from a changed NSPanel.frame.
    func videoViewDidBeginUserGeometryChange(_ view: PiPVideoLayerView)
    /// Fires continuously while an edge-drag resize is in progress (every mouseDragged tick), and
    /// once more at mouseUp with the exact final size — PiPPanelController forwards each call on
    /// to resize the source window itself to match, so it visibly reflows live as the panel is
    /// dragged rather than only catching up once the user lets go. Safe to call at UI-event
    /// frequency: each call is a live AX IPC round-trip to a different process, so
    /// CaptureSession.resizeSourceWindow coalesces these into a depth-1 queue internally (always
    /// working toward the latest requested size, never piling up a backlog) rather than this view
    /// needing to throttle them itself.
    func videoView(_ view: PiPVideoLayerView, didResizeTo size: CGSize)
    /// The panel was Option-dragged mostly off every screen, or dropped overlapping
    /// CloseDropZoneOverlay's circular target in the screen's lower half — both treated as a
    /// "drag to dismiss" gesture (like removing a menu-bar icon), the latter shown live via the
    /// floating target while the drag is in progress.
    func videoViewDidRequestCloseByDragging(_ view: PiPVideoLayerView)
    /// Fires on any mouseDown while isPartOfStack is true — see that property's doc comment.
    func videoViewDidRequestUnstack(_ view: PiPVideoLayerView)
    /// The lyrics toggle button (only shown when isMusicApp is true) was clicked — PiPPanelController
    /// forwards this to setLyricsMode(_:), flipping between the mirrored video and PiPLyricsView.
    func videoViewDidToggleLyricsMode(_ view: PiPVideoLayerView)
    /// A transport button on musicControlsBar was clicked — music sources expose all three
    /// commands, while supported video sources configure the same bar with play/pause only.
    func videoView(_ view: PiPVideoLayerView, didRequestMusicCommand command: PiPMusicControlsBar.Command)
    /// closeCornerControl's close button was clicked (SettingsStore.panelCloseMethod ==
    /// .cornerButton only) — the other way to close a panel, alongside
    /// videoViewDidRequestCloseByDragging's drag-to-CloseDropZoneOverlay gesture.
    func videoViewDidRequestClose(_ view: PiPVideoLayerView)
}

/// Hosts an AVSampleBufferDisplayLayer for hardware-accelerated, zero-CPU-copy frame rendering,
/// and captures mouse/keyboard input for InteractionForwarder to replay on the real window.
///
/// A freshly-opened panel starts in "move mode" (hasEnteredControlMode false): a plain drag, no
/// modifier needed, moves the panel around — dropping it onto CloseDropZoneOverlay's circular
/// target, shown in the screen's lower half for the duration of the drag, or dragging it mostly
/// off-screen entirely, both close it, like pulling a menu-bar icon off the bar. Double-clicking
/// the content (not a resize edge) is the one-time gate into "control mode": from then on for
/// this panel, plain hovering hands control to InteractionForwarder's cursor capture instead (the
/// real cursor moves onto the virtual display and directly controls the source — see its own doc
/// comment), the same as this view's default used to be unconditionally. Moving the panel is still
/// possible after that — Option+drag keeps working in control mode exactly like it always did,
/// since Option appearing mid-capture already released it immediately so a subsequent mouseDown
/// can reach this view. Dragging within an edge margin resizes the panel in either mode, checked
/// before either the move-drag or double-click/capture logic, so it's never shadowed by them.
final class PiPVideoLayerView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()
    weak var interactionDelegate: PiPVideoLayerViewDelegate?
    private(set) var nativeSize: CGSize = .zero

    /// .fill (crop-to-cover, the default): used while the source window is still being actively
    /// resized to match the panel — the asynchronous catch-up gap (AX IPC + the app's own reflow
    /// + a new captured frame arriving) reads as "already filling the panel" under a crop, rather
    /// than flashing letterbox bars on every resize tick.
    /// .fit (scale-to-contain, no crop): used once the panel has been dragged smaller than the
    /// source app's own discovered minimum size (PiPPanelController, following
    /// CaptureSession.onSourceMinSizeDiscovered) — the source window has stopped changing at that
    /// point, so there's nothing left to "catch up" to; shrinking the panel further is now a pure
    /// visual zoom of the whole picture, which should show all of it rather than cropping into it.
    enum ContentScalingMode { case fill, fit }
    private var contentScalingMode: ContentScalingMode = .fill
    /// `.resize` is used only for a very small aspect mismatch caused by apps which quantize their
    /// window dimensions (for example Ghostty's character grid). Keep this separately from the
    /// requested fill/fit policy so interaction geometry mirrors the layer's effective rendering.
    private var stretchesMinorAspectMismatch = false

    func setContentScalingMode(_ mode: ContentScalingMode) {
        contentScalingMode = mode
        refreshVideoGravity()
    }

    private func refreshVideoGravity() {
        let shouldStretch = contentScalingMode == .fill
            && PiPContentScalingPolicy.shouldStretchMinorAspectMismatch(
                containerSize: bounds.size,
                capturedContentSize: nativeSize
            )
        stretchesMinorAspectMismatch = shouldStretch
        if contentScalingMode == .fit {
            displayLayer.videoGravity = .resizeAspect
        } else {
            displayLayer.videoGravity = shouldStretch ? .resize : .resizeAspectFill
        }
    }

    private enum DragMode {
        case movingPanel(mouseDownScreenPoint: NSPoint, initialWindowOrigin: NSPoint)
        case resizing(edge: ResizeEdge, mouseDownScreenPoint: NSPoint, initialFrame: NSRect)
    }

    private struct ResizeEdge: OptionSet {
        let rawValue: Int
        static let left = ResizeEdge(rawValue: 1 << 0)
        static let right = ResizeEdge(rawValue: 1 << 1)
        static let top = ResizeEdge(rawValue: 1 << 2)
        static let bottom = ResizeEdge(rawValue: 1 << 3)
    }

    private static let edgeGrabInset: CGFloat = 10
    /// AppKit exposes only horizontal and vertical resize cursors. Rotate the native horizontal
    /// cursor instead of drawing a new symbol so diagonal corners retain the system cursor's
    /// outline, contrast and accessibility-friendly shape.
    private static let diagonalResizeNWSECursor = makeDiagonalResizeCursor(rotation: -45)
    private static let diagonalResizeNESWCursor = makeDiagonalResizeCursor(rotation: 45)
    private var dragMode: DragMode?
    private var trackingArea: NSTrackingArea?

    /// false for a freshly-opened panel — see this type's own doc comment for the "move mode" vs
    /// "control mode" split this gates. Set true the moment a double-click on the content is
    /// detected in mouseDown; set back to false by resetToMoveMode() (PiPPanelController, wired to
    /// InteractionForwarder.onCaptureEnded) every time cursor capture actually ends, so control
    /// mode only lasts for one "session" of controlling the source rather than latching permanently
    /// after the first double-click — see resetToMoveMode's own doc comment for why that matters.
    private var hasEnteredControlMode = false

    /// Set by PiPPanelController (following PiPSessionManager.stackAllSessions/unstackSessions)
    /// while this panel is sitting in the Notification-Center-style overlapping stack. While true,
    /// every one of this view's normal gestures — move-drag, resize, double-click into control
    /// mode, hover-capture — is suspended in favor of one thing: any mouseDown at all just asks to
    /// unstack the whole group (videoViewDidRequestUnstack), same as clicking a stack of
    /// notifications expands it. There'd be no sensible way to resize or move-drag one layer of an
    /// intentionally-overlapping pile anyway; this makes that moot rather than leaving those
    /// gestures live and confusing while several panels are covering each other.
    var isPartOfStack = false

    /// The screen CloseDropZoneOverlay's circular target was shown on for the current move drag
    /// — fixed for the duration of the drag (chosen from wherever the panel started) rather than
    /// recomputed on every mouseDragged, so the target doesn't jump between screens mid-drag.
    private var closeDropZoneScreen: NSScreen?

    /// Stands in for the real system cursor while InteractionForwarder has it captured on the
    /// virtual display (and therefore genuinely off-screen, invisible on any real display) — the
    /// mirrored video itself never includes a cursor either (CaptureSession's showsCursor is
    /// false), so without this there'd be no visual feedback at all for where the pointer is
    /// while hovering the panel. Uses the actual system arrow image so it reads as "your cursor,"
    /// just relocated, rather than some unrelated indicator.
    private let capturedCursorIndicator: NSImageView = {
        let imageView = NSImageView(image: NSCursor.arrow.image)
        imageView.isHidden = true
        imageView.wantsLayer = true
        imageView.layer?.shadowColor = NSColor.black.cgColor
        imageView.layer?.shadowOpacity = 0.5
        imageView.layer?.shadowRadius = 1.5
        imageView.layer?.shadowOffset = CGSize(width: 0.5, height: -0.5)
        return imageView
    }()

    /// The panel itself appears immediately (PiPPanelController.animateEntrance's slide-in), but
    /// the underlying pipeline behind it — virtual display creation, moving the source window onto
    /// it, ScreenCaptureKit discovering the new display, starting the stream — can take anywhere
    /// from under a second up to several seconds (CaptureSession.waitForShareableDisplay's own doc
    /// comment) before the first real frame ever reaches enqueue(_:nativeSize:) below. Until then,
    /// displayLayer has nothing queued and just shows through to this view's plain black
    /// background — reading as "broken" rather than "starting up." A plain spinner over that same
    /// black background is a minimal, low-risk fix for the *perceived* wait — it doesn't touch any
    /// of the actual pipeline timing (already tuned against real observed latency), just gives the
    /// wait something to look at instead of a blank void.
    private let loadingIndicator: NSProgressIndicator = {
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.isIndeterminate = true
        indicator.controlSize = .regular
        // Forces the spinner's own light-on-dark rendering regardless of the system's current
        // light/dark appearance — this view's background is always black, so the indicator needs
        // to always be the light variant, not whichever one matches the system.
        indicator.appearance = NSAppearance(named: .darkAqua)
        return indicator
    }()
    private var hasShownFirstFrame = false

    /// Shown at the top of the panel, mirroring the source window's own title — see
    /// updateTitleLabel's doc comment for when it's actually visible.
    private let titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        label.layer?.cornerRadius = 6
        label.isHidden = true
        return label
    }()
    /// The source window's own title, set once by PiPPanelController right after this view is
    /// created — nil until then, and never shown at all unless SettingsStore.panelTitleEnabled is
    /// also true (read once at init, same "only affects new panels" contract every other
    /// appearance setting here follows).
    var titleText: String? {
        didSet { updateTitleLabel() }
    }

    /// Shown instead of displayLayer while lyrics mode is active (PiPPanelController.
    /// setLyricsMode) — a plain sibling subview, same "another thing shown instead of the video"
    /// pattern as loadingIndicator/titleLabel. Exposed (not private) so PiPPanelController can
    /// push track/lyric updates into it directly without this view needing to know anything about
    /// LyricsController itself.
    let lyricsView = PiPLyricsView(frame: .zero)

    /// Set once by PiPPanelController right after this view is created (from
    /// WindowEnumerator.isKnownMusicApp, computed at PiPSessionManager.startSession time) — gates
    /// whether lyricsToggleButton is ever shown at all.
    var isMusicApp: Bool = false {
        didSet {
            if isMusicApp { musicControlsBar.mode = .music }
            updateLyricsToggleButton()
        }
    }
    /// Browsers and native video players supported by WindowEnumerator. Browser eligibility alone
    /// doesn't reveal anything: setVideoPlaybackAvailable(_:playing:) also has to confirm that
    /// this exact window matches the system's active media session.
    var isVideoApp: Bool = false {
        didSet {
            if isVideoApp { musicControlsBar.mode = .video }
            if !isVideoApp { setVideoPlaybackAvailable(false, playing: false) }
        }
    }
    private(set) var isVideoPlaybackAvailable = false
    /// True once lyrics mode has actually been toggled on for this panel — only used to swap the
    /// button's own icon between "show lyrics" and "show video" so it reads as a real toggle
    /// rather than a one-way action; the actual mode switch itself lives in PiPPanelController.
    private(set) var isLyricsModeActive = false

    private let lyricsToggleButton: NSButton = {
        let button = NSButton(image: NSImage(systemSymbolName: "quote.bubble.fill", accessibilityDescription: "歌词") ?? NSImage(), target: nil, action: nil)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .white
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        button.layer?.cornerRadius = 12
        button.isHidden = true
        return button
    }()

    /// Shown only while the real cursor is hovering the bottom strip of a supported playback panel
    /// (see controlsBarHoverZone in mouseMoved below) — the same "reveal controls near an edge on
    /// hover" the real iOS/macOS PiP window uses. Video sources additionally need a matching active
    /// media session, so an idle browser window never exposes a control for some other window's
    /// panel's hover/capture/drag behavior is completely untouched by this feature.
    let musicControlsBar = PiPMusicControlsBar(frame: .zero)
    private static let musicControlsBarHoverZone: CGFloat = 42
    private static let musicControlsBarSize = CGSize(width: 116, height: 34)
    private static let videoControlsBarSize = CGSize(width: 50, height: 34)
    private var isMusicControlsBarVisible = false

    /// Covers source-window migration and live resize reflow. These are tracked as independent
    /// reasons so a post-migration frame arriving mid-resize cannot hide the glass too early.
    private let transitionGlassView: ResizeGlassOverlayView = {
        let glass = ResizeGlassOverlayView(frame: .zero)
        glass.alphaValue = 0
        glass.isHidden = true
        return glass
    }()
    private enum WindowMigrationGlassState {
        case inactive
        case moving
        case awaitingPostMoveFrame
    }
    private var windowMigrationGlassState: WindowMigrationGlassState = .inactive
    private var isResizeGlassVisible = false

    /// The alternative to CloseDropZoneOverlay's drag-to-close gesture — see SettingsStore.
    /// panelCloseMethod's own doc comment. Always a subview (cheap to keep around hidden), shown/
    /// hidden live from layout() by reading the setting fresh each time, same "live, not cached"
    /// contract as panelLyricsEnabled/updateLyricsToggleButton.
    private let closeCornerControl = PiPCloseCornerControl(frame: .zero)
    // 24pt button plus 8pt breathing room on each side. The wrapper's transparent margin passes
    // clicks through via PiPCloseCornerControl.hitTest(_:).
    private static let closeCornerControlSize: CGFloat = 40

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(hex: SettingsStore.shared.panelBackgroundColorHex)?.cgColor ?? NSColor.black.cgColor
        layer?.cornerRadius = CGFloat(SettingsStore.shared.panelCornerRadius)
        layer?.masksToBounds = true

        // Starts in .fill — see contentScalingMode's doc comment for when/why this switches.
        displayLayer.videoGravity = .resizeAspectFill
        displayLayer.frame = bounds
        displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(displayLayer)

        // Install glass immediately above the video but below the loading indicator and controls.
        // It starts hidden and is activated only by a real source move or an interactive resize.
        addSubview(transitionGlassView)

        capturedCursorIndicator.frame = CGRect(origin: .zero, size: capturedCursorIndicator.image?.size ?? .zero)
        addSubview(capturedCursorIndicator)

        loadingIndicator.sizeToFit()
        addSubview(loadingIndicator)
        repositionLoadingIndicator()
        loadingIndicator.startAnimation(nil)

        addSubview(titleLabel)
        updateTitleLabel()

        lyricsView.isHidden = true
        addSubview(lyricsView)

        lyricsToggleButton.target = self
        lyricsToggleButton.action = #selector(lyricsToggleButtonPressed)
        addSubview(lyricsToggleButton)

        musicControlsBar.delegate = self
        addSubview(musicControlsBar)

        closeCornerControl.delegate = self
        closeCornerControl.isHidden = true
        addSubview(closeCornerControl)

        updateBorderAppearance()
    }

    @objc private func lyricsToggleButtonPressed() {
        interactionDelegate?.videoViewDidToggleLyricsMode(self)
    }

    /// Called by PiPPanelController.setLyricsMode after it flips displayLayer/lyricsView
    /// visibility, purely so this button's own icon reflects which mode is currently active
    /// (a filled "quote bubble" to invite switching to lyrics, an outlined "photo/video" glyph to
    /// invite switching back) — the actual content swap itself is owned by PiPPanelController, not
    /// this view.
    func setLyricsModeActive(_ active: Bool) {
        isLyricsModeActive = active
        let symbolName = active ? "rectangle.on.rectangle" : "quote.bubble.fill"
        lyricsToggleButton.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "歌词")
    }

    func setVideoPlaybackAvailable(_ available: Bool, playing: Bool) {
        isVideoPlaybackAvailable = available
        musicControlsBar.setPlaying(available && playing)
        if !available { setMusicControlsBarVisible(false) }
    }

    private var canShowPlaybackControls: Bool {
        isMusicApp || (isVideoApp && isVideoPlaybackAvailable)
    }

    /// Shows/hides the toggle button — only ever visible for a music-app source
    /// (SettingsStore.panelLyricsEnabled read live here rather than cached, since it's a plain
    /// visibility toggle the user should see take effect immediately rather than needing the
    /// panel recreated). Also requires an active membership — this is a Pro-only feature per the
    /// user's own explicit choice, and MembershipGate in AppearanceSettingsView only disables the
    /// *settings toggle itself* for non-members; it doesn't stop panelLyricsEnabled from already
    /// defaulting to true, so the actual membership check has to happen here too, not just in the
    /// Settings UI.
    private func updateLyricsToggleButton() {
        lyricsToggleButton.isHidden = !(
            isMusicApp && SettingsStore.shared.panelLyricsEnabled && MembershipManager.shared.isMember
        )
    }

    /// Positions/shows the title label — a no-op (stays hidden) unless both panelTitleEnabled is
    /// on and titleText has actually been set to something. Sized to fit its text plus fixed
    /// padding, anchored top-center with a small margin from the panel's own top edge.
    private func updateTitleLabel() {
        guard SettingsStore.shared.panelTitleEnabled, let titleText, !titleText.isEmpty else {
            titleLabel.isHidden = true
            return
        }
        titleLabel.stringValue = titleText
        titleLabel.sizeToFit()
        let horizontalPadding: CGFloat = 8
        let verticalPadding: CGFloat = 3
        let width = titleLabel.frame.width + horizontalPadding * 2
        let height = titleLabel.frame.height + verticalPadding * 2
        titleLabel.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        titleLabel.frame = CGRect(x: (bounds.width - width) / 2, y: bounds.height - height - 8, width: width, height: height)
        titleLabel.isHidden = false
    }

    /// Draws whichever edge style SettingsStore.panelBorderStyle currently selects — read once at
    /// init, not observed live (same "only affects new panels" contract as panelCornerRadius/
    /// panelShadowEnabled).
    ///
    /// .stroke is the simple case: CALayer's own borderWidth/borderColor already respect
    /// cornerRadius natively, no extra layer needed. The other three styles all need something
    /// that only shows up in a *ring* around the edge, content-hole in the middle — a plain
    /// full-bounds layer would just cover the video entirely — so they share one ring-shaped
    /// CAShapeLayer mask (ringMask(insetBy:)) applied to a differently-filled layer each:
    /// a blurred NSVisualEffectView for .frostedGlass, a CAGradientLayer for .gradient, and a
    /// solid, softly-shadowed layer for .glow. .glow's "glow" stays inside the panel's own
    /// clipped bounds (an inner rim rather than a true halo bleeding past the edge) — a true
    /// outer glow would need panel.contentView restructured into an unclipped wrapper around this
    /// view specifically to host it, which is a lot more surface area for a purely cosmetic
    /// effect that reads close enough to the same thing at this size.
    private func updateBorderAppearance() {
        borderLayer?.removeFromSuperlayer()
        borderView?.removeFromSuperview()
        borderLayer = nil
        borderView = nil

        let style = SettingsStore.shared.panelBorderStyle
        let width = CGFloat(SettingsStore.shared.panelBorderWidth)
        let color = NSColor(hex: SettingsStore.shared.panelBorderColorHex) ?? .white

        switch style {
        case .none:
            layer?.borderWidth = 0
        case .stroke:
            layer?.borderWidth = width
            layer?.borderColor = color.cgColor
        case .frostedGlass:
            layer?.borderWidth = 0
            let effectView = NSVisualEffectView(frame: bounds)
            effectView.material = .hudWindow
            effectView.blendingMode = .withinWindow
            effectView.state = .active
            effectView.autoresizingMask = [.width, .height]
            effectView.layer?.mask = ringMask(insetBy: width)
            addSubview(effectView)
            borderView = effectView
        case .gradient:
            layer?.borderWidth = 0
            let gradient = CAGradientLayer()
            gradient.frame = bounds
            gradient.colors = [color.cgColor, (NSColor(hex: SettingsStore.shared.panelBorderGradientEndColorHex) ?? color).cgColor]
            gradient.startPoint = CGPoint(x: 0, y: 1)
            gradient.endPoint = CGPoint(x: 1, y: 0)
            gradient.mask = ringMask(insetBy: width)
            layer?.addSublayer(gradient)
            borderLayer = gradient
        case .glow:
            layer?.borderWidth = 0
            let glow = CALayer()
            glow.frame = bounds
            glow.backgroundColor = color.withAlphaComponent(0.55).cgColor
            glow.mask = ringMask(insetBy: width)
            glow.shadowColor = color.cgColor
            glow.shadowRadius = width * 1.5
            glow.shadowOpacity = 0.8
            glow.shadowOffset = .zero
            layer?.addSublayer(glow)
            borderLayer = glow
        }
    }

    /// Kept alive so layout() can re-frame it as this view resizes — only one of borderLayer/
    /// borderView is ever non-nil at a time, matching whichever branch updateBorderAppearance took.
    private var borderLayer: CALayer?
    private var borderView: NSView?

    /// PiPPanelController renders the actual glow in a separate, non-interactive transparent
    /// window, because pixels outside this view are clipped by the PiP panel's window bounds.
    /// This view remains the source of truth for control state and reports live setting changes.
    private(set) var isControlModeActive = false
    var onControlModeAppearanceChanged: ((Bool) -> Void)?

    func setControlModeActive(_ active: Bool) {
        isControlModeActive = active
        refreshControlModeGlowPreference()
    }

    func refreshControlModeGlowPreference() {
        onControlModeAppearanceChanged?(
            isControlModeActive && SettingsStore.shared.controlModeGlowEnabled
        )
    }

    /// A shape that fills a ring width points wide just inside this view's own rounded-rect
    /// bounds, hollow in the middle (even-odd fill between an outer and an inset-by-width inner
    /// rounded rect) — used as a `.mask` so whatever it's applied to (a blur view, a gradient
    /// layer, a solid glow layer) only ever shows up as a border, never covering the content.
    private func ringMask(insetBy width: CGFloat) -> CAShapeLayer {
        let radius = layer?.cornerRadius ?? 0
        let outerPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let innerRect = bounds.insetBy(dx: width, dy: width)
        let innerRadius = max(radius - width, 0)
        let innerPath = CGPath(roundedRect: innerRect, cornerWidth: innerRadius, cornerHeight: innerRadius, transform: nil)
        let combined = CGMutablePath()
        combined.addPath(outerPath)
        combined.addPath(innerPath)
        let mask = CAShapeLayer()
        mask.path = combined
        mask.fillRule = .evenOdd
        return mask
    }

    /// Keeps the loading indicator centered as this view's own size changes — from a PiP-panel
    /// resize, or just the initial frame not matching whatever size the panel eventually settles
    /// at. Equal flexible margins on every side (fixed size in between) handle that automatically.
    private func repositionLoadingIndicator() {
        loadingIndicator.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        let x = (bounds.width - loadingIndicator.frame.width) / 2
        loadingIndicator.setFrameOrigin(CGPoint(x: x, y: (bounds.height - loadingIndicator.frame.height) / 2))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        refreshVideoGravity()
        if let borderLayer {
            borderLayer.frame = bounds
            borderLayer.mask = ringMask(insetBy: CGFloat(SettingsStore.shared.panelBorderWidth))
        }
        if let borderView {
            borderView.frame = bounds
            borderView.layer?.mask = ringMask(insetBy: CGFloat(SettingsStore.shared.panelBorderWidth))
        }
        CATransaction.commit()
        updateTitleLabel()

        lyricsView.frame = bounds
        transitionGlassView.frame = bounds
        transitionGlassView.layer?.cornerRadius = CGFloat(SettingsStore.shared.panelCornerRadius)

        let buttonSize: CGFloat = 24
        let buttonMargin: CGFloat = 8
        lyricsToggleButton.frame = CGRect(
            x: bounds.width - buttonSize - buttonMargin,
            y: bounds.height - buttonSize - buttonMargin,
            width: buttonSize,
            height: buttonSize
        )

        let barSize = isVideoApp ? Self.videoControlsBarSize : Self.musicControlsBarSize
        let barBottomMargin: CGFloat = 6
        musicControlsBar.frame = CGRect(
            x: (bounds.width - barSize.width) / 2,
            y: barBottomMargin,
            width: barSize.width,
            height: barSize.height
        )

        closeCornerControl.isHidden = SettingsStore.shared.panelCloseMethod != .cornerButton
        let controlSize = Self.closeCornerControlSize
        closeCornerControl.frame = CGRect(
            x: 0,
            y: bounds.height - controlSize,
            width: controlSize,
            height: controlSize
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        // .mouseMoved is what lets a plain hover (no button down) trigger cursor capture — see
        // mouseMoved(with:) below. Edge-docking no longer touches this view at all — a docked group
        // is represented by EdgeHandleWindow, a completely separate, always-fully-on-screen window,
        // not a partially-off-screen sliver of this one — so there's no reveal/re-hide hand-off to
        // wire up here anymore.
        // .mouseEnteredAndExited is what lets mouseExited(with:) hide musicControlsBar the moment
        // the cursor leaves the panel entirely — mouseMoved alone only fires while still inside
        // bounds, so without this a bar revealed near the bottom edge would stay visible forever
        // once the cursor moved off the panel from within that same bottom strip.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    /// A plain hover (not near a resize edge, no Option held — both reserved for panel gestures)
    /// only triggers cursor capture once hasEnteredControlMode is true; PiPPanelController wires
    /// that straight through to InteractionForwarder.beginCaptureIfNeeded(atLocalPoint:), which
    /// no-ops if already captured. Before that (fresh panel, still in move mode), hovering just
    /// shows an open-hand cursor hinting that a drag here moves the panel — see mouseDown for
    /// where that drag, and the double-click that flips hasEnteredControlMode, are both handled.
    ///
    /// The resize hot-zone (edgeGrabInset, 10pt) had no cursor feedback at all — nothing visually
    /// distinguished it from the rest of the content, on a panel with rounded corners and a
    /// shadow blurring exactly where its edge actually is. Landing a mouseDown inside those 10pt
    /// is the *only* way resizing engages at all (see mouseDown below); missing it by a few points
    /// just silently falls through to cursor capture (or the move-drag) instead, with no sign
    /// anything went wrong — which reads as "resizing doesn't work" when it's actually "the grab
    /// zone was never found." Swapping in a resize cursor while hovering it makes that zone
    /// findable, in either mode — checked first, before the mode split below.
    override func mouseMoved(with event: NSEvent) {
        guard !isPartOfStack else {
            NSCursor.pointingHand.set()
            return
        }
        guard dragMode == nil, !event.modifierFlags.contains(.option) else { return }
        let point = convert(event.locationInWindow, from: nil)
        let edge = resizeEdge(at: point)
        guard edge.isEmpty else {
            setResizeCursor(for: edge)
            return
        }

        // Checked ahead of the move/control-mode split below, same as the resize-edge check above
        // it: hovering this strip should reveal musicControlsBar and stop there, rather than also
        // handing off to cursor capture — capture warps the real cursor onto the virtual display
        // (InteractionForwarder.beginCaptureIfNeeded), which would make it physically impossible to
        // then reach the very buttons this hover was meant to reveal.
        if canShowPlaybackControls {
            let hovering = point.y <= Self.musicControlsBarHoverZone
            setMusicControlsBarVisible(hovering)
            if hovering {
                NSCursor.arrow.set()
                return
            }
        }

        guard hasEnteredControlMode else {
            NSCursor.openHand.set()
            return
        }
        NSCursor.arrow.set()
        interactionDelegate?.videoView(self, didHoverContentAt: point)
    }

    override func mouseExited(with event: NSEvent) {
        if canShowPlaybackControls {
            setMusicControlsBarVisible(false)
        }
    }

    private func setMusicControlsBarVisible(_ visible: Bool) {
        guard visible != isMusicControlsBarVisible else { return }
        isMusicControlsBarVisible = visible
        musicControlsBar.setVisible(visible, animated: true)
    }

    private func setResizeCursor(for edge: ResizeEdge) {
        let isHorizontal = edge.contains(.left) || edge.contains(.right)
        let isVertical = edge.contains(.top) || edge.contains(.bottom)

        if isHorizontal && isVertical {
            let isNWSE = (edge.contains(.left) && edge.contains(.top))
                || (edge.contains(.right) && edge.contains(.bottom))
            (isNWSE ? Self.diagonalResizeNWSECursor : Self.diagonalResizeNESWCursor).set()
        } else if isHorizontal {
            NSCursor.resizeLeftRight.set()
        } else if isVertical {
            NSCursor.resizeUpDown.set()
        }
    }

    private static func makeDiagonalResizeCursor(rotation: CGFloat) -> NSCursor {
        let source = NSCursor.resizeLeftRight.image
        let side = ceil(hypot(source.size.width, source.size.height))
        let canvasSize = CGSize(width: side, height: side)
        let image = NSImage(size: canvasSize, flipped: false) { rect in
            guard let context = NSGraphicsContext.current else { return false }
            context.saveGraphicsState()
            context.imageInterpolation = .high

            let transform = NSAffineTransform()
            transform.translateX(by: rect.midX, yBy: rect.midY)
            transform.rotate(byDegrees: rotation)
            transform.translateX(by: -source.size.width / 2, yBy: -source.size.height / 2)
            transform.concat()
            source.draw(
                in: CGRect(origin: .zero, size: source.size),
                from: CGRect(origin: .zero, size: source.size),
                operation: .sourceOver,
                fraction: 1
            )
            context.restoreGraphicsState()
            return true
        }
        return NSCursor(
            image: image,
            hotSpot: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        )
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer, nativeSize: CGSize) {
        self.nativeSize = nativeSize
        refreshVideoGravity()
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        // ScreenCaptureKit timestamps describe when the desktop frame was captured. Any main-loop
        // delay between capture and enqueue can make that time older than the next presentation
        // opportunity, which AVSampleBufferDisplayLayer treats as a late frame. Rebase only the
        // output presentation time onto the current host clock; the IOSurface remains zero-copy.
        _ = CMSampleBufferSetOutputPresentationTimeStamp(
            sampleBuffer,
            newValue: CMClockGetTime(CMClockGetHostTimeClock())
        )
        displayLayer.enqueue(sampleBuffer)
        finishWindowMigrationGlassAfterPresentedFrameIfNeeded()
        if !hasShownFirstFrame {
            hasShownFirstFrame = true
            hideLoadingIndicator()
        }
    }

    func sourceWindowWillMoveOntoVirtualDisplay() {
        windowMigrationGlassState = .moving
        refreshTransitionGlassVisibility(animated: true)
    }

    func sourceWindowDidMoveOntoVirtualDisplay() {
        guard windowMigrationGlassState != .inactive else { return }
        windowMigrationGlassState = .awaitingPostMoveFrame
    }

    private func finishWindowMigrationGlassAfterPresentedFrameIfNeeded() {
        guard windowMigrationGlassState == .awaitingPostMoveFrame else { return }
        windowMigrationGlassState = .inactive
        // Let the newly-enqueued buffer reach AVSampleBufferDisplayLayer before revealing it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.refreshTransitionGlassVisibility(animated: true)
        }
    }

    /// A quick fade rather than an instant removal — the first real frame landing right as the
    /// spinner vanishes reads as a deliberate handoff rather than a jarring swap.
    private func hideLoadingIndicator() {
        loadingIndicator.stopAnimation(nil)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            loadingIndicator.animator().alphaValue = 0
        }, completionHandler: { [weak loadingIndicator] in
            loadingIndicator?.isHidden = true
        })
    }

    /// A one-shot ripple — a ring expanding from the center and fading out — played once the
    /// panel finishes sliding into place (PiPPanelController.animateEntrance). Purely a CALayer
    /// animation on this view's own layer, so unlike the real-window animation this replaced
    /// (manually stepping another process's Accessibility frame/alpha at fixed intervals), it's
    /// entirely GPU-composited by AppKit/CoreAnimation and stays smooth regardless of anything
    /// else going on.
    func playAppearRipple() {
        guard SettingsStore.shared.panelAppearRippleEnabled, let rootLayer = layer else { return }
        let diameter = min(bounds.width, bounds.height) * 0.7
        let ripple = CALayer()
        ripple.frame = CGRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2, width: diameter, height: diameter)
        ripple.cornerRadius = diameter / 2
        ripple.borderWidth = 2
        ripple.borderColor = NSColor.white.cgColor
        ripple.backgroundColor = NSColor.clear.cgColor
        ripple.opacity = 0
        rootLayer.addSublayer(ripple)

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.5
        scale.toValue = 1.5

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0, 0.85, 0]
        opacity.keyTimes = [0, 0.25, 1]

        let group = CAAnimationGroup()
        group.animations = [scale, opacity]
        group.duration = 0.5
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        ripple.add(group, forKey: "appearRipple")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak ripple] in
            ripple?.removeFromSuperlayer()
        }
    }

    /// The actual on-screen rect the video content occupies inside this view, matching whichever
    /// of contentScalingMode's layouts is currently active:
    ///  - .fill (crop-to-cover): when the panel's aspect doesn't match the source window's, this
    ///    is *larger* than bounds in one dimension (centered, clipped by the layer's
    ///    masksToBounds).
    ///  - .fit (scale-to-contain): the mirror image of that — *smaller* than bounds in one
    ///    dimension (centered, letterboxed/pillarboxed by the panel's own black background).
    /// CoordinateTranslator/cursor-capture math works unchanged against either: a bounds-contained
    /// click always falls inside a .fill rect (which itself contains bounds), and for .fit the
    /// existing "outside displayedVideoRect" guard in CoordinateTranslator correctly rejects
    /// clicks that land in the letterbox bars rather than on the mirrored content itself.
    func displayedVideoRect(nativeSize: CGSize) -> CGRect {
        guard nativeSize.width > 0, nativeSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        if stretchesMinorAspectMismatch {
            return bounds
        }
        let viewAspect = bounds.width / bounds.height
        let videoAspect = nativeSize.width / nativeSize.height
        // .fill grows past bounds on whichever axis needs it to cover; .fit shrinks below bounds
        // on the *other* axis to stay contained — same two branches, just swapped.
        let widthDrivenByHeight = (contentScalingMode == .fill) == (videoAspect > viewAspect)
        if widthDrivenByHeight {
            let width = bounds.height * videoAspect
            let x = (bounds.width - width) / 2
            return CGRect(x: x, y: 0, width: width, height: bounds.height)
        } else {
            let height = bounds.width / videoAspect
            let y = (bounds.height - height) / 2
            return CGRect(x: 0, y: y, width: bounds.width, height: height)
        }
    }

    // MARK: - Captured cursor indicator

    func showCapturedCursorIndicator(atLocalPoint point: CGPoint) {
        positionCapturedCursorIndicator(atLocalPoint: point)
        capturedCursorIndicator.isHidden = false
    }

    func updateCapturedCursorIndicator(atLocalPoint point: CGPoint) {
        positionCapturedCursorIndicator(atLocalPoint: point)
    }

    func hideCapturedCursorIndicator() {
        capturedCursorIndicator.isHidden = true
    }

    private func positionCapturedCursorIndicator(atLocalPoint point: CGPoint) {
        // NSCursor's hotSpot is in the image's own top-left-origin coordinate system; this view
        // is a normal (non-flipped, bottom-left-origin) AppKit view, hence the height flip below.
        let hotSpot = NSCursor.arrow.hotSpot
        let size = capturedCursorIndicator.frame.size
        capturedCursorIndicator.setFrameOrigin(CGPoint(
            x: point.x - hotSpot.x,
            y: point.y - (size.height - hotSpot.y)
        ))
    }

    // MARK: - Input capture

    /// Called by PiPPanelController (wired to InteractionForwarder.onCaptureEnded) every time
    /// cursor capture actually ends, so control mode only lasts one "session" of controlling the
    /// source rather than latching permanently after the first double-click. Without this, a plain
    /// hover always re-triggers capture once hasEnteredControlMode is true, and hovering
    /// unavoidably happens before a plain mouseDown ever could reach this view — so the *first*
    /// double-click that ever happened would end up permanently requiring Option to move the panel
    /// for the rest of the session, even long after the user was done controlling the source and
    /// had moved on. Resetting here instead means moving the mouse off the panel to end an
    /// interaction hands it back to being freely draggable, matching a freshly-opened panel, and
    /// it only takes another double-click to hand control back to the source again.
    func resetToMoveMode() {
        hasEnteredControlMode = false
    }

    /// Lets clicks land immediately (as real mouseDown events) instead of the first click on a
    /// background window being absorbed just to bring it forward — we want click-to-forward to
    /// work without ever visually disturbing the panel or stealing focus.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard !isPartOfStack else {
            interactionDelegate?.videoViewDidRequestUnstack(self)
            return
        }
        // A plain click/drag on the content never reaches here while cursor capture is active —
        // the real cursor isn't actually over this view once captured, so AppKit routes real
        // mouseDown/mouseDragged/mouseUp straight to the source window instead. This only fires
        // for the panel's own gestures below (edge-resize, move-drag/double-click, Option-drag),
        // which capture never engages for in the first place (see mouseMoved(with:)).
        let point = convert(event.locationInWindow, from: nil)

        let edge = resizeEdge(at: point)
        if !edge.isEmpty, let window {
            dragMode = .resizing(edge: edge, mouseDownScreenPoint: NSEvent.mouseLocation, initialFrame: window.frame)
            setResizeGlassVisible(true, animated: true)
            return
        }

        if !hasEnteredControlMode {
            // The double-click that gates entry into control mode. There's no way to know, right
            // on the *first* press of what might become a double-click, that a second one is
            // coming — AppKit only reports clickCount 2 once that second press actually lands —
            // so the first press already starts a move-drag below rather than waiting to find
            // out; a genuine stationary double-click won't have moved the panel any perceptible
            // amount by the time this second mouseDown arrives anyway. Hover-capturing
            // immediately (rather than waiting for the next real mouseMoved) makes the transition
            // feel instant instead of needing an extra wiggle of the mouse first.
            if event.clickCount >= 2 {
                hasEnteredControlMode = true
                interactionDelegate?.videoView(self, didHoverContentAt: point)
                return
            }
            startMovingPanel()
            return
        }

        if event.modifierFlags.contains(.option) {
            startMovingPanel()
        }
    }

    /// Shared by mouseDown's two move-drag triggers: the plain first click while still in move
    /// mode, and an Option+click once already in control mode (control mode's own default is
    /// hover-capture, so Option is what carves out room for this instead there — same as before
    /// hasEnteredControlMode existed at all).
    private func startMovingPanel() {
        guard let window else { return }
        dragMode = .movingPanel(mouseDownScreenPoint: NSEvent.mouseLocation, initialWindowOrigin: window.frame.origin)
        // closeDropZoneScreen stays nil under .cornerButton — mouseDragged/mouseUp's own
        // `if let`/`.map` checks on it then naturally skip ever showing, highlighting, or
        // dropping into CloseDropZoneOverlay, leaving the corner button as the only way to close.
        // Dragging mostly off-screen (isFrameMostlyOffscreen, in mouseUp) is deliberately left
        // active either way — that's a distinct "fling it away" gesture, not "the red zone" this
        // setting is actually choosing between.
        guard SettingsStore.shared.panelCloseMethod == .dragToZone else { return }
        let screen = mostOverlappingScreen(window.frame) ?? NSScreen.main
        closeDropZoneScreen = screen
        if let screen {
            CloseDropZoneOverlay.shared.show(on: screen)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragMode, let window else { return }
        interactionDelegate?.videoViewDidBeginUserGeometryChange(self)
        let current = NSEvent.mouseLocation
        switch dragMode {
        case .movingPanel(let start, let initialOrigin):
            window.setFrameOrigin(NSPoint(x: initialOrigin.x + (current.x - start.x), y: initialOrigin.y + (current.y - start.y)))
            if let screen = closeDropZoneScreen {
                CloseDropZoneOverlay.shared.setHighlighted(CloseDropZoneOverlay.intersects(window.frame, on: screen))
            }

        case .resizing(let edge, let start, let initialFrame):
            let dx = current.x - start.x
            let dy = current.y - start.y
            let minSize = window.minSize
            // window.setFrame doesn't itself enforce minSize/maxSize (those are only applied by
            // AppKit's own interactive-resize machinery, which this custom edge-drag bypasses) —
            // so both ends have to be clamped by hand here, same as minSize already was. Without
            // the maxSize half, nothing stopped this from growing the panel past what the virtual
            // display can actually back (PiPPanelController.panel.maxSize), silently desyncing the
            // mirrored source window's real size from the panel's.
            let maxSize = window.maxSize
            var frame = initialFrame
            if edge.contains(.right) {
                frame.size.width = min(max(initialFrame.width + dx, minSize.width), maxSize.width)
            }
            if edge.contains(.left) {
                let newWidth = min(max(initialFrame.width - dx, minSize.width), maxSize.width)
                frame.origin.x = initialFrame.maxX - newWidth
                frame.size.width = newWidth
            }
            if edge.contains(.top) {
                frame.size.height = min(max(initialFrame.height + dy, minSize.height), maxSize.height)
            }
            if edge.contains(.bottom) {
                let newHeight = min(max(initialFrame.height - dy, minSize.height), maxSize.height)
                frame.origin.y = initialFrame.maxY - newHeight
                frame.size.height = newHeight
            }
            window.setFrame(frame, display: true)
            interactionDelegate?.videoView(self, didResizeTo: frame.size)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let wasResizing: Bool
        if case .resizing = dragMode {
            wasResizing = true
        } else {
            wasResizing = false
        }
        defer {
            if wasResizing {
                setResizeGlassVisible(false, animated: true)
            }
            dragMode = nil
            closeDropZoneScreen = nil
        }
        if case .resizing = dragMode, let window {
            interactionDelegate?.videoView(self, didResizeTo: window.frame.size)
        }
        guard case .movingPanel = dragMode, let window else {
            CloseDropZoneOverlay.shared.hide()
            return
        }
        let droppedInZone = closeDropZoneScreen.map { CloseDropZoneOverlay.intersects(window.frame, on: $0) } ?? false
        if droppedInZone {
            // Close the PiP first, then remove the target immediately in the same event turn. No
            // pulse, fade, delayed work item, or extra run-loop hop remains.
            interactionDelegate?.videoViewDidRequestCloseByDragging(self)
            CloseDropZoneOverlay.shared.hide()
        } else {
            CloseDropZoneOverlay.shared.hide()
            if isFrameMostlyOffscreen(window.frame) {
                interactionDelegate?.videoViewDidRequestCloseByDragging(self)
            }
        }
    }

    private func setResizeGlassVisible(_ visible: Bool, animated: Bool) {
        guard visible != isResizeGlassVisible else { return }
        isResizeGlassVisible = visible

        refreshTransitionGlassVisibility(animated: animated)
    }

    private func refreshTransitionGlassVisibility(animated: Bool) {
        let visible = windowMigrationGlassState != .inactive || isResizeGlassVisible

        if visible {
            transitionGlassView.isHidden = false
        }

        let changes = {
            self.transitionGlassView.animator().alphaValue = visible ? 1 : 0
        }
        guard animated else {
            transitionGlassView.alphaValue = visible ? 1 : 0
            if !visible {
                transitionGlassView.isHidden = true
            }
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = visible ? 0.12 : 0.32
            context.timingFunction = CAMediaTimingFunction(name: visible ? .easeOut : .easeInEaseOut)
            changes()
        }, completionHandler: { [weak self] in
            guard let self, self.windowMigrationGlassState == .inactive,
                  !self.isResizeGlassVisible else { return }
            self.transitionGlassView.isHidden = true
        })
    }

    private func resizeEdge(at point: CGPoint) -> ResizeEdge {
        let inset = Self.edgeGrabInset
        var edge: ResizeEdge = []
        if point.x <= inset { edge.insert(.left) }
        if point.x >= bounds.width - inset { edge.insert(.right) }
        if point.y <= inset { edge.insert(.bottom) }
        if point.y >= bounds.height - inset { edge.insert(.top) }
        return edge
    }

    private func isFrameMostlyOffscreen(_ frame: CGRect) -> Bool {
        let totalArea = frame.width * frame.height
        guard totalArea > 0 else { return false }
        let visibleArea = realScreens.reduce(CGFloat(0)) { partial, screen in
            let intersection = frame.intersection(screen.frame)
            return partial + intersection.width * intersection.height
        }
        return visibleArea < totalArea * 0.3
    }

    /// The screen the panel currently overlaps the most — used to anchor CloseDropZoneOverlay's
    /// circular target for the duration of a move drag.
    private func mostOverlappingScreen(_ frame: CGRect) -> NSScreen? {
        realScreens.max { a, b in
            let areaA = frame.intersection(a.frame).width * frame.intersection(a.frame).height
            let areaB = frame.intersection(b.frame).width * frame.intersection(b.frame).height
            return areaA < areaB
        }
    }

    private var realScreens: [NSScreen] {
        NSScreen.screens.filter { !VirtualDisplayHost.isManagedDisplay($0) }
    }

    override func keyDown(with event: NSEvent) {
        interactionDelegate?.videoView(self, didReceiveKeyEvent: event)
    }

    override func keyUp(with event: NSEvent) {
        interactionDelegate?.videoView(self, didReceiveKeyEvent: event)
    }
}

extension PiPVideoLayerView: PiPMusicControlsBarDelegate {
    func musicControlsBar(_ bar: PiPMusicControlsBar, didSend command: PiPMusicControlsBar.Command) {
        interactionDelegate?.videoView(self, didRequestMusicCommand: command)
    }
}

extension PiPVideoLayerView: PiPCloseCornerControlDelegate {
    func closeCornerControlWasClicked(_ control: PiPCloseCornerControl) {
        interactionDelegate?.videoViewDidRequestClose(self)
    }
}
