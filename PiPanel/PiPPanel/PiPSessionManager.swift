import AppKit
import Combine

/// Captures where a newly-created panel belongs relative to its physical screen's visible area.
/// WindowServer may change that screen's global origin while a private display is registered;
/// keeping edge insets (rather than a global frame) lets the same user-selected corner/stack slot
/// be reconstructed after the topology settles without consulting other panels that may also have
/// been temporarily displaced.
struct PanelPlacementAnchor {
    let size: CGSize
    let horizontalInset: CGFloat
    let verticalInset: CGFloat
    let corner: PanelCorner

    init(frame: CGRect, visibleFrame: CGRect, corner: PanelCorner) {
        size = frame.size
        self.corner = corner
        horizontalInset = corner.isLeading
            ? frame.minX - visibleFrame.minX
            : visibleFrame.maxX - frame.maxX
        verticalInset = corner.isTop
            ? visibleFrame.maxY - frame.maxY
            : frame.minY - visibleFrame.minY
    }

    func frame(in visibleFrame: CGRect) -> CGRect {
        let x = corner.isLeading
            ? visibleFrame.minX + horizontalInset
            : visibleFrame.maxX - horizontalInset - size.width
        let y = corner.isTop
            ? visibleFrame.maxY - verticalInset - size.height
            : visibleFrame.minY + verticalInset
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}

/// Pure geometry used by the runtime intrusion guard and its unit tests. A window counts as being
/// on a managed display when its center is there or at least half of its area overlaps one; this
/// ignores harmless shadows/slivers crossing a display edge while still catching topology reflows
/// that strand most of a real application window inside a hidden PiPanel display.
enum VirtualDisplayIntrusionPolicy {
    static func occupiesManagedDisplay(_ frame: CGRect, managedFrames: [CGRect]) -> Bool {
        guard frame.width > 0, frame.height > 0 else { return false }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if managedFrames.contains(where: { $0.contains(center) }) { return true }
        let area = frame.width * frame.height
        return managedFrames.contains { managed in
            let intersection = frame.intersection(managed)
            return !intersection.isNull && intersection.width * intersection.height >= area * 0.5
        }
    }

    static func recoveryFrame(
        for currentFrame: CGRect,
        lastSafeFrame: CGRect?,
        physicalFrames: [CGRect]
    ) -> CGRect? {
        guard !physicalFrames.isEmpty else { return nil }
        if let lastSafeFrame,
           physicalFrames.contains(where: { $0.contains(CGPoint(x: lastSafeFrame.midX, y: lastSafeFrame.midY)) }) {
            return lastSafeFrame
        }

        let center = CGPoint(x: currentFrame.midX, y: currentFrame.midY)
        guard let destination = physicalFrames.min(by: {
            squaredDistance(from: center, to: $0) < squaredDistance(from: center, to: $1)
        }) else { return nil }

        // Preserve the application's window size. Only clamp its top-left origin far enough into
        // the physical display that the title bar and a useful portion of the window are visible.
        let horizontalMargin: CGFloat = 24
        let topMargin: CGFloat = 44
        let bottomMargin: CGFloat = 24
        let minX = destination.minX + horizontalMargin
        let maxX = max(minX, destination.maxX - currentFrame.width - horizontalMargin)
        let minY = destination.minY + topMargin
        let maxY = max(minY, destination.maxY - currentFrame.height - bottomMargin)
        return CGRect(
            x: min(max(currentFrame.minX, minX), maxX),
            y: min(max(currentFrame.minY, minY), maxY),
            width: currentFrame.width,
            height: currentFrame.height
        )
    }

    private static func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(max(rect.minX - point.x, 0), point.x - rect.maxX)
        let dy = max(max(rect.minY - point.y, 0), point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}

private struct GuardedWindowSnapshot {
    let id: CGWindowID
    let ownerPID: pid_t
    let title: String?
    let frame: CGRect
}

private enum SourceWindowMatcher {
    static func titlesLikelyMatch(_ lhs: String, _ rhs: String) -> Bool {
        let lhs = lhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rhs = rhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        if lhs == rhs { return true }
        let shorter = lhs.count <= rhs.count ? lhs : rhs
        let longer = lhs.count <= rhs.count ? rhs : lhs
        return shorter.count >= 3 && longer.contains(shorter)
    }

