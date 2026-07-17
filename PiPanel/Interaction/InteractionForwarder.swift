import AppKit
import CoreGraphics

/// Prevents an ordinary physical pointer movement from escaping onto one of PiPanel's invisible
/// displays. InteractionForwarder explicitly registers a short-lived control owner before it
/// warps the cursor there; only those registered control sessions are allowed through.
///
/// NSEvent monitors are event-driven rather than a display-link/polling loop, so the guard has no
/// idle CPU cost. Both global and local monitors are needed: a global monitor sees movement while
/// another app is active, while the local monitor covers PiPanel's own settings/menu surfaces.
@MainActor
final class VirtualDisplayCursorGuard {
    static let shared = VirtualDisplayCursorGuard()

    private static let movementEvents: NSEvent.EventTypeMask = [
        .mouseMoved,
        .leftMouseDragged,
        .rightMouseDragged,
        .otherMouseDragged,
    ]

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var activeControlDisplays: [ObjectIdentifier: CGDirectDisplayID] = [:]
    private var lastPhysicalPoint: CGPoint?
    private var isWarping = false

    func start() {
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.movementEvents) { [weak self] _ in
                Task { @MainActor in
                    self?.handlePointerMovement()
                }
            }
        }
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.movementEvents) { [weak self] event in
                Task { @MainActor in
                    self?.handlePointerMovement()
                }
                return event
            }
        }

        // Seed the recovery point before the first virtual display is created. This makes the
        // first rescue deterministic even if WindowServer's topology notification and the first
        // mouse event arrive in the opposite order.
        recordCurrentPhysicalPoint()
    }

    func beginControl(owner: ObjectIdentifier, displayID: CGDirectDisplayID) {
        // Retry installation here as well as at launch. A first-run user can grant Accessibility
        // after the initial global-monitor request; the first real control session must pick up
        // the newly available permission without requiring another relaunch.
        start()
        recordCurrentPhysicalPoint()
        activeControlDisplays[owner] = displayID
    }

    func endControl(owner: ObjectIdentifier) {
        activeControlDisplays.removeValue(forKey: owner)
    }

    func currentPhysicalCursorPoint() -> CGPoint? {
        guard let point = CGEvent(source: nil)?.location else { return lastPhysicalPoint }
        let frames = physicalDisplayFrames()
        guard frames.contains(where: { $0.contains(point) }) else { return lastPhysicalPoint }
        lastPhysicalPoint = point
        return point
    }

    /// Warps to a known physical point, keeping a small inset from the display boundary so the
    /// very next hardware delta cannot immediately cross the one-point virtual-display seam again.
    @discardableResult
    func returnCursorToPhysical(preferredPoint: CGPoint? = nil) -> Bool {
        let frames = physicalDisplayFrames()
        guard !frames.isEmpty else { return false }
        let current = CGEvent(source: nil)?.location ?? .zero
        guard let target = Self.recoveryPoint(
            preferredPoint: preferredPoint,
            lastPhysicalPoint: lastPhysicalPoint,
            cursorPoint: current,
            physicalFrames: frames
        ) else { return false }

        isWarping = true
        lastPhysicalPoint = target
        CGWarpMouseCursorPosition(target)
        DispatchQueue.main.async { [weak self] in
            self?.isWarping = false
        }
        return true
    }

    /// Pure recovery geometry kept internal for unit tests. Preferred/last-known points win when
    /// they still belong to a physical display; otherwise the nearest physical display is used.
    nonisolated static func recoveryPoint(
        preferredPoint: CGPoint?,
        lastPhysicalPoint: CGPoint?,
        cursorPoint: CGPoint,
        physicalFrames: [CGRect],
        edgeInset: CGFloat = 6
    ) -> CGPoint? {
        guard !physicalFrames.isEmpty else { return nil }

        for candidate in [preferredPoint, lastPhysicalPoint].compactMap({ $0 }) {
            if let frame = physicalFrames.first(where: { $0.contains(candidate) }) {
                return clamp(candidate, inside: frame, inset: edgeInset)
            }
        }

        guard let nearest = physicalFrames.min(by: {
            squaredDistance(from: cursorPoint, to: $0) < squaredDistance(from: cursorPoint, to: $1)
        }) else { return nil }
        return clamp(cursorPoint, inside: nearest, inset: edgeInset)
    }

    private func handlePointerMovement() {
        guard !isWarping, let point = CGEvent(source: nil)?.location else { return }
        let managedFrames = Dictionary(uniqueKeysWithValues: VirtualDisplayHost.activeDisplayIDs.compactMap { displayID -> (CGDirectDisplayID, CGRect)? in
            let frame = CGDisplayBounds(displayID)
            return frame.width > 0 && frame.height > 0 ? (displayID, frame) : nil
        })

        if let enteredDisplayID = managedFrames.first(where: { $0.value.contains(point) })?.key {
            // Whitelist the exact display being controlled, not every PiPanel display. With
            // multiple PiPs, reaching a sibling private display must never redirect real clicks
            // into a different source application.
            guard !activeControlDisplays.values.contains(enteredDisplayID) else { return }
            _ = returnCursorToPhysical()
            return
        }

        if physicalDisplayFrames().contains(where: { $0.contains(point) }) {
            lastPhysicalPoint = point
        }
    }

    private func recordCurrentPhysicalPoint() {
        guard let point = CGEvent(source: nil)?.location,
              physicalDisplayFrames().contains(where: { $0.contains(point) }) else { return }
        lastPhysicalPoint = point
    }

    private func physicalDisplayFrames() -> [CGRect] {
        let managedIDs = VirtualDisplayHost.activeDisplayIDs
        return NSScreen.screens.compactMap { screen -> CGRect? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            guard !managedIDs.contains(displayID) else { return nil }
            let frame = CGDisplayBounds(displayID)
            return frame.width > 0 && frame.height > 0 ? frame : nil
        }
    }

    nonisolated private static func clamp(_ point: CGPoint, inside frame: CGRect, inset: CGFloat) -> CGPoint {
        let safeInsetX = min(inset, max((frame.width - 1) / 2, 0))
        let safeInsetY = min(inset, max((frame.height - 1) / 2, 0))
        return CGPoint(
            x: min(max(point.x, frame.minX + safeInsetX), frame.maxX - safeInsetX),
            y: min(max(point.y, frame.minY + safeInsetY), frame.maxY - safeInsetY)
        )
    }

    nonisolated private static func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(max(rect.minX - point.x, 0), point.x - rect.maxX)
        let dy = max(max(rect.minY - point.y, 0), point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}

