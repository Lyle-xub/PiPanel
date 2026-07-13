import AppKit
import CoreMedia
import Combine

@MainActor
final class PiPSessionManager: NSObject, ObservableObject {
    static let shared = PiPSessionManager()

    @Published private(set) var sessions: [PiPSession] = []

    private var sessionsByCaptureSession: [ObjectIdentifier: PiPSession] = [:]
    private let flingDetector = WindowFlingDetector()

    override init() {
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeApplicationDidChange(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        flingDetector.onFling = { [weak self] windowInfo in
            self?.startSession(for: windowInfo)
        }
        flingDetector.start()
    }

    /// M3: whenever the frontmost app changes, pull any matching session's window onto the
    /// physical screen (and hide its panel) if its source app just became frontmost, or send it
    /// back to the virtual display (and re-show the panel) if the user just switched away from
    /// a session that was in that state.
    @objc private func activeApplicationDidChange(_ notification: Notification) {
        guard let activatedApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        for session in sessions {
            let captureSession = session.captureSession
            if activatedApp.processIdentifier == session.windowInfo.ownerPID {
                guard captureSession.presentationState == .pip else { continue }
                if captureSession.suppressNextActivationTransition {
                    // Just a forwarded click/keystroke needing the app briefly frontmost to
                    // deliver — leave the window on the virtual display and the panel visible.
                    captureSession.suppressNextActivationTransition = false
                    continue
                }
                captureSession.enterSourceActiveState()
                if SettingsStore.shared.autoHideWhenSourceActive {
                    session.panelController.setLive(false)
                }
            } else if captureSession.presentationState == .sourceActive {
                Task {
                    await captureSession.enterPiPState()
                    session.panelController.setLive(true)
                }
            }
        }
    }

    func startSession(for windowInfo: WindowInfo) {
        debugTrace("startSession(for:) called for \(windowInfo.ownerAppName)/\(windowInfo.title)")
        if sessions.contains(where: { $0.windowInfo.id == windowInfo.id }) {
            PiPanelLogger.app.info("Session already active for window \(windowInfo.id)")
            return
        }

        let panelFrame = defaultPanelFrame(for: windowInfo)
        debugTrace("creating PiPPanelController with frame \(panelFrame)")
        let panelController = PiPPanelController(initialFrame: panelFrame, nativeSize: windowInfo.frame.size)
        panelController.delegate = self
        debugTrace("panel created and ordered front")

        let captureSession = CaptureSession(windowInfo: windowInfo)
        captureSession.delegate = self
        captureSession.targetFPS = SettingsStore.shared.targetFPS

        let interactionForwarder = InteractionForwarder(captureSession: captureSession)
        interactionForwarder.autoReturnEnabled = SettingsStore.shared.autoReturnEnabled
        interactionForwarder.autoReturnIdleInterval = SettingsStore.shared.autoReturnIdleInterval
        panelController.interactionForwarder = interactionForwarder

        let session = PiPSession(windowInfo: windowInfo, captureSession: captureSession, panelController: panelController)
        sessions.append(session)
        sessionsByCaptureSession[ObjectIdentifier(captureSession)] = session

        Task {
            debugTrace("calling captureSession.start()")
            do {
                try await captureSession.start()
                debugTrace("captureSession.start() returned successfully")
            } catch {
                debugTrace("Failed to start capture: \(error)")
                self.stopSession(session)
            }
        }
    }

    func stopSession(_ session: PiPSession) {
        guard sessions.contains(where: { $0.id == session.id }) else { return }
        sessions.removeAll { $0.id == session.id }
        sessionsByCaptureSession.removeValue(forKey: ObjectIdentifier(session.captureSession))
        session.panelController.close()
        Task {
            await session.captureSession.stop()
        }
    }

    func stopAll() {
        for session in sessions { stopSession(session) }
    }

    /// Anchors to SettingsStore.shared.defaultStackingCorner (default top-right, matching this
    /// method's original hardcoded-always-top-right behavior byte-for-byte) and stacks additional
    /// panels away from that corner — each new one goes directly adjacent to the outermost
    /// currently-open panel, rather than the old tiny diagonal-cascade offset, which left multiple
    /// sessions' panels almost fully overlapping (M4: multi-session). Top corners stack downward
    /// (using the lowest existing panel's bottom edge); bottom corners are the mirror image and
    /// stack upward (using the highest existing panel's top edge).
    private func defaultPanelFrame(for windowInfo: WindowInfo) -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(x: 100, y: 100, width: 320, height: 200)
        }
        let aspect = windowInfo.frame.width / max(windowInfo.frame.height, 1)
        let width = CGFloat(SettingsStore.shared.defaultPanelWidth)
        let height = max(width / max(aspect, 0.1), 120)
        let margin: CGFloat = 24
        let gap: CGFloat = 12
        let corner = SettingsStore.shared.defaultStackingCorner
        let visible = screen.visibleFrame

        let x = corner.isLeading
            ? visible.minX + margin
            : visible.maxX - width - margin

        let y: CGFloat
        if corner.isTop {
            let lowestExistingBottom = sessions
                .map { $0.panelController.panel.frame.minY }
                .min() ?? (visible.maxY + gap)
            y = lowestExistingBottom - gap - height
        } else {
            let highestExistingTop = sessions
                .map { $0.panelController.panel.frame.maxY }
                .max() ?? (visible.minY - gap)
            y = highestExistingTop + gap
        }

        return NSRect(x: x, y: y, width: width, height: height)
    }
}

extension PiPSessionManager: PiPPanelControllerDelegate {
    func pipPanelControllerDidRequestClose(_ controller: PiPPanelController) {
        guard let session = sessions.first(where: { $0.panelController === controller }) else { return }
        stopSession(session)
    }
}

extension PiPSessionManager: CaptureSessionDelegate {
    nonisolated func captureSession(_ session: CaptureSession, didOutput sampleBuffer: CMSampleBuffer) {
        Task { @MainActor in
            guard let pipSession = self.sessionsByCaptureSession[ObjectIdentifier(session)] else { return }
            let nativeSize = session.framedRect.size
            pipSession.panelController.enqueue(sampleBuffer, nativeSize: nativeSize.width > 0 ? nativeSize : session.windowInfo.frame.size)
        }
    }

    nonisolated func captureSessionDidStop(_ session: CaptureSession, error: Error?) {
        Task { @MainActor in
            guard let pipSession = self.sessionsByCaptureSession[ObjectIdentifier(session)] else { return }
            PiPanelLogger.app.info("Source window disappeared, closing PiP panel")
            self.stopSession(pipSession)
        }
    }
}