    static func distance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.origin.x - rhs.origin.x)
            + abs(lhs.origin.y - rhs.origin.y)
            + abs(lhs.width - rhs.width)
            + abs(lhs.height - rhs.height)
    }
}

@MainActor
final class PiPSessionManager: NSObject, ObservableObject {
    static let shared = PiPSessionManager()

    @Published private(set) var sessions: [PiPSession] = []
    private var sessionsByCaptureSession: [ObjectIdentifier: PiPSession] = [:]
    /// Keep a closing session registered until its source has actually returned to a physical
    /// display. Otherwise the intrusion guard can mistake that still-restoring source for an
    /// unrelated window and move it to a generic recovery frame.
    private var stoppingSessionIDs: Set<PiPSession.ID> = []
    /// Gives application termination a structured handle to the same asynchronous cleanup used by
    /// ordinary close actions. Without retaining these tasks, AppDelegate could only request
    /// stopAll() and guess when every source window had actually returned from its virtual display.
    private var stoppingTasks: [PiPSession.ID: Task<Void, Never>] = [:]
    /// Set before application termination starts. Pending pool warm-up callbacks and user gestures
    /// must not create a fresh PiP after the shutdown snapshot has already been collected.
    private var isPreparingForTermination = false
    /// WindowServer may assign a fresh SCWindowID while a session is starting, so the ID-only
    /// duplicate check is insufficient during that gap.
    private var startingSourcePIDs: Set<pid_t> = []
    private let cornerPiPController = WindowCornerPiPController()
    private var settingsCancellables: Set<AnyCancellable> = []
    private var virtualDisplayIntrusionGuardTask: Task<Void, Never>?
    private var lastSafeWindowFrames: [CGWindowID: CGRect] = [:]