/// Controls the source window directly by moving the real cursor onto its (invisible) virtual
/// display, rather than synthesizing discrete click/scroll/drag events one at a time.
///
/// The real cursor entering the panel's content area (not near a resize edge, no Option held —
/// PiPVideoLayerView only calls beginCaptureIfNeeded when neither applies, so this never fights
/// edge-resize or Option-drag-to-move) is taken as "the user wants to interact with the source
/// directly": the cursor is warped onto the virtual display, at the point matching where it just
/// entered, and left there. From that moment on, the user's actual physical clicks/drags/scrolls
/// are genuine hardware events landing directly on the source window — nothing needs synthesizing,
/// and hover/selection/scrolling all behave exactly as they would using the source app normally.
///
/// AppKit stops delivering events to PiPVideoLayerView once the cursor isn't really over it, so a
/// global mouseMoved monitor is what keeps tracking real motion while captured — purely to detect
/// when the pointer has moved past the mirrored window's edge (endCapture(exitingThroughEdge:)
/// then sends it back to the matching point on the real screen) and to keep the panel's own
/// visible cursor indicator (PiPVideoLayerView.updateCapturedCursorIndicator) in sync, since the
/// real system cursor is off-screen (on the virtual display, which isn't rendered anywhere) for as
/// long as capture is active and the mirrored video itself never includes a cursor
/// (CaptureSession's showsCursor is false) — without that indicator there'd be no visual feedback
/// for where the pointer is at all while hovering the panel.
@MainActor
final class InteractionForwarder {
    weak var captureSession: CaptureSession?

    var autoReturnEnabled = false
    var autoReturnIdleInterval: TimeInterval = 1.5
    /// Fires (main actor) every time capture actually ends, however it ends — crossing back out
    /// through the mirrored window's edge, or Option appearing mid-capture. PiPPanelController
    /// uses this to reset PiPVideoLayerView's control-mode gate back to "move mode" (see that
    /// type's own doc comment) each time, rather than hasEnteredControlMode staying permanently
    /// latched after the first double-click for the rest of the session — the first version of
    /// that gate did exactly that, and it meant Option was needed to move the panel forever after
    /// one double-click, since a plain hover always re-captures once hasEnteredControlMode is
    /// true, and hovering unavoidably happens before a plain mouseDown ever could. Resetting here
    /// means the panel goes back to being freely draggable the moment you're done controlling the
    /// source, and only needs another double-click to hand control back to it again.
    var onCaptureEnded: (() -> Void)?

