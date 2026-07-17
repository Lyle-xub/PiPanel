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

@MainActor
final class PiPSessionManager: NSObject, ObservableObject {
    static let shared = PiPSessionManager()

    @Published private(set) var sessions: [PiPSession] = []
    /// Whether the group is currently gathered into stackAllSessions' overlapping pile — gates
    /// PiPVideoLayerView.isPartOfStack on every panel, and what GlobalHotkeyManager's shortcut and
    /// unstackSessions each toggle.
    @Published private(set) var isStacked = false
    /// Set by startSession whenever a non-member tries to open a second concurrent PiP (see
    /// Constants.freeSessionLimit) — WindowPickerView surfaces this as a brief inline hint rather
    /// than the request just silently doing nothing. Cleared automatically a few seconds later.
    @Published private(set) var membershipLimitMessage: String?
    private var membershipLimitMessageResetTask: Task<Void, Never>?

    private enum Constants {
        /// Non-members can run exactly one PiP session at a time; membership removes the cap
        /// entirely. Everything else in the app (auto-hide, resize, appearance, etc.) stays fully
        /// usable either way — this is the one place session *count* itself is gated, mirroring
        /// how MembershipGate already gates the settings UI's customization options.
        static let freeSessionLimit = 1
    }

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
    /// A shake can produce another valid gesture before the first asynchronous virtual-display
    /// startup has finished. WindowServer may also assign a fresh SCWindowID while the window is
    /// moving, so sessions' ID-only duplicate check is insufficient during that gap.
    private var startingSourcePIDs: Set<pid_t> = []
    /// Each session's frame from right before stackAllSessions moved it — restored by
    /// unstackSessions, so expanding the stack (via the hotkey again, or clicking any panel in it)
    /// puts every panel back exactly where the user had actually arranged it, rather than back
    /// into some fresh auto-layout that would just have to be manually re-arranged all over again.
    private var preStackFrames: [PiPSession.ID: NSRect] = [:]
    private let flingDetector = WindowFlingDetector()
    private let cornerPiPController = WindowCornerPiPController()
    private let hotkeyManager = GlobalHotkeyManager()
    private let idleMonitor = GlobalIdleMonitor()
    private var settingsCancellables: Set<AnyCancellable> = []
    private var virtualDisplayIntrusionGuardTask: Task<Void, Never>?
    private var lastSafeWindowFrames: [CGWindowID: CGRect] = [:]

    /// True once autoStackOnIdle has hidden the (already-stacked) group completely, replaced
    /// on-screen by edgeHandleWindow. Distinct from isStacked, which just means "gathered into the
    /// overlapping pile" — the manual stack hotkey sets isStacked without ever hiding anything.
    private var isEdgeDocked = false
    /// The small, always-fully-on-screen handle shown in place of the whole group while
    /// isEdgeDocked — see its own doc comment for why it's a separate window rather than a sliver
    /// of one of the PiP panels left on-screen.
    private let edgeHandleWindow = EdgeHandleWindow()
    /// The real screen snapSessionsToStackingCorner anchors to for as long as the group stays
    /// stacked — computed once, from each panel's true pre-stack frame, when the group is first
    /// gathered (stackAllSessions/dockStackToEdge's own `!isStacked` branch) rather than
    /// re-derived on every reveal/re-hide call. Necessary specifically for multi-monitor setups
    /// with no gap between screens: once docked, a panel's own frame sits mostly *past* the
    /// screen's edge, which — when another real monitor happens to be immediately adjacent there
    /// — lands mostly inside that neighboring screen's own frame instead of empty space.
    /// bestMatchingRealScreen picks whichever screen a frame overlaps *most*, so re-deriving from
    /// the already-docked frame on the very next reveal/re-hide picked that neighbor instead, and
    /// every call after that kept picking whichever screen the *previous* snap happened to leave
    /// it mostly overlapping — confirmed via /tmp/pipanel_trace.log as a real drift across a
    /// dock/reveal/re-dock cycle (the anchor screen permanently jumped to the neighboring monitor
    /// after a single dock). Freezing it at gather time, while every panel is still genuinely
    /// on-screen, breaks that feedback loop.
    private var stackedScreen: NSScreen?