    override init() {
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeApplicationDidChange(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        cornerPiPController.onRequestPiP = { [weak self] windowInfo in
            self?.startSession(for: windowInfo)
        }
        cornerPiPController.start()
        observeLiveSettings()
        startVirtualDisplayIntrusionGuard()
    }

    /// PiPanel keeps idle private displays registered for the whole app lifetime. WindowServer can
    /// occasionally carry an unrelated application window along during a topology reflow, leaving
    /// it inaccessible on one of those hidden desktops. Poll cheaply through CGWindowList, then
    /// pay the AX lookup cost only for a window that actually occupies a managed display.
    private func startVirtualDisplayIntrusionGuard() {
        virtualDisplayIntrusionGuardTask?.cancel()
        virtualDisplayIntrusionGuardTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 750_000_000)
                guard !Task.isCancelled else { return }
                self?.recoverIntrudingWindowsIfNeeded()
            }
        }
    }

    private func recoverIntrudingWindowsIfNeeded() {
        let managedFrames = VirtualDisplayHost.activeDisplayIDs.compactMap { displayID -> CGRect? in
            let frame = CGDisplayBounds(displayID)
            return frame.width > 0 && frame.height > 0 ? frame : nil
        }
        guard !managedFrames.isEmpty else { return }

        let physicalFrames = realScreens().compactMap { screen -> CGRect? in
            guard let displayID = Self.displayID(for: screen) else { return nil }
            let frame = CGDisplayBounds(displayID)
            return frame.width > 0 && frame.height > 0 ? frame : nil
        }
        guard !physicalFrames.isEmpty else { return }

        let snapshots = Self.guardWindowSnapshots()
        let liveWindowIDs = Set(snapshots.map(\.id))
        lastSafeWindowFrames = lastSafeWindowFrames.filter { liveWindowIDs.contains($0.key) }
        let ownPID = ProcessInfo.processInfo.processIdentifier

        for snapshot in snapshots where snapshot.ownerPID != ownPID {
            guard NSRunningApplication(processIdentifier: snapshot.ownerPID)?.activationPolicy == .regular else {
                continue
            }

            if !VirtualDisplayIntrusionPolicy.occupiesManagedDisplay(
                snapshot.frame,
                managedFrames: managedFrames
            ) {
                if physicalFrames.contains(where: {
                    $0.contains(CGPoint(x: snapshot.frame.midX, y: snapshot.frame.midY))
                }) {
                    lastSafeWindowFrames[snapshot.id] = snapshot.frame
                }
                continue
            }

            guard let axWindow = AXWindowLocator.locate(
                ownerPID: snapshot.ownerPID,
                approximateFrame: snapshot.frame,
                title: snapshot.title
            ), !AXWindowLocator.isMinimized(axWindow) else { continue }

            // The one source window owned by each active CaptureSession is intentionally on a
            // virtual display. Everything else — including another window from the same PID — is
            // an intrusion and must be returned to a physical screen.
            if sessions.contains(where: { $0.captureSession.ownsSourceWindow(axWindow) }) {
                continue
            }

            // Native fullscreen commonly creates a second WindowServer/AX window for the same
            // application rather than reusing the original source element. It fills the private
            // display in raw backing pixels (for example 2560×1600 on a 1280×800 2× host), so an
            // identity-only check mistakes it for an unrelated intrusion and drags it away. A
            // fullscreen window from the active source PID is the session's intended companion.
            if sessions.contains(where: {
                $0.windowInfo.ownerPID == snapshot.ownerPID
                    && (AXWindowLocator.isFullScreen(axWindow)
                        || $0.captureSession.sourceIsNativeFullScreen())
            }) {
                continue
            }

            guard let targetFrame = VirtualDisplayIntrusionPolicy.recoveryFrame(
                for: snapshot.frame,
                lastSafeFrame: lastSafeWindowFrames[snapshot.id],
                physicalFrames: physicalFrames
            ) else { continue }

            AXWindowLocator.setFrame(targetFrame, on: axWindow)
            lastSafeWindowFrames[snapshot.id] = targetFrame
            debugTrace(
                "vdisplay guard: recovered unrelated windowID=\(snapshot.id) pid=\(snapshot.ownerPID) "
                + "from=\(snapshot.frame) to=\(targetFrame)"
            )
        }
    }

    private static func guardWindowSnapshots() -> [GuardedWindowSnapshot] {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        return windowInfo.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? NSNumber, layer.intValue == 0,
                  let id = info[kCGWindowNumber as String] as? NSNumber,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.width > 60, frame.height > 60 else { return nil }
            return GuardedWindowSnapshot(
                id: CGWindowID(id.uint32Value),
                ownerPID: pid_t(ownerPID.int32Value),
                title: info[kCGWindowName as String] as? String,
                frame: frame
            )
        }
    }

    /// Most settings here are only ever read once, at startSession's own call site. Frame rate,
    /// virtualDisplayLongEdge ("虚拟显示器分辨率") and captureOutputLongEdge ("画面清晰度") are the
    /// exceptions: they apply live to sessions that are already open, the same way
    /// BetterDisplay's own resolution tool does against a virtual display it's already streaming.
    /// CaptureSession's own didSet on each property does the actual live-apply work (a coalesced
    /// resize for the former, an immediate SCStreamConfiguration update for the latter) — this just
    /// has to re-set that property on every currently-open session whenever the setting changes,
    /// since nothing else in the app currently pushes a SettingsStore change into an
    /// already-running CaptureSession instance.
    private func observeLiveSettings() {
        SettingsStore.shared.$targetFPS
            .dropFirst()
            .sink { [weak self] newValue in
                for session in self?.sessions ?? [] {
                    session.captureSession.targetFPS = newValue
                }
            }
            .store(in: &settingsCancellables)
        SettingsStore.shared.$virtualDisplayLongEdge
            .dropFirst()
            .sink { [weak self] newValue in
                for session in self?.sessions ?? [] {
                    session.captureSession.virtualDisplayLongEdge = newValue
                }
                VirtualDisplayPool.shared.scheduleAvailableDisplayResize(longEdge: CGFloat(newValue))
            }
            .store(in: &settingsCancellables)
        SettingsStore.shared.$captureOutputLongEdge
            .dropFirst()
            .sink { [weak self] newValue in
                for session in self?.sessions ?? [] {
                    session.captureSession.maxOutputLongEdge = CGFloat(newValue)
                }
            }
            .store(in: &settingsCancellables)
        // 画中画透明度 — same live-apply contract as the two settings above (PiPPanelController.
        // updateOpacity itself no-ops for a panel that's currently hidden, see its own doc comment).
        SettingsStore.shared.$panelOpacity
            .dropFirst()
            .sink { [weak self] _ in
                for session in self?.sessions ?? [] {
                    session.panelController.updateOpacity()
                }
            }
            .store(in: &settingsCancellables)
    }

    /// M3: whenever the frontmost app changes, pull any matching session's window onto the
    /// physical screen (and hide its panel) if its source app just became frontmost, or send it
    /// back to the virtual display (and re-show the panel) if the user just switched away from
    /// a session that was in that state.
    @objc private func activeApplicationDidChange(_ notification: Notification) {
        guard let activatedApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        debugTrace("activation: app pid=\(activatedApp.processIdentifier) sessions=\(sessions.map { "\($0.windowInfo.ownerPID):\($0.captureSession.presentationState)" })")
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
        guard !isPreparingForTermination else { return }
        debugTrace("startSession(for:) called id=\(windowInfo.id) pid=\(windowInfo.ownerPID) frame=\(windowInfo.frame) for \(windowInfo.ownerAppName)/\(windowInfo.title)")
        if sessions.contains(where: { Self.representsSameSource($0.windowInfo, windowInfo) }) {
            PiPanelLogger.app.info("Session already active for window \(windowInfo.id)")
            debugTrace("startSession ignored: source already represented id=\(windowInfo.id) pid=\(windowInfo.ownerPID)")
            return
        }
        guard !startingSourcePIDs.contains(windowInfo.ownerPID) else {
            debugTrace("startSession ignored: startup already pending for pid=\(windowInfo.ownerPID)")
            return
        }
        guard sessions.isEmpty else { return }
        startingSourcePIDs.insert(windowInfo.ownerPID)

        // Screen selection must happen after launch-time pre-warming finishes. Otherwise a user
        // triggering PiP during the brief initial topology setup could have the source matched
        // against an intermediate arrangement. Concurrent callers await the same pool warm-up.
        Task { @MainActor [weak self] in
            await VirtualDisplayPool.shared.warmUp(
                longEdge: CGFloat(SettingsStore.shared.virtualDisplayLongEdge)
            )
            self?.startPreparedSession(for: windowInfo)
        }
    }

    private func startPreparedSession(for originalWindowInfo: WindowInfo) {
        guard !isPreparingForTermination else {
            startingSourcePIDs.remove(originalWindowInfo.ownerPID)
            return
        }
        guard startingSourcePIDs.contains(originalWindowInfo.ownerPID) else { return }
        guard !sessions.contains(where: { Self.representsSameSource($0.windowInfo, originalWindowInfo) }) else {
            startingSourcePIDs.remove(originalWindowInfo.ownerPID)
            return
        }
        guard sessions.isEmpty else {
            startingSourcePIDs.remove(originalWindowInfo.ownerPID)
            return
        }

        // The launch-time topology setup may have completed between gesture detection and this
        // point. Refresh the live AX frame so target-screen matching never uses that stale sample.
        var windowInfo = originalWindowInfo
        if let axWindow = AXWindowLocator.locate(originalWindowInfo),
           let liveFrame = AXWindowLocator.frame(of: axWindow) {
            windowInfo.frame = liveFrame
        }
        let siblingCaptureSessions = sessions.map(\.captureSession)

        // Resolve the source monitor in Quartz space before creating any virtual display. Using
        // its stable display ID lets us find the same physical monitor again after WindowServer's
        // topology reflow, even if that monitor's AppKit frame changed in the meantime.
        let sourceScreen = bestMatchingRealScreen(forQuartzFrame: windowInfo.frame) ?? NSScreen.main
        let sourceDisplayID = sourceScreen.flatMap(Self.displayID)
        let panelFrame = defaultPanelFrame(for: windowInfo, on: sourceScreen)
        let placementAnchor = sourceScreen.map {
            PanelPlacementAnchor(
                frame: panelFrame,
                visibleFrame: $0.visibleFrame,
                corner: SettingsStore.shared.defaultStackingCorner
            )
        }
        debugTrace("creating PiPPanelController with frame \(panelFrame)")
        let panelController = PiPPanelController(
            initialFrame: panelFrame,
            nativeSize: windowInfo.frame.size,
            windowTitle: windowInfo.title,
            sourceBundleIdentifier: windowInfo.ownerBundleIdentifier
        )
        panelController.delegate = self
        debugTrace("panel created and ordered front")

        let framePresenter = LatestVideoFramePresenter(panelController: panelController)
        let captureSession = CaptureSession(windowInfo: windowInfo, framePresenter: framePresenter)
        captureSession.delegate = self
        captureSession.siblingSessionsProvider = { [weak self, weak captureSession] in
            guard let self, let captureSession else { return [] }
            return self.sessions
                .map(\.captureSession)
                .filter { $0 !== captureSession }
        }
        captureSession.targetFPS = SettingsStore.shared.targetFPS
        captureSession.captureDisplayMaximumFPS = DisplayRefreshRate.maximumPhysicalFPS()
        captureSession.presentationDisplayMaximumFPS = DisplayRefreshRate.fps(for: sourceScreen)
        captureSession.virtualDisplayLongEdge = SettingsStore.shared.virtualDisplayLongEdge
        captureSession.maxOutputLongEdge = CGFloat(SettingsStore.shared.captureOutputLongEdge)
        panelController.onPresentationDisplayMaximumFPSChanged = { [weak captureSession] fps in
            captureSession?.presentationDisplayMaximumFPS = fps
        }

        let interactionForwarder = InteractionForwarder(captureSession: captureSession)
        interactionForwarder.autoReturnEnabled = SettingsStore.shared.autoReturnEnabled
        interactionForwarder.autoReturnIdleInterval = SettingsStore.shared.autoReturnIdleInterval
        panelController.interactionForwarder = interactionForwarder

        let session = PiPSession(windowInfo: windowInfo, captureSession: captureSession, panelController: panelController)
        sessions.append(session)
        sessionsByCaptureSession[ObjectIdentifier(captureSession)] = session

        Task {
            defer { self.startingSourcePIDs.remove(windowInfo.ownerPID) }
            debugTrace("calling captureSession.start()")
            do {
                try await captureSession.start(reanchoring: siblingCaptureSessions)
                debugTrace("captureSession.start() returned successfully")
                await self.stabilizePanelPlacement(
                    for: session,
                    onSourceDisplayID: sourceDisplayID,
                    anchor: placementAnchor
                )
            } catch {
                debugTrace("Failed to start capture: \(error)")
                self.stopSession(session)
            }
        }
    }

    private static func representsSameSource(_ lhs: WindowInfo, _ rhs: WindowInfo) -> Bool {
        if lhs.id == rhs.id { return true }
        guard lhs.ownerPID == rhs.ownerPID,
              SourceWindowMatcher.titlesLikelyMatch(lhs.title, rhs.title) else { return false }

        // SC and AX can trail one another briefly while the source window is moving, but its size
        // remains stable. Keep the tolerance bounded so separate same-title windows stay eligible.
        return SourceWindowMatcher.distance(lhs.frame, rhs.frame) < 600
    }

    func stopSession(_ session: PiPSession) {
        _ = stopTask(for: session)
    }

    @discardableResult
    private func stopTask(for session: PiPSession) -> Task<Void, Never>? {
        if let existing = stoppingTasks[session.id] { return existing }
        guard sessions.contains(where: { $0.id == session.id }),
              stoppingSessionIDs.insert(session.id).inserted else { return nil }
        session.panelController.close()
        let task = Task { @MainActor [weak self] in
            await session.captureSession.stop()
            guard let self else { return }
            self.sessions.removeAll { $0.id == session.id }
            self.sessionsByCaptureSession.removeValue(forKey: ObjectIdentifier(session.captureSession))
            self.stoppingSessionIDs.remove(session.id)
            self.stoppingTasks.removeValue(forKey: session.id)
        }
        stoppingTasks[session.id] = task
        return task
    }

    func stopAll() {
        for session in sessions { stopSession(session) }
    }

    /// Used by AppDelegate's terminate-later handshake. It prevents new sessions, cancels pending
    /// pre-session preparation, and does not return until every CaptureSession.stop() has restored
    /// its source window and released its virtual display lease.
    func stopAllAndWaitForWindowRestoration() async {
        isPreparingForTermination = true
        startingSourcePIDs.removeAll()
        let tasks = sessions.compactMap { stopTask(for: $0) }
        for task in tasks {
            await task.value
        }
    }

    /// Picks whichever currently-active, real (non-PiPanel-virtual) screen a given frame overlaps
    /// most — shared by defaultPanelFrame (anchored to the source window's own real on-screen
    /// frame, so a freshly-created panel lands on whichever screen the user actually triggered PiP
    /// from) and snapSessionsToStackingCorner (anchored to an already-open panel's own frame).
    /// Excluding every PiPanel-managed virtual display is essential, not cosmetic — this now
    /// includes the idle pre-warmed pool as well as displays leased by open sessions.
    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    private func realScreens() -> [NSScreen] {
        let virtualDisplayIDs = VirtualDisplayHost.activeDisplayIDs
        return NSScreen.screens.filter { screen in
            guard let displayID = Self.displayID(for: screen) else { return true }
            return !virtualDisplayIDs.contains(displayID)
        }
    }

    private func realScreen(withDisplayID displayID: CGDirectDisplayID) -> NSScreen? {
        realScreens().first { Self.displayID(for: $0) == displayID }
    }

    /// AppKit-space lookup used for already-created PiP panels.
    private func bestMatchingRealScreen(for frame: CGRect) -> NSScreen? {
        let best = realScreens()
            .max { a, b in
                Self.intersectionArea(frame, a.frame) < Self.intersectionArea(frame, b.frame)
            }
        guard let best, Self.intersectionArea(frame, best.frame) > 0 else { return nil }
        return best
    }

    /// WindowInfo/AX frames are Quartz-global (top-left, Y grows downward), while NSScreen.frame is
    /// AppKit-global (bottom-left, Y grows upward). Comparing those rectangles after a single
    /// primary-height flip is fragile for monitors placed above/below one another. Compare the
    /// source directly with each physical display's CGDisplayBounds instead, then carry that
    /// display's stable ID through virtual-display creation.
    private func bestMatchingRealScreen(forQuartzFrame frame: CGRect) -> NSScreen? {
        let candidates = realScreens().compactMap { screen -> (screen: NSScreen, area: CGFloat)? in
            guard let displayID = Self.displayID(for: screen) else { return nil }
            let quartzBounds = CGDisplayBounds(displayID)
            guard quartzBounds.width > 0, quartzBounds.height > 0 else { return nil }
            return (screen, Self.intersectionArea(frame, quartzBounds))
        }
        guard let best = candidates.max(by: { $0.area < $1.area }), best.area > 0 else { return nil }
        return best.screen
    }

    /// Places the single free PiP at the selected corner of the source window's physical screen.
    private func defaultPanelFrame(
        for windowInfo: WindowInfo,
        on preferredScreen: NSScreen? = nil
    ) -> NSRect {
        // NSScreen.main is "whichever screen has the key window," which for this accessory app
        // (no window of its own usually has key focus) doesn't track where the user actually
        // triggered PiP from at all — confirmed as a real regression: opening a window on a
        // *non-main* display still placed the new panel using the system's main display's own
        // corner, nowhere near the window the user was actually looking at. windowInfo.frame is the
        // source window's own real, current on-screen position (this runs before it's ever moved to
        // any virtual display), so anchoring to whichever real screen *that* overlaps most actually
        // tracks the right monitor. Only falls back to NSScreen.main if the source window's frame
        // doesn't clearly overlap any real screen (e.g. some edge case with off-screen coordinates).
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let sourceAppKitFrame = CoordinateTranslator.appKitFrame(
            fromQuartzFrame: windowInfo.frame,
            primaryScreenHeight: primaryHeight
        )
        guard let screen = preferredScreen
                ?? bestMatchingRealScreen(forQuartzFrame: windowInfo.frame)
                ?? bestMatchingRealScreen(for: sourceAppKitFrame)
                ?? NSScreen.main else {
            return NSRect(x: 100, y: 100, width: 320, height: 200)
        }
        let aspect = windowInfo.frame.width / max(windowInfo.frame.height, 1)
        let width = CGFloat(SettingsStore.shared.defaultPanelWidth)
        let height = max(width / max(aspect, 0.1), 120)
        let margin: CGFloat = 24
        let corner = SettingsStore.shared.defaultStackingCorner
        let visible = screen.visibleFrame
        let displayID = Self.displayID(for: screen) ?? kCGNullDirectDisplay
        debugTrace("panel placement: sourceQuartz=\(windowInfo.frame) sourceAppKit=\(sourceAppKitFrame) targetDisplayID=\(displayID) targetScreen=\(screen.frame) visible=\(visible)")

        let x = corner.isLeading
            ? visible.minX + margin
            : visible.maxX - width - margin

        let y = corner.isTop ? visible.maxY - height : visible.minY

        return NSRect(x: x, y: y, width: width, height: height)
    }

    /// Creating and positioning a CGVirtualDisplay can move an NSScreen's global origin even
    /// though the physical monitor itself has not changed. The panel's first frame is computed
    /// before that operation so it appears immediately; once startup finishes, resolve the same
    /// physical display by ID and correct the resting frame against its now-final visibleFrame.
    /// Skip the correction only if PiPVideoLayerView observed a real user drag while capture was
    /// loading. A frame comparison cannot establish user intent here: WindowServer routinely
    /// relocates untouched panels to another physical display, off-screen, or onto a PiPanel
    /// virtual display while the display topology is changing.
    private func stabilizePanelPlacement(
        for session: PiPSession,
        onSourceDisplayID displayID: CGDirectDisplayID?,
        anchor: PanelPlacementAnchor?
    ) async {
        // The capture topology barrier waits for CoreGraphics, but NSScreen can publish its
        // visibleFrame one or two main-run-loop turns later. Correct immediately, then verify the
        // anchor twice more over a short window. Every pass stops as soon as the user actually
        // drags/resizes, and a closed session is never brought back.
        let delays: [UInt64] = [0, 150_000_000, 450_000_000]
        for (attempt, delay) in delays.enumerated() {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard sessions.contains(where: { $0.id == session.id }) else { return }
            guard !session.panelController.hasUserAdjustedFrameSinceCreation else {
                debugTrace("panel placement: stabilization stopped after explicit user drag attempt=\(attempt)")
                return
            }
            finalizePanelPlacement(
                for: session,
                onSourceDisplayID: displayID,
                anchor: anchor,
                attempt: attempt
            )
        }
    }

    private func finalizePanelPlacement(
        for session: PiPSession,
        onSourceDisplayID displayID: CGDirectDisplayID?,
        anchor: PanelPlacementAnchor?,
        attempt: Int
    ) {
        guard let displayID, let anchor else { return }
        guard let screen = realScreen(withDisplayID: displayID) else {
            debugTrace("panel placement: physical screen not visible yet displayID=\(displayID) attempt=\(attempt)")
            return
        }
        let panel = session.panelController.panel
        let currentFrame = panel.frame
        guard !session.panelController.hasUserAdjustedFrameSinceCreation else {
            debugTrace("panel placement: final correction skipped after explicit user drag displayID=\(displayID) current=\(currentFrame)")
            return
        }

        let correctedFrame = anchor.frame(in: screen.visibleFrame)
        debugTrace("panel placement: final correction displayID=\(displayID) attempt=\(attempt) screen=\(screen.frame) visible=\(screen.visibleFrame) before=\(currentFrame) corrected=\(correctedFrame)")
        guard abs(currentFrame.minX - correctedFrame.minX) > 1
                || abs(currentFrame.minY - correctedFrame.minY) > 1 else { return }

        // This is recovery from a topology-induced jump, not a user-visible navigation gesture.
        // Applying it immediately avoids an extra cross-screen "fly back" animation.
        panel.setFrame(correctedFrame, display: true)
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        return intersection.width * intersection.height
    }
}

extension PiPSessionManager: PiPPanelControllerDelegate {
    func pipPanelControllerDidRequestClose(_ controller: PiPPanelController) {
        guard let session = sessions.first(where: { $0.panelController === controller }) else { return }
        stopSession(session)
    }

}

extension PiPSessionManager: CaptureSessionDelegate {
    nonisolated func captureSessionDidStop(_ session: CaptureSession, error: Error?) {
        Task { @MainActor in
            guard let pipSession = self.sessionsByCaptureSession[ObjectIdentifier(session)] else { return }
            PiPanelLogger.app.info("Source window disappeared, closing PiP panel")
            self.stopSession(pipSession)
        }
    }
}