    private var previousFrontmostApp: NSRunningApplication?
    private var idleReturnTimer: Timer?

    private weak var videoView: PiPVideoLayerView?
    private weak var panel: NSPanel?
    private var isCaptured = false
    private var globalMouseMonitor: Any?
    private var globalFlagsMonitor: Any?
    private var captureReturnPoint: CGPoint?
    /// True after a native source-app drag (Finder files, attachments, images, etc.) crosses the
    /// mirrored edge and the real cursor has been handed back to a physical display. The source
    /// app still owns the genuine mouse-down/dragging session; PiPanel must not synthesize an up or
    /// tear down its bookkeeping until the user releases on the physical destination.
    private var isNativeDragHandoffActive = false
    private var nativeDragHandoffTimer: Timer?

    init(captureSession: CaptureSession) {
        self.captureSession = captureSession
    }

    /// Wires up the panel/view this forwarder is attached to — needed only for cursor capture's
    /// coordinate math (translating both into and back out of the virtual display) and the
    /// on-panel cursor indicator, not for keyboard forwarding.
    func attach(videoView: PiPVideoLayerView, panel: NSPanel) {
        self.videoView = videoView
        self.panel = panel
    }

    // MARK: - Cursor capture

    func beginCaptureIfNeeded(atLocalPoint localPoint: CGPoint) {
        guard !isCaptured, !isNativeDragHandoffActive, let captureSession, let videoView,
              let capturedContentFrame = captureSession.currentCapturedContentFrame(),
              let controlDisplayID = captureSession.virtualDisplayHost?.displayID else { return }
        let displayedRect = videoView.displayedVideoRect(nativeSize: videoView.nativeSize)
        guard let virtualPoint = CoordinateTranslator.globalPoint(
            forLocalPoint: localPoint,
            viewBounds: videoView.bounds,
            nativeSize: videoView.nativeSize,
            displayedVideoRect: displayedRect,
            windowGlobalFrame: capturedContentFrame
        ), captureSession.canForwardInteraction(at: virtualPoint) else { return }

        let owner = ObjectIdentifier(self)
        captureReturnPoint = VirtualDisplayCursorGuard.shared.currentPhysicalCursorPoint()
        VirtualDisplayCursorGuard.shared.beginControl(owner: owner, displayID: controlDisplayID)
        isCaptured = true
        CGWarpMouseCursorPosition(virtualPoint)
        videoView.setControlModeActive(true)
        videoView.showCapturedCursorIndicator(atLocalPoint: localPoint)
        Task { [weak self] in
            await self?.activateSourceAppIfNeeded()
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            Task { @MainActor in
                self?.handleGlobalMouseEvent(event)
            }
        }
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            // Option appearing mid-capture means the user wants to Option-drag the panel itself —
            // release capture immediately so a subsequent mouseDown can reach the view again,
            // rather than it landing on the source window instead.
            if event.modifierFlags.contains(.option) {
                self?.endCaptureReturningToEntryPoint()
            }
        }
    }

    private func handleGlobalMouseEvent(_ event: NSEvent) {
        if isNativeDragHandoffActive {
            if event.type == .leftMouseUp {
                finishNativeDragHandoff()
            }
            return
        }
        handleCapturedMouseMoved()
    }

    /// Fires on every real mouse movement while captured (a global monitor, since AppKit no
    /// longer considers the real cursor to be over PiPVideoLayerView once it's been warped onto
    /// the virtual display). Translates the cursor's current real position back into the panel's
    /// local coordinates — both to update the visible indicator, and, if that position has moved
    /// past the mirrored window's edge, to hand control back to the real screen.
    private func handleCapturedMouseMoved() {
        guard isCaptured, let capturedContentFrame = captureSession?.currentCapturedContentFrame(),
              capturedContentFrame.width > 0, capturedContentFrame.height > 0,
              let current = CGEvent(source: nil)?.location else { return }

        let fracX = (current.x - capturedContentFrame.minX) / capturedContentFrame.width
        let fracYFromTop = (current.y - capturedContentFrame.minY) / capturedContentFrame.height

        guard fracX < 0 || fracX > 1 || fracYFromTop < 0 || fracYFromTop > 1 else {
            updateCapturedCursorIndicator(fracX: fracX, fracYFromTop: fracYFromTop, clamped: false)
            return
        }
        endCapture(exitFracX: fracX, exitFracYFromTop: fracYFromTop)
    }

    private func updateCapturedCursorIndicator(fracX: CGFloat, fracYFromTop: CGFloat, clamped: Bool) {
        guard let videoView else { return }
        let displayedRect = videoView.displayedVideoRect(nativeSize: videoView.nativeSize)
        guard displayedRect.width > 0, displayedRect.height > 0 else { return }
        let x = displayedRect.minX + fracX * displayedRect.width
        let y = displayedRect.minY + (1 - fracYFromTop) * displayedRect.height
        videoView.updateCapturedCursorIndicator(atLocalPoint: CGPoint(x: x, y: y))
    }

    /// Option means "give the panel back to me." Return to the exact physical point from which
    /// control began instead of leaving the real cursor stranded on the now-unmonitored virtual
    /// display (the previous behavior and a direct cause of the cursor-disappeared symptom).
    private func endCaptureReturningToEntryPoint() {
        completeCapture(returningTo: captureReturnPoint)
    }

    /// Maps the fractional position where the pointer crossed the mirrored window's edge back to
    /// the corresponding point just outside the panel's matching edge on the real screen — the
    /// inverse of CoordinateTranslator.globalPoint — so leaving the PiP through, say, its left
    /// edge continues seamlessly onto the real desktop to the left of the panel, at the same
    /// relative height, rather than reappearing somewhere arbitrary like the screen's center.
    private func endCapture(exitFracX: CGFloat, exitFracYFromTop: CGFloat) {
        guard let videoView, let panel else {
            completeCapture(returningTo: captureReturnPoint)
            return
        }
        let displayedRect = videoView.displayedVideoRect(nativeSize: videoView.nativeSize)
        guard displayedRect.width > 0, displayedRect.height > 0 else {
            completeCapture(returningTo: captureReturnPoint)
            return
        }

        let nudge: CGFloat = 6
        let localPoint: CGPoint
        if exitFracX < 0 || exitFracX > 1 {
            let clampedFracYFromTop = min(max(exitFracYFromTop, 0), 1)
            let y = displayedRect.minY + (1 - clampedFracYFromTop) * displayedRect.height
            let x = exitFracX < 0 ? displayedRect.minX - nudge : displayedRect.maxX + nudge
            localPoint = CGPoint(x: x, y: y)
        } else {
            let clampedFracX = min(max(exitFracX, 0), 1)
            let x = displayedRect.minX + clampedFracX * displayedRect.width
            let y = exitFracYFromTop < 0 ? displayedRect.maxY + nudge : displayedRect.minY - nudge
            localPoint = CGPoint(x: x, y: y)
        }

        let windowPoint = videoView.convert(localPoint, to: nil)
        let screenPoint = panel.convertPoint(toScreen: windowPoint)
        // AppKit screen space (bottom-left origin) -> Quartz space (top-left origin), the same
        // conversion used elsewhere (WindowFlingDetector) for CGWarpMouseCursorPosition.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let quartzPoint = CGPoint(x: screenPoint.x, y: primaryHeight - screenPoint.y)
        if CGEventSource.buttonState(.combinedSessionState, button: .left) {
            beginNativeDragHandoff(returningTo: quartzPoint)
        } else {
            completeCapture(returningTo: quartzPoint)
        }
        NSCursor.arrow.set()
    }

    /// Keeps Finder/AppKit's real dragging session alive while moving its cursor representation
    /// from the private display to the physical desktop. CGWarpMouseCursorPosition does not post a
    /// mouse event, so the original down remains held and the next hardware delta continues the
    /// same native drag over any physical-screen destination.
    private func beginNativeDragHandoff(returningTo point: CGPoint) {
        guard isCaptured else { return }
        isCaptured = false
        isNativeDragHandoffActive = true
        videoView?.setControlModeActive(false)
        videoView?.hideCapturedCursorIndicator()

        _ = VirtualDisplayCursorGuard.shared.returnCursorToPhysical(preferredPoint: point)
        VirtualDisplayCursorGuard.shared.endControl(owner: ObjectIdentifier(self))
        captureReturnPoint = nil

        // Flags are only relevant while controlling the source. Keep the mouse monitor for the
        // physical mouse-up, plus a common-mode timer as a fallback when an AppKit destination's
        // modal dragging loop prevents the global monitor from observing that final event.
        if let globalFlagsMonitor { NSEvent.removeMonitor(globalFlagsMonitor) }
        globalFlagsMonitor = nil
        nativeDragHandoffTimer?.invalidate()
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard !CGEventSource.buttonState(.combinedSessionState, button: .left) else { return }
                self?.finishNativeDragHandoff()
            }
        }
        nativeDragHandoffTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func finishNativeDragHandoff() {
        guard isNativeDragHandoffActive else { return }
        isNativeDragHandoffActive = false
        nativeDragHandoffTimer?.invalidate()
        nativeDragHandoffTimer = nil
        removeCaptureMonitors()
        onCaptureEnded?()
    }

    /// Called before a panel/session disappears. It is intentionally idempotent so normal close,
    /// failed startup and application termination can all use the same cleanup path.
    func stop() {
        if isCaptured {
            completeCapture(returningTo: captureReturnPoint)
        } else if isNativeDragHandoffActive {
            finishNativeDragHandoff()
        } else {
            removeCaptureMonitors()
            videoView?.setControlModeActive(false)
            VirtualDisplayCursorGuard.shared.endControl(owner: ObjectIdentifier(self))
        }
        cancelPendingAutoReturn()
    }

    private func completeCapture(returningTo point: CGPoint?) {
        guard isCaptured else {
            VirtualDisplayCursorGuard.shared.endControl(owner: ObjectIdentifier(self))
            return
        }
        isCaptured = false
        removeCaptureMonitors()
        videoView?.setControlModeActive(false)
        videoView?.hideCapturedCursorIndicator()

        // Keep the owner allow-listed until after the physical warp; otherwise the guard may see
        // the synthetic movement while the cursor is still on the virtual display and race it.
        _ = VirtualDisplayCursorGuard.shared.returnCursorToPhysical(preferredPoint: point)
        VirtualDisplayCursorGuard.shared.endControl(owner: ObjectIdentifier(self))
        captureReturnPoint = nil
        onCaptureEnded?()
    }

    private func removeCaptureMonitors() {
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let globalFlagsMonitor { NSEvent.removeMonitor(globalFlagsMonitor) }
        globalMouseMonitor = nil
        globalFlagsMonitor = nil
        nativeDragHandoffTimer?.invalidate()
        nativeDragHandoffTimer = nil
    }

    /// Activates the source app if it isn't already frontmost — done as soon as capture begins
    /// (rather than waiting for an actual click) since, once captured, the user's next click is a
    /// genuine hardware event we can't intercept ahead of time to activate just-in-time the way a
    /// synthetic one could; this gives the activation a head start so it's settled by the time a
    /// real click actually lands.
    private func activateSourceAppIfNeeded() async {
        guard let captureSession, let sourceApp = NSRunningApplication(processIdentifier: captureSession.windowInfo.ownerPID) else { return }
        if previousFrontmostApp == nil {
            previousFrontmostApp = NSWorkspace.shared.frontmostApplication
        }
        guard !sourceApp.isActive else { return }
        // PiPSessionManager should not treat this as the user switching to the app (M3's
        // hide-panel/move-window transition is for real switches, e.g. Cmd+Tab).
        captureSession.suppressNextActivationTransition = true
        sourceApp.activate()
    }

    // MARK: - Keyboard

    func forwardKeyEvent(_ event: NSEvent) {
        Task { [weak self] in
            await self?.activateSourceAppIfNeeded()
            KeyboardEventForwarder.post(event)
        }
        if autoReturnEnabled {
            scheduleAutoReturn()
        }
    }

    private func scheduleAutoReturn() {
        idleReturnTimer?.invalidate()
        idleReturnTimer = Timer.scheduledTimer(withTimeInterval: autoReturnIdleInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.returnFocusToPreviousApp()
            }
        }
    }

    private func returnFocusToPreviousApp() {
        previousFrontmostApp?.activate()
        previousFrontmostApp = nil
        idleReturnTimer = nil
    }

    func cancelPendingAutoReturn() {
        idleReturnTimer?.invalidate()
        idleReturnTimer = nil
        previousFrontmostApp = nil
    }
}