    override init() {
        super.init()
        VirtualDisplayCursorGuard.shared.start()
        edgeHandleWindow.delegate = self
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeApplicationDidChange(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        flingDetector.onFling = { [weak self] windowInfo in
            self?.startSession(for: windowInfo)
        }
        cornerPiPController.onRequestPiP = { [weak self] windowInfo in
            self?.startSession(for: windowInfo)
        }
        idleMonitor.onIdleThresholdReached = { [weak self] in
            self?.autoStackOnIdle()
        }
        observeLiveSettings()
        observeActivationMethod()
        hotkeyManager.register(shortcut: { SettingsStore.shared.stackShortcut }) { [weak self] in
            guard let self else { return }
            self.isStacked ? self.unstackSessions() : self.stackAllSessions()
        }
        hotkeyManager.register(shortcut: { SettingsStore.shared.closeAllShortcut }) { [weak self] in
            self?.stopAll()
        }
        hotkeyManager.register(shortcut: { SettingsStore.shared.pipAllShortcut }) { [weak self] in
            self?.pipAllEligibleWindows()
        }
        hotkeyManager.start()
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

    /// Keeps exactly one single-window activation affordance live. Both a seven-day trial and a
    /// permanent license may start WindowFlingDetector. If a saved shake preference is read before
    /// entitlement validation completes (or after it expires), the free corner switch remains
    /// available as the fallback without destroying that saved preference.
    private func observeActivationMethod() {
        SettingsStore.shared.$pipActivationMethod
            .combineLatest(MembershipManager.shared.$entitlement)
            .sink { [weak self] method, entitlement in
                guard let self else { return }
                let hasProAccess: Bool
                switch entitlement {
                case .trial, .licensed: hasProAccess = true
                case .free: hasProAccess = false
                }

                if method.resolved(hasProAccess: hasProAccess) == .shake {
                    self.cornerPiPController.stop()
                    self.flingDetector.start()
                } else {
                    self.flingDetector.stop()
                    self.cornerPiPController.start()
                }
            }
            .store(in: &settingsCancellables)
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
        SettingsStore.shared.$controlModeGlowEnabled
            .dropFirst()
            .sink { [weak self] _ in
                for session in self?.sessions ?? [] {
                    session.panelController.updateControlModeGlowPreference()
                }
            }
            .store(in: &settingsCancellables)
        // Not dropFirst(): idleMonitor needs to be started on launch too if the setting was
        // already on from a previous run, not just the moment the user flips the toggle live.
        SettingsStore.shared.$autoStackOnIdleEnabled
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.idleMonitor.start { SettingsStore.shared.autoStackIdleInterval }
                } else {
                    self.idleMonitor.stop()
                }
            }
            .store(in: &settingsCancellables)
    }

    /// Called by idleMonitor once the system has been idle — no real or forwarded input anywhere,
    /// not just within a PiP panel, see GlobalIdleMonitor's own doc comment — for at least
    /// SettingsStore.autoStackIdleInterval. Only ever docks, never un-docks: a user manually
    /// un-stacking shouldn't get immediately re-docked by this — the next idle *period* simply
    /// won't fire again until they interact and go idle a second time (see GlobalIdleMonitor.
    /// hasFiredForCurrentIdlePeriod).
    private func autoStackOnIdle() {
        debugTrace("idle: autoStackOnIdle called sessions.count=\(sessions.count) isStacked=\(isStacked) isEdgeDocked=\(isEdgeDocked)")
        dockStackToEdge()
    }

