import AppKit
import AVFoundation
import CoreMedia

@MainActor
protocol PiPVideoLayerViewDelegate: AnyObject {
    /// The real cursor moved somewhere within the content area that isn't a resize edge and
    /// isn't an Option-drag — see InteractionForwarder.beginCaptureIfNeeded for what happens
    /// next (the real cursor gets moved onto the virtual display to directly control the source).
    func videoView(_ view: PiPVideoLayerView, didHoverContentAt localPoint: CGPoint)
    func videoView(_ view: PiPVideoLayerView, didReceiveKeyEvent event: NSEvent)
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
}

/// Hosts an AVSampleBufferDisplayLayer for hardware-accelerated, zero-CPU-copy frame rendering,
/// and captures mouse/keyboard input for InteractionForwarder to replay on the real window.
///
/// Plain hovering over the video content hands control to InteractionForwarder's cursor capture
/// (the real cursor moves onto the virtual display and directly controls the source — see its
/// own doc comment) rather than this view handling clicks/drags/scrolls itself; the panel still
/// owns its own dedicated gestures so they don't collide with that: Option+drag moves the panel
/// (dropping it onto CloseDropZoneOverlay's circular target, shown in the screen's lower half for
/// the duration of the drag, or dragging it mostly off-screen entirely, both close it — like
/// pulling a menu-bar icon off the bar), and dragging within an edge margin resizes it. Both are
/// detected before capture ever engages (mouseMoved only triggers it outside the edge margin and
/// without Option held), and Option appearing mid-capture releases it immediately, so a
/// subsequent mouseDown can still reach this view for either gesture.
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

    func setContentScalingMode(_ mode: ContentScalingMode) {
        guard contentScalingMode != mode else { return }
        contentScalingMode = mode
        displayLayer.videoGravity = mode == .fill ? .resizeAspectFill : .resizeAspect
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
    private var dragMode: DragMode?
    private var trackingArea: NSTrackingArea?

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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = CGFloat(SettingsStore.shared.panelCornerRadius)
        layer?.masksToBounds = true

        // Starts in .fill — see contentScalingMode's doc comment for when/why this switches.
        displayLayer.videoGravity = .resizeAspectFill
        displayLayer.frame = bounds
        displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(displayLayer)

        capturedCursorIndicator.frame = CGRect(origin: .zero, size: capturedCursorIndicator.image?.size ?? .zero)
        addSubview(capturedCursorIndicator)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        // .mouseMoved is what lets a plain hover (no button down) trigger cursor capture — see
        // mouseMoved(with:) below.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    /// Only a plain hover (not near a resize edge, no Option held — both reserved for panel
    /// gestures) triggers cursor capture; PiPPanelController wires this straight through to
    /// InteractionForwarder.beginCaptureIfNeeded(atLocalPoint:), which no-ops if already captured.
    ///
    /// The resize hot-zone (edgeGrabInset, 10pt) had no cursor feedback at all — nothing visually
    /// distinguished it from the rest of the content, on a panel with rounded corners and a
    /// shadow blurring exactly where its edge actually is. Landing a mouseDown inside those 10pt
    /// is the *only* way resizing engages at all (see mouseDown below); missing it by a few points
    /// just silently falls through to cursor capture instead, with no sign anything went wrong —
    /// which reads as "resizing doesn't work" when it's actually "the grab zone was never found."
    /// Swapping in a resize cursor while hovering it makes that zone findable.
    override func mouseMoved(with event: NSEvent) {
        guard dragMode == nil, !event.modifierFlags.contains(.option) else { return }
        let point = convert(event.locationInWindow, from: nil)
        let edge = resizeEdge(at: point)
        guard edge.isEmpty else {
            setResizeCursor(for: edge)
            return
        }
        NSCursor.arrow.set()
        interactionDelegate?.videoView(self, didHoverContentAt: point)
    }

    /// AppKit only exposes horizontal/vertical resize cursors publicly (no diagonal one for
    /// corners) — a corner just prioritizes whichever axis has more room to matter, defaulting to
    /// horizontal, which is fine since either is a clear enough "you can resize here" signal.
    private func setResizeCursor(for edge: ResizeEdge) {
        if edge.contains(.left) || edge.contains(.right) {
            NSCursor.resizeLeftRight.set()
        } else if edge.contains(.top) || edge.contains(.bottom) {
            NSCursor.resizeUpDown.set()
        }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer, nativeSize: CGSize) {
        self.nativeSize = nativeSize
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        displayLayer.enqueue(sampleBuffer)
    }

    /// A one-shot ripple — a ring expanding from the center and fading out — played once the
    /// panel finishes sliding into place (PiPPanelController.animateEntrance). Purely a CALayer
    /// animation on this view's own layer, so unlike the real-window animation this replaced
    /// (manually stepping another process's Accessibility frame/alpha at fixed intervals), it's
    /// entirely GPU-composited by AppKit/CoreAnimation and stays smooth regardless of anything
    /// else going on.
    func playAppearRipple() {
        guard let rootLayer = layer else { return }
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

    /// Lets clicks land immediately (as real mouseDown events) instead of the first click on a
    /// background window being absorbed just to bring it forward — we want click-to-forward to
    /// work without ever visually disturbing the panel or stealing focus.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        // A plain click/drag on the content never reaches here while cursor capture is active —
        // the real cursor isn't actually over this view once captured, so AppKit routes real
        // mouseDown/mouseDragged/mouseUp straight to the source window instead. This only fires
        // for the panel's own gestures below (edge-resize, Option-drag), which capture never
        // engages for in the first place (see mouseMoved(with:)).
        let point = convert(event.locationInWindow, from: nil)

        let edge = resizeEdge(at: point)
        if !edge.isEmpty, let window {
            dragMode = .resizing(edge: edge, mouseDownScreenPoint: NSEvent.mouseLocation, initialFrame: window.frame)
            return
        }
        if event.modifierFlags.contains(.option), let window {
            dragMode = .movingPanel(mouseDownScreenPoint: NSEvent.mouseLocation, initialWindowOrigin: window.frame.origin)
            let screen = mostOverlappingScreen(window.frame) ?? NSScreen.main
            closeDropZoneScreen = screen
            if let screen {
                CloseDropZoneOverlay.shared.show(on: screen)
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragMode, let window else { return }
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
        defer {
            dragMode = nil
            closeDropZoneScreen = nil
            CloseDropZoneOverlay.shared.hide()
        }
        if case .resizing = dragMode, let window {
            interactionDelegate?.videoView(self, didResizeTo: window.frame.size)
        }
        guard case .movingPanel = dragMode, let window else { return }
        let droppedInZone = closeDropZoneScreen.map { CloseDropZoneOverlay.intersects(window.frame, on: $0) } ?? false
        if droppedInZone || isFrameMostlyOffscreen(window.frame) {
            interactionDelegate?.videoViewDidRequestCloseByDragging(self)
        }
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
        let visibleArea = NSScreen.screens.reduce(CGFloat(0)) { partial, screen in
            let intersection = frame.intersection(screen.frame)
            return partial + intersection.width * intersection.height
        }
        return visibleArea < totalArea * 0.3
    }

    /// The screen the panel currently overlaps the most — used to anchor CloseDropZoneOverlay's
    /// circular target for the duration of a move drag.
    private func mostOverlappingScreen(_ frame: CGRect) -> NSScreen? {
        NSScreen.screens.max { a, b in
            let areaA = frame.intersection(a.frame).width * frame.intersection(a.frame).height
            let areaB = frame.intersection(b.frame).width * frame.intersection(b.frame).height
            return areaA < areaB
        }
    }

    override func keyDown(with event: NSEvent) {
        interactionDelegate?.videoView(self, didReceiveKeyEvent: event)
    }

    override func keyUp(with event: NSEvent) {
        interactionDelegate?.videoView(self, didReceiveKeyEvent: event)
    }
}
