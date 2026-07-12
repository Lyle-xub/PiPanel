import AppKit
import CoreGraphics

/// Forwards mouse/keyboard input from a PiP panel's video view onto the real source window
/// sitting on its (invisible) virtual display.
///
/// Mouse clicks are coordinate-targeted (MouseEventForwarder posts at the translated screen
/// point), but — verified empirically — a synthetic click delivered to an app that isn't yet
/// frontmost gets "eaten" activating the app rather than performing the click's action (e.g.
/// placing a text caret): this is standard AppKit click-to-activate behavior for any normal
/// window, not something specific to our synthetic events, and it happens whether or not we
/// call activate() ourselves. So forwardClick activates the source app first when needed, the
/// same as keyboard input — the difference from keyboard is only that once the app is already
/// active, repeat clicks skip straight to posting the event. Because the source window lives on
/// an invisible virtual display, none of this produces a visible Space-switch or otherwise
/// disturbs what the user is actually looking at; only the menu bar/frontmost-app identity
/// changes. autoReturnEnabled hands focus back to whatever was frontmost before, after a short
/// idle period with no further forwarded input.
@MainActor
final class InteractionForwarder {
    weak var captureSession: CaptureSession?

    var autoReturnEnabled = false
    var autoReturnIdleInterval: TimeInterval = 1.5

    private var previousFrontmostApp: NSRunningApplication?
    private var idleReturnTimer: Timer?

    init(captureSession: CaptureSession) {
        self.captureSession = captureSession
    }

    // MARK: - Mouse

    func forwardClick(
        atLocalPoint localPoint: CGPoint,
        viewBounds: CGRect,
        nativeSize: CGSize,
        displayedVideoRect: CGRect,
        button: CGMouseButton = .left
    ) {
        guard let globalPoint = translatedGlobalPoint(
            localPoint: localPoint, viewBounds: viewBounds, nativeSize: nativeSize, displayedVideoRect: displayedVideoRect
        ) else { return }
        Task {
            await activateSourceAppIfNeeded()
            MouseEventForwarder.click(at: globalPoint, button: button)
        }
        if autoReturnEnabled {
            scheduleAutoReturn()
        }
    }

    func forwardScroll(
        atLocalPoint localPoint: CGPoint,
        viewBounds: CGRect,
        nativeSize: CGSize,
        displayedVideoRect: CGRect,
        deltaY: Int32,
        deltaX: Int32 = 0
    ) {
        guard let globalPoint = translatedGlobalPoint(
            localPoint: localPoint, viewBounds: viewBounds, nativeSize: nativeSize, displayedVideoRect: displayedVideoRect
        ) else { return }
        Task {
            await activateSourceAppIfNeeded()
            MouseEventForwarder.scroll(at: globalPoint, deltaY: deltaY, deltaX: deltaX)
        }
        if autoReturnEnabled {
            scheduleAutoReturn()
        }
    }

    /// Activates the source app if it isn't already frontmost, and gives the window server a
    /// moment to settle — a synthetic click/keystroke delivered in the same beat as activate()
    /// was observed to get consumed just bringing the app forward rather than performing the
    /// click/keystroke's actual action.
    private func activateSourceAppIfNeeded() async {
        guard let captureSession, let sourceApp = NSRunningApplication(processIdentifier: captureSession.windowInfo.ownerPID) else { return }
        if previousFrontmostApp == nil {
            previousFrontmostApp = NSWorkspace.shared.frontmostApplication
        }
        guard !sourceApp.isActive else { return }
        // This activation is only to get the click/keystroke delivered — PiPSessionManager
        // should not treat it as the user switching to the app (M3's hide-panel/move-window
        // transition is for real switches, e.g. Cmd+Tab or "jump to source").
        captureSession.suppressNextActivationTransition = true
        sourceApp.activate()
        try? await Task.sleep(nanoseconds: 80_000_000)
    }

    private func translatedGlobalPoint(
        localPoint: CGPoint, viewBounds: CGRect, nativeSize: CGSize, displayedVideoRect: CGRect
    ) -> CGPoint? {
        guard let windowFrame = captureSession?.currentSourceWindowFrame() else { return nil }
        return CoordinateTranslator.globalPoint(
            forLocalPoint: localPoint,
            viewBounds: viewBounds,
            nativeSize: nativeSize,
            displayedVideoRect: displayedVideoRect,
            windowGlobalFrame: windowFrame
        )
    }

    // MARK: - Keyboard

    func forwardKeyEvent(_ event: NSEvent) {
        Task {
            await activateSourceAppIfNeeded()
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