    /// "长时间无操作时自动堆叠贴边" — matches macOS's own PiP auto-hide (Safari/QuickTime): not just
    /// gathering into the overlapping stack and sitting fully visible at a corner (that's what
    /// stackAllSessions/the manual hotkey already do), but disappearing completely, replaced by
    /// edgeHandleWindow — a small, fixed pill sitting at the screen edge, modeled on iOS's own
    /// collapsed-PiP handle (see that type's own doc comment for why it's a wholly separate window
    /// rather than a partially-off-screen sliver of a PiP panel, the design this replaced). Gathers
    /// into the stack first if it isn't already (same preStackFrames/isStacked bookkeeping as
    /// stackAllSessions, so a later unstack still restores each panel's true pre-stack position) —
    /// since a single open session is also "gathered" this way trivially, this matches real PiP's
    /// behavior for a lone player too, not just multi-session groups.
    private func dockStackToEdge() {
        guard !sessions.isEmpty else { return }
        if !isStacked {
            preStackFrames = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.panelController.panel.frame) })
            isStacked = true
            stackedScreen = bestMatchingRealScreen(for: sessions.first!.panelController.panel.frame) ?? NSScreen.main
            for session in sessions {
                session.panelController.panel.orderFrontRegardless()
                session.panelController.setStacked(true)
            }
            snapSessionsToStackingCorner()
        }
        isEdgeDocked = true
        for session in sessions {
            session.panelController.setFullyHidden(true)
        }
        if let screen = stackedScreen {
            edgeHandleWindow.show(on: screen, corner: SettingsStore.shared.defaultStackingCorner)
        }
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
        guard MembershipManager.shared.isMember || sessions.count < Constants.freeSessionLimit else {
            showMembershipLimitMessage()
            return
        }
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
        guard MembershipManager.shared.isMember || sessions.count < Constants.freeSessionLimit else {
            startingSourcePIDs.remove(originalWindowInfo.ownerPID)
            showMembershipLimitMessage()
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
        // A brand-new panel would join the group at its own defaultPanelFrame position while
        // every existing one still sits stacked and unclickable-except-to-expand
        // (PiPVideoLayerView.isPartOfStack) — a confusing half-stacked state. Expanding first
        // keeps "the group is stacked" an all-or-nothing fact.
        if isStacked { unstackSessions() }

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
        captureSession.onSourceWindowWillMoveOntoVirtualDisplay = { [weak panelController] in
            panelController?.sourceWindowWillMoveOntoVirtualDisplay()
        }
        captureSession.onSourceWindowDidMoveOntoVirtualDisplay = { [weak panelController] in
            panelController?.sourceWindowDidMoveOntoVirtualDisplay()
        }
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
              FlingCandidateMatcher.titlesLikelyMatch(lhs.title, rhs.title) else { return false }

        // During a shake, SC and AX can trail one another by a few hundred points but the window's
        // size remains stable. Keep the tolerance bounded so two genuinely separate same-title
        // windows from the same app remain eligible once the first startup has completed.
        return FlingCandidateMatcher.distance(lhs.frame, rhs.frame) < 600
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
        // Also covers the no-active-session case where the pointer crossed onto an idle pre-warmed
        // display. Session close performs the same rescue for an intentional control capture.
        _ = VirtualDisplayCursorGuard.shared.returnCursorToPhysical()
        let tasks = sessions.compactMap { stopTask(for: $0) }
        for task in tasks {
            await task.value
        }
    }

    /// Turns every eligible window — not already a PiP session, not minimized, not fullscreen
    /// (AXWindowLocator.isMinimized/isFullScreen), not otherwise filtered out by WindowEnumerator's
    /// own candidate rules (system helper windows, windows too small to be a real document, this
    /// app's own windows) — into a PiP session, then gathers the result into the overlapping stack.
    /// A non-member only ever gets as far as the first one; startSession's own freeSessionLimit
    /// check silently stops the rest from opening, same as it would for any other way of starting a
    /// second session.
    func pipAllEligibleWindows() {
        Task {
            guard let candidates = try? await WindowEnumerator.listPiPCandidateWindows() else { return }
            let alreadyOpen = Set(sessions.map(\.windowInfo.id))
            let startCountBefore = sessions.count
            for windowInfo in candidates where !alreadyOpen.contains(windowInfo.id) {
                guard let axWindow = AXWindowLocator.locate(windowInfo),
                      !AXWindowLocator.isFullScreen(axWindow),
                      !AXWindowLocator.isMinimized(axWindow) else { continue }
                startSession(for: windowInfo)
            }
            guard sessions.count > startCountBefore else { return }
            // Panels animate in over PiPPanelController.animateEntrance's own 0.32s slide — waiting
            // a little past that before gathering them into the stack avoids stackAllSessions
            // reading (and fighting) a still-mid-slide-in frame as if it were each panel's actual
            // resting position.
            try? await Task.sleep(nanoseconds: 400_000_000)
            stackAllSessions()
        }
    }

    private func showMembershipLimitMessage() {
        membershipLimitMessageResetTask?.cancel()
        membershipLimitMessage = "免费版最多同时开启 1 个画中画，购买专业版解锁无限数量"
        // The @Published property above only ever reaches WindowPickerView's own inline banner,
        // which is silently invisible unless the menu bar dropdown happens to already be open at
        // this exact moment — not the case for either of this method's other two callers
        // (WindowFlingDetector's shake gesture, GlobalHotkeyManager's "PiP all" shortcut), both
        // triggered while the user is looking at their desktop instead. This floating toast is
        // what's actually visible for those.
        MembershipLimitToast.shared.show(membershipLimitMessage!)
        membershipLimitMessageResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.membershipLimitMessage = nil
        }
    }

    /// Laid out edge-to-edge (each panel's full height + a gap below the last) at first — reusing
    /// defaultPanelFrame's own geometry, just re-applied to every session instead of only the
    /// newest — but that grows the group's total footprint linearly with session count, and with
    /// more than a handful open it ran panels right off the bottom of the screen, which read as
    /// them "just disappearing" rather than stacking. Apple's own Notification Center stack is the
    /// better reference: every panel keeps its size, but instead of tiling downward they mostly
    /// overlap, offset from the frontmost by a small step per layer that maxes out after a few —
    /// so the group's total footprint barely grows no matter how many panels are open, and it
    /// visibly reads as a stack rather than a list.
    func stackAllSessions() {
        guard !sessions.isEmpty, !isStacked else { return }
        preStackFrames = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.panelController.panel.frame) })
        isStacked = true
        stackedScreen = bestMatchingRealScreen(for: sessions.first!.panelController.panel.frame) ?? NSScreen.main
        snapSessionsToStackingCorner()
        // The animation above only moves frames — it doesn't touch front-to-back window ordering,
        // so without this the OS's actual stacking order might not match the newest-on-top visual
        // the offsets are implying. Bringing each forward in oldest-to-newest order leaves the
        // newest genuinely frontmost.
        for session in sessions {
            session.panelController.panel.orderFrontRegardless()
            session.panelController.setStacked(true)
        }
    }

    /// The actual geometry half of stackAllSessions — factored out so dockStackToEdge can re-run
    /// just this part (when first gathering into a group that's about to be hidden behind
    /// edgeHandleWindow) without repeating stackAllSessions' own one-time preStackFrames/isStacked
    /// bookkeeping. Always lands fully on-screen, margin points in from the edge — a hidden
    /// (edge-docked) group no longer parks its panels at some special partially-off-screen
    /// position at all; it just goes fully invisible in place (PiPPanelController.setFullyHidden),
    /// so there's only ever this one resting position to compute anymore.
    private func snapSessionsToStackingCorner() {
        // Anchored to stackedScreen — frozen once, from each panel's true pre-stack frame, when
        // the group was first gathered (see that property's own doc comment for why re-deriving
        // this on every call is wrong). The fallback here only matters if this is somehow reached
        // before stackAllSessions/dockStackToEdge ever set it.
        //
        // NSScreen.screens includes PiPanel's own private virtual displays (VirtualDisplayHost),
        // not just real monitors — confirmed via /tmp/pipanel_trace.log as the cause of a real
        // regression. bestMatchingRealScreen excludes every displayID currently backing an open
        // session's VirtualDisplayHost, so it always picks a real, user-visible monitor.
        guard let screen = stackedScreen ?? bestMatchingRealScreen(for: sessions.first!.panelController.panel.frame) ?? NSScreen.main else { return }

        let margin = CGFloat(SettingsStore.shared.stackCascadeMargin)
        let corner = SettingsStore.shared.defaultStackingCorner
        let visible = screen.visibleFrame
        let step = CGFloat(SettingsStore.shared.stackCascadeStep)
        let maxVisibleDepth = Int(SettingsStore.shared.stackMaxVisibleDepth)
        debugTrace("stack: screen=\(screen) visibleFrame=\(visible) corner=\(corner)")

        // The newest session ends up frontmost, sitting exactly at the anchor corner; earlier
        // ones peek out increasingly from behind it, capped at maxVisibleDepth layers of offset.
        for (reverseIndex, session) in sessions.reversed().enumerated() {
            let panel = session.panelController.panel
            let sessionID = session.id
            let size = panel.frame.size
            let depth = CGFloat(min(reverseIndex, maxVisibleDepth))
            // No vertical margin, matching defaultPanelFrame's own convention below — visibleFrame
            // already excludes the menu bar/Dock, so a panel's edge sitting flush against it looks
            // right without extra clearance; only the horizontal edge needs one.
            let cornerX = corner.isLeading ? visible.minX + margin : visible.maxX - size.width - margin
            let cornerY = corner.isTop ? visible.maxY - size.height : visible.minY
            let x = cornerX + (corner.isLeading ? depth * step : -depth * step)
            let y = cornerY + (corner.isTop ? -depth * step : depth * step)
            let targetFrame = NSRect(x: x, y: y, width: size.width, height: size.height)
            debugTrace("stack: session=\(sessionID) beforeFrame=\(panel.frame) targetFrame=\(targetFrame)")
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(targetFrame, display: true)
            } completionHandler: {
                debugTrace("stack: session=\(sessionID) afterFrame=\(panel.frame)")
            }
        }
    }

    /// The other half of stackAllSessions — restores every panel to wherever it actually was right
    /// before being gathered into the stack, and lets each one resume its own normal gestures
    /// (move/resize/double-click-to-control) again. Triggered by GlobalHotkeyManager's shortcut a
    /// second time (the manager toggles based on isStacked), or by clicking any panel while it's
    /// part of the stack (PiPVideoLayerView.isPartOfStack → videoViewDidRequestUnstack →
    /// pipPanelControllerDidRequestUnstackAll below) — same as clicking a notification group
    /// expands it in Notification Center.
    func unstackSessions() {
        guard isStacked else { return }
        isStacked = false
        isEdgeDocked = false
        stackedScreen = nil
        edgeHandleWindow.hide()
        for session in sessions {
            session.panelController.setStacked(false)
            session.panelController.setFullyHidden(false)
            guard let frame = preStackFrames[session.id] else { continue }
            let panel = session.panelController.panel
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        }
        preStackFrames.removeAll()
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

    /// Anchors to SettingsStore.shared.defaultStackingCorner (default top-right, matching this
    /// method's original hardcoded-always-top-right behavior byte-for-byte) and stacks additional
    /// panels away from that corner — each new one goes directly adjacent to the outermost
    /// currently-open panel, rather than the old tiny diagonal-cascade offset, which left multiple
    /// sessions' panels almost fully overlapping (M4: multi-session). Top corners stack downward
    /// (using the lowest existing panel's bottom edge); bottom corners are the mirror image and
    /// stack upward (using the highest existing panel's top edge).
    private func defaultPanelFrame(
        for windowInfo: WindowInfo,
        on preferredScreen: NSScreen? = nil,
        excludingPanel: NSPanel? = nil
    ) -> NSRect {
        // NSScreen.main is "whichever screen has the key window," which for this accessory app
        // (no window of its own usually has key focus) doesn't track where the user actually
        // triggered PiP from at all — confirmed as a real regression: shaking a window open on a
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
        let margin = CGFloat(SettingsStore.shared.stackCascadeMargin)
        let gap: CGFloat = 12
        let corner = SettingsStore.shared.defaultStackingCorner
        let visible = screen.visibleFrame
        let existingFramesOnScreen = sessions
            .filter { $0.panelController.panel !== excludingPanel }
            .map { $0.panelController.panel.frame }
            .filter { Self.intersectionArea($0, screen.frame) > 0 }
        let displayID = Self.displayID(for: screen) ?? kCGNullDirectDisplay
        debugTrace("panel placement: sourceQuartz=\(windowInfo.frame) sourceAppKit=\(sourceAppKitFrame) targetDisplayID=\(displayID) targetScreen=\(screen.frame) visible=\(visible) existingOnScreen=\(existingFramesOnScreen.count)")

        let x = corner.isLeading
            ? visible.minX + margin
            : visible.maxX - width - margin

        let y: CGFloat
        if corner.isTop {
            let lowestExistingBottom = existingFramesOnScreen
                .map(\.minY)
                .min() ?? (visible.maxY + gap)
            y = lowestExistingBottom - gap - height
        } else {
            let highestExistingTop = existingFramesOnScreen
                .map(\.maxY)
                .max() ?? (visible.minY - gap)
            y = highestExistingTop + gap
        }

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

    func pipPanelControllerDidRequestUnstackAll(_ controller: PiPPanelController) {
        unstackSessions()
    }
}

extension PiPSessionManager: EdgeHandleWindowDelegate {
    func edgeHandleWindowDidClick(_ window: EdgeHandleWindow) {
        unstackSessions()
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
