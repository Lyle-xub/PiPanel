import AppKit
import CoreGraphics

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
        guard !isCaptured, let captureSession, let videoView,
              let capturedContentFrame = captureSession.currentCapturedContentFrame() else { return }
        let displayedRect = videoView.displayedVideoRect(nativeSize: videoView.nativeSize)
        guard let virtualPoint = CoordinateTranslator.globalPoint(
            forLocalPoint: localPoint,
            viewBounds: videoView.bounds,
            nativeSize: videoView.nativeSize,
            displayedVideoRect: displayedRect,
            windowGlobalFrame: capturedContentFrame
        ), captureSession.canForwardInteraction(at: virtualPoint) else { return }

        isCaptured = true
        CGWarpMouseCursorPosition(virtualPoint)
        videoView.showCapturedCursorIndicator(atLocalPoint: localPoint)
        Task { [weak self] in
            await self?.activateSourceAppIfNeeded()
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.handleCapturedMouseMoved()
        }
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            // Option appearing mid-capture means the user wants to Option-drag the panel itself —
            // release capture immediately so a subsequent mouseDown can reach the view again,
            // rather than it landing on the source window instead.
            if event.modifierFlags.contains(.option) {
                self?.endCaptureInPlace()
            }
        }
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

    /// Releases capture without a known exit point (Option appearing mid-hover) — the real
    /// cursor is left wherever it currently sits on the virtual display; there's no meaningful
    /// "return to the real screen" position to compute since this isn't an edge exit, and the
    /// point is just to stop treating further input as captured so mouseDown can reach the panel.
    private func endCaptureInPlace() {
        guard isCaptured else { return }
        isCaptured = false
        removeCaptureMonitors()
        videoView?.hideCapturedCursorIndicator()
        onCaptureEnded?()
    }

    /// Maps the fractional position where the pointer crossed the mirrored window's edge back to
    /// the corresponding point just outside the panel's matching edge on the real screen — the
    /// inverse of CoordinateTranslator.globalPoint — so leaving the PiP through, say, its left
    /// edge continues seamlessly onto the real desktop to the left of the panel, at the same
    /// relative height, rather than reappearing somewhere arbitrary like the screen's center.
    private func endCapture(exitFracX: CGFloat, exitFracYFromTop: CGFloat) {
        isCaptured = false
        removeCaptureMonitors()
        onCaptureEnded?()

        guard let videoView, let panel else { return }
        videoView.hideCapturedCursorIndicator()
        let displayedRect = videoView.displayedVideoRect(nativeSize: videoView.nativeSize)
        guard displayedRect.width > 0, displayedRect.height > 0 else { return }

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
        // conversion used elsewhere for CGWarpMouseCursorPosition.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let quartzPoint = CGPoint(x: screenPoint.x, y: primaryHeight - screenPoint.y)
        CGWarpMouseCursorPosition(quartzPoint)
        NSCursor.arrow.set()
    }

    private func removeCaptureMonitors() {
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let globalFlagsMonitor { NSEvent.removeMonitor(globalFlagsMonitor) }
        globalMouseMonitor = nil
        globalFlagsMonitor = nil
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
