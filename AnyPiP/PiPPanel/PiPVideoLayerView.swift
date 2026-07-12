import AppKit
import AVFoundation
import CoreMedia

@MainActor
protocol PiPVideoLayerViewDelegate: AnyObject {
    func videoView(_ view: PiPVideoLayerView, didClickAt localPoint: CGPoint, button: CGMouseButton)
    func videoView(_ view: PiPVideoLayerView, didDoubleClickAt localPoint: CGPoint)
    func videoView(_ view: PiPVideoLayerView, didScrollAt localPoint: CGPoint, deltaX: Int32, deltaY: Int32)
    func videoView(_ view: PiPVideoLayerView, didReceiveKeyEvent event: NSEvent)
    /// The panel was Option-dragged mostly off every screen, or dropped with its center inside
    /// CloseDropZoneOverlay's circular target in the screen's lower half — both treated as a
    /// "drag to dismiss" gesture (like removing a menu-bar icon), the latter shown live via the
    /// floating target while the drag is in progress.
    func videoViewDidRequestCloseByDragging(_ view: PiPVideoLayerView)
}

/// Hosts an AVSampleBufferDisplayLayer for hardware-accelerated, zero-CPU-copy frame rendering,
/// and captures mouse/keyboard input for InteractionForwarder to replay on the real window.
///
/// A plain click/drag on the video content forwards to the source window (InteractionForwarder)
/// rather than moving/resizing the panel — the panel needs its own dedicated gestures so the two
/// don't collide: Option+drag moves the panel (dropping it onto CloseDropZoneOverlay's circular
/// target, shown in the screen's lower half for the duration of the drag, or dragging it mostly
/// off-screen entirely, both close it — like pulling a menu-bar icon off the bar), and dragging
/// within an edge margin resizes it.
final class PiPVideoLayerView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()
    weak var interactionDelegate: PiPVideoLayerViewDelegate?
    private(set) var nativeSize: CGSize = .zero

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

    /// Forces the real cursor to stay a plain arrow the entire time it's over this view,
    /// regardless of what's under it. Forwarded clicks/scrolls warp the real cursor onto the
    /// source window just long enough to deliver the event — if that point happens to be
    /// hover-sensitive content (a link, a text field), the source app calls NSCursor.set() to
    /// show a hand/I-beam image, exactly like a real hover would. Because the warp is a
    /// teleport rather than continuous motion, the source app never sees the matching
    /// mouseExited/cursorUpdate that would normally make it pop that cursor back off — and since
    /// NSCursor's "current" image is one shared system resource, not scoped per app/window, that
    /// orphaned custom cursor keeps showing (or renders broken/invisible) even once the position
    /// is back under the user's real mouse. Reasserting the arrow on a fast repeating timer for
    /// as long as the mouse is over the panel out-races any of those stray sets.
    private var cursorLockTimer: Timer?
    private var trackingArea: NSTrackingArea?

    /// The screen CloseDropZoneOverlay's circular target was shown on for the current move drag
    /// — fixed for the duration of the drag (chosen from wherever the panel started) rather than
    /// recomputed on every mouseDragged, so the target doesn't jump between screens mid-drag.
    private var closeDropZoneScreen: NSScreen?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        displayLayer.videoGravity = .resizeAspect
        displayLayer.frame = bounds
        displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        cursorLockTimer?.invalidate()
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
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.arrow.set()
        cursorLockTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard self != nil else { return }
            NSCursor.arrow.set()
        }
        RunLoop.main.add(timer, forMode: .common)
        cursorLockTimer = timer
    }

    override func mouseExited(with event: NSEvent) {
        cursorLockTimer?.invalidate()
        cursorLockTimer = nil
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

    /// The actual on-screen rect of the video content inside this view, accounting for
    /// .resizeAspect letterboxing when the panel's aspect ratio doesn't match the source window's.
    func displayedVideoRect(nativeSize: CGSize) -> CGRect {
        guard nativeSize.width > 0, nativeSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        let viewAspect = bounds.width / bounds.height
        let videoAspect = nativeSize.width / nativeSize.height
        if videoAspect > viewAspect {
            let height = bounds.width / videoAspect
            let y = (bounds.height - height) / 2
            return CGRect(x: 0, y: y, width: bounds.width, height: height)
        } else {
            let width = bounds.height * videoAspect
            let x = (bounds.width - width) / 2
            return CGRect(x: x, y: 0, width: width, height: bounds.height)
        }
    }

    // MARK: - Input capture

    /// Lets clicks land immediately (as real mouseDown events) instead of the first click on a
    /// background window being absorbed just to bring it forward — we want click-to-forward to
    /// work without ever visually disturbing the panel or stealing focus.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
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
            return
        }

        dragMode = nil
        if event.clickCount == 2 {
            interactionDelegate?.videoView(self, didDoubleClickAt: point)
        } else {
            interactionDelegate?.videoView(self, didClickAt: point, button: .left)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragMode, let window else { return }
        let current = NSEvent.mouseLocation
        switch dragMode {
        case .movingPanel(let start, let initialOrigin):
            window.setFrameOrigin(NSPoint(x: initialOrigin.x + (current.x - start.x), y: initialOrigin.y + (current.y - start.y)))
            if let screen = closeDropZoneScreen {
                CloseDropZoneOverlay.shared.setHighlighted(CloseDropZoneOverlay.containsCenter(of: window.frame, on: screen))
            }

        case .resizing(let edge, let start, let initialFrame):
            let dx = current.x - start.x
            let dy = current.y - start.y
            let minSize = window.minSize
            var frame = initialFrame
            if edge.contains(.right) {
                frame.size.width = max(initialFrame.width + dx, minSize.width)
            }
            if edge.contains(.left) {
                let newWidth = max(initialFrame.width - dx, minSize.width)
                frame.origin.x = initialFrame.maxX - newWidth
                frame.size.width = newWidth
            }
            if edge.contains(.top) {
                frame.size.height = max(initialFrame.height + dy, minSize.height)
            }
            if edge.contains(.bottom) {
                let newHeight = max(initialFrame.height - dy, minSize.height)
                frame.origin.y = initialFrame.maxY - newHeight
                frame.size.height = newHeight
            }
            window.setFrame(frame, display: true)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragMode = nil
            closeDropZoneScreen = nil
            CloseDropZoneOverlay.shared.hide()
        }
        guard case .movingPanel = dragMode, let window else { return }
        let droppedInZone = closeDropZoneScreen.map { CloseDropZoneOverlay.containsCenter(of: window.frame, on: $0) } ?? false
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

    override func rightMouseDown(with event: NSEvent) {
        interactionDelegate?.videoView(self, didClickAt: convert(event.locationInWindow, from: nil), button: .right)
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // NSEvent scroll deltas are already direction-correct for AppKit; CGScrollWheelEvent
        // wheel1/wheel2 use the same up-positive/left-positive convention.
        interactionDelegate?.videoView(
            self, didScrollAt: point,
            deltaX: Int32(event.scrollingDeltaX.rounded()),
            deltaY: Int32(event.scrollingDeltaY.rounded())
        )
    }

    override func keyDown(with event: NSEvent) {
        interactionDelegate?.videoView(self, didReceiveKeyEvent: event)
    }

    override func keyUp(with event: NSEvent) {
        interactionDelegate?.videoView(self, didReceiveKeyEvent: event)
    }
}
