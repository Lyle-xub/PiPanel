import ScreenCaptureKit
import CoreMedia
import AppKit
import ApplicationServices

protocol CaptureSessionDelegate: AnyObject {
    func captureSession(_ session: CaptureSession, didOutput sampleBuffer: CMSampleBuffer)
    func captureSessionDidStop(_ session: CaptureSession, error: Error?)
}

enum CaptureSessionError: Error {
    case windowNotAccessible
    case virtualDisplayCreationFailed
    case virtualDisplayNotVisibleToScreenCaptureKit
}

/// Owns one PiP capture session: leases a logical layer of the application-lifetime shared virtual
/// canvas, relocates the source window into its common workspace via Accessibility, and captures
/// only that source window through ScreenCaptureKit. Source windows may overlap on the hidden
/// canvas; the per-window SCContentFilter is the isolation boundary between sessions.
///
/// Why a virtual display instead of capturing the window in place: SCContentFilter's two
/// window-scoped filter types were both verified (Spikes/CaptureSpike) to break for this
/// product's core requirement —
///   - desktopIndependentWindow (macOS 14+, nominally "survives Space changes"): delivers
///     exactly one status-only frame and then silently stalls forever on this OS build.
///   - display(_:including:): streams reliably, but only while the window's Space is the
///     currently active one — the moment another app goes full-screen elsewhere, frames keep
///     arriving but are blank.
/// A private virtual display (Spikes/VirtualDisplaySpike) doesn't have this problem: it's a
/// genuinely independent, always-composited display, so display(_:excludingWindows:) against it
/// streams continuously regardless of what's happening on the physical screen. The tradeoff is
/// the window physically leaves the user's real screens for as long as the session is active —
/// SourceWindowActivator (M2/M3) is responsible for moving it back for interaction and restoring
/// it on session stop.
///
/// One more sharp edge (Spikes/VirtualDisplaySpike): a virtual display created *small* (roughly
/// window-sized, e.g. ~500x460) reliably gets placed by macOS at the same (0,0) origin as the
/// main display instead of being extended beside it — the two overlap in global coordinate
/// space, which made a window moved onto the virtual display ambiguously render back on the
/// real screen, and in one case made macOS mirror the physical display down to the tiny
/// resolution instead. A virtual display created at a "normal monitor" size (1280x800) was
/// reliably placed beside the physical display with no overlap. So the virtual display is
/// always created at a generous floor size regardless of the source window's size, and
/// SCStreamConfiguration.sourceRect crops down to just the window's own rect within it.
final class CaptureSession: NSObject {
    /// .pip: window sits on the virtual display, panel shows a live mirror.
    /// .sourceActive: the source app is frontmost, so the window has been pulled back onto the
    /// physical screen where the user can actually see/use it (M3) — there's nothing useful to
    /// mirror while that's true, so the panel hides itself.
    enum PresentationState {
        case starting
        case pip
        case sourceActive
    }

    let windowInfo: WindowInfo
    weak var delegate: CaptureSessionDelegate?

    private(set) var virtualDisplayHost: VirtualDisplayHost?
    private(set) var virtualDisplayLease: VirtualDisplayPool.Lease?
    private(set) var originalFrame: CGRect?
    private(set) var axWindow: AXUIElement?
    private(set) var framedRect: CGRect = .zero
    private(set) var presentationState: PresentationState = .starting
    /// The size the window should be placed at on the virtual display — starts equal to
    /// originalFrame.size but diverges once resizeSourceWindow (PiP-panel edge-drag resize) is
    /// used. Deliberately kept separate from originalFrame: enterPiPState/
    /// reanchorAfterDisplayReconfiguration re-place the window using this, so a size the user
    /// picked via PiP resizing survives round-trips through M3's source-active state, while
    /// restoreWindowIfNeeded (stop/enterSourceActiveState — putting the window back on the real
    /// screen) still uses originalFrame, the true pre-session size.
    private var currentPiPSize: CGSize = .zero
    /// Depth-1 coalescing queue for resizeSourceWindow — see its doc comment.
    private var isResizingSourceWindow = false
    private var pendingResizeSize: CGSize?
    /// Set once commitSourceWindowSize observes the source app refusing to shrink some axis
    /// further — from then on, applyPanelResize stops asking that axis to go below this (see its
    /// doc comment for why), rather than repeating a request already known to be pointless.
    /// Tracked per axis, not as a single CGSize: a request that only tests height (because width
    /// happened to already be at a value satisfying its own, separately-discovered floor) must
    /// never be allowed to overwrite what's already known about width just because both numbers
    /// arrive bundled together in one AXUIElement frame read — each axis's constraint is
    /// independent and should only ever be tightened by evidence about that same axis.
    private var discoveredMinWidth: CGFloat?
    private var discoveredMinHeight: CGFloat?
    /// Fires (on the main actor) whenever discoveredMinWidth/discoveredMinHeight is (re-)
    /// established — PiPPanelController uses this to switch the mirror to a pure visual scale (no
    /// more source resize attempts) once the panel is dragged smaller than this. An axis not yet
    /// discovered is reported as 0 (never fails a "size < floor" comparison since sizes are always
    /// positive), so a fresh discovery on one axis doesn't imply anything false about the other.
    /// See commitSourceWindowSize's doc comment for the full story.
    var onSourceMinSizeDiscovered: ((CGSize) -> Void)?
    /// The mirror image of discoveredMinWidth/discoveredMinHeight: some apps also refuse to *grow*
    /// past some size on a given axis (e.g. a settings/preferences-style window deliberately
    /// capped at a comfortable reading width) — same per-axis independence rationale as the floor.
    private var discoveredMaxWidth: CGFloat?
    private var discoveredMaxHeight: CGFloat?
    /// Fires (on the main actor) whenever discoveredMaxWidth/discoveredMaxHeight is (re-)
    /// established — PiPPanelController uses this the same way as onSourceMinSizeDiscovered, just
    /// for the panel growing past what the source will follow rather than shrinking below it. An
    /// axis not yet discovered is reported as .infinity (never fails a "size > ceiling" comparison).
    var onSourceMaxSizeDiscovered: ((CGSize) -> Void)?
    /// Holds a floor/ceiling candidate for one axis that looked like "the source refused to go
    /// further" on its *most recent* commit, but hasn't yet been confirmed by enough independent
    /// samples — see commitSourceWindowSize's doc comment for why a single sample isn't trustworthy
    /// enough to commit to discoveredMin/MaxWidth/Height directly. Cleared back to nil the moment a
    /// commit shows real progress on that axis instead, so a merely-slow app never accumulates a
    /// false confirmation across unrelated ticks.
    private var suspectedMinWidth: CGFloat?
    private var suspectedMinHeight: CGFloat?
    private var suspectedMaxWidth: CGFloat?
    private var suspectedMaxHeight: CGFloat?
    /// How many consecutive commits have to report the exact same suspected value on a given axis
    /// before commitSourceWindowSize actually commits to discoveredMin/MaxWidth/Height — paired
    /// 1:1 with suspectedMin/MaxWidth/Height above (reset to 0 wherever those are reset to nil).
    /// Confirmed via /tmp/pipanel_trace.log against a real regression: 2 samples (the previous
    /// threshold) turned out not to be a strong enough signal at this app's own resize cadence —
    /// a terminal genuinely still catching up from a large jump (real growth 1105→1210→1238 pt
    /// across three commits) then happened to read the *same* 1238 on the very next two commits,
    /// only ~80-160ms apart, purely because it hadn't finished settling yet — not because it had
    /// actually hit a hard limit. That got "CONFIRMED" as a permanent ceiling almost instantly,
    /// after which nothing about this app's own careful re-test-nothing-once-discovered design (see
    /// commitSourceWindowSize's own doc comment) ever revisits it, so every later drag stayed
    /// wrongly pinned there for the rest of the session regardless of how far the panel kept
    /// growing. 3 total consistent samples is a meaningfully stronger signal a genuinely-capped app
    /// still clears easily (identical actual size call after call), while giving a slow-but-uncapped
    /// app one more ~80-150ms tick to show visible progress and clear the suspicion first.
    private static let boundConfirmationStreak = 3
    private var suspectedMinWidthStreak = 0
    private var suspectedMinHeightStreak = 0
    private var suspectedMaxWidthStreak = 0
    private var suspectedMaxHeightStreak = 0
    /// The target size actually sent to the previous commitSourceWindowSize call — distinct from
    /// framedRect.size (the previous *actual*, already read as previousActual below). Needed
    /// because a discovered-bound streak isn't valid evidence unless each sample represents a
    /// genuinely *new, escalated* ask, not the same request repeated. That repeat case is common
    /// and easy to trigger: once resizeSourceWindow's panel-space input pins at panel.minSize (or
    /// panel.maxSize) on one axis while the user keeps jiggling the mouse on the other, the scaled
    /// sourceTargetSize on the pinned axis becomes a *constant* value tick after tick even though
    /// nothing new is being tested. Confirmed via /tmp/pipanel_trace.log against a real regression:
    /// a panel dragged down to its 160pt minWidth, combined with a ~3.24x panelToSourceScale,
    /// repeatedly asked for the identical ~519.27pt source width; the app's own pixel/character-
    /// grid rounding snapped that to a fixed 517pt every single time, and 3 identical "actual"
    /// readings in a row (of a target that itself never changed) satisfied boundConfirmationStreak
    /// and got wrongly locked in as a permanent ceiling — even though the app was never actually
    /// asked to grow any further than that one static value.
    private var previousTargetSize: CGSize = .zero

    /// The ratio between the source window's own point-space and the PiP panel's — a single,
    /// uniform scalar (not independent per axis), established from the very first PiP-panel
    /// resize request of the session and held fixed afterward. See resizeSourceWindow's doc
    /// comment for why this exists and why it's one shared number rather than separate
    /// width/height factors; PiPPanelController.updateContentScalingMode reads it too, to compare
    /// the panel's size against discoveredSourceMinSize/MaxSize (both in source-space) on the same
    /// footing.
    private(set) var panelToSourceScale: CGFloat?

    /// Set by InteractionForwarder right before it activates the source app just to deliver a
    /// forwarded click/keystroke — PiPSessionManager consumes (and clears) this to tell that
    /// apart from the user genuinely switching to the app (Cmd+Tab, Dock, "jump to source"), so
    /// operating the PiP thumbnail doesn't itself yank the window onto the physical screen and
    /// hide the panel (M3's transition is for real switches only).
    var suppressNextActivationTransition = false

    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "com.pipanel.mac.capture.sampleQueue")
    private var lastFrameDate = Date()
    private var stallTimer: DispatchSourceTimer?
    /// Keeps the crop in sync with the window's live frame for as long as the session is
    /// presenting in PiP — see startFrameWatch.
    private var frameWatchTimer: Timer?
    /// See observeScreenParameterChanges/reanchorAfterDisplayReconfiguration.
    private var screenParamsObserver: NSObjectProtocol?
    private var isReanchoring = false
    /// Invalidates an ordinary notification-queued re-anchor when a sibling startup has already
    /// corrected this session synchronously while holding the topology lock. Without a generation
    /// token the stale queued task would run again after startup and could act on a later layout.
    private var reanchorTaskGeneration = 0
    /// Set before stop() waits for the topology coordinator. A queued re-anchor captures its host
    /// strongly, so checking only `virtualDisplayHost != nil` before queuing is insufficient: stop
    /// may tear that display down while the re-anchor is waiting, after which the stale task would
    /// otherwise move the source window back toward a display that no longer exists.
    private var isStopping = false

    var targetFPS: Int = 15 {
        didSet { Task { try? await applyConfiguration() } }
    }
    /// Refresh ceiling of the physical display that contained the source window when PiP was
    /// created. The global setting may follow a faster monitor, but a session that came from a
    /// 60 Hz screen should not ask ScreenCaptureKit for frames that display cannot produce.
    var sourceDisplayMaximumFPS: Int = DisplayRefreshRate.fallbackFPS {
        didSet { Task { try? await applyConfiguration() } }
    }

    private var effectiveTargetFPS: Int {
        Self.effectiveFrameRate(requested: targetFPS, displayMaximum: sourceDisplayMaximumFPS)
    }

    static func effectiveFrameRate(requested: Int, displayMaximum: Int) -> Int {
        min(max(requested, 1), max(displayMaximum, 1))
    }
    /// Per-session source-workspace ceiling. Changing it only resizes/moves this session's source
    /// inside the shared canvas workspace; it never reapplies the CGVirtualDisplay mode, so a
    /// settings-slider drag cannot trigger a WindowServer display reconfiguration or screen flash.
    var virtualDisplayLongEdge: CGFloat = CGFloat(VirtualDisplayHost.maxPixelsWide) {
        didSet {
            guard virtualDisplayHost != nil, oldValue != virtualDisplayLongEdge else { return }
            // Depth-1 coalescing queue, same pattern and same reason as resizeSourceWindow's own:
            // a slider drag fires this every tick, each a real IPC round-trip to the window
            // server, so this always chases the latest requested value instead of piling up a
            // backlog of stale in-flight resizes.
            pendingVirtualDisplayLongEdge = virtualDisplayLongEdge
            guard !isResizingVirtualDisplay else { return }
            isResizingVirtualDisplay = true
            Task {
                while let longEdge = pendingVirtualDisplayLongEdge {
                    pendingVirtualDisplayLongEdge = nil
                    await applyWorkspaceResolutionLimit(longEdge: longEdge)
                }
                isResizingVirtualDisplay = false
            }
        }
    }
    private var isResizingVirtualDisplay = false
    private var pendingVirtualDisplayLongEdge: CGFloat?
    /// Fires (on the main actor) once the initial virtual display is ready and after any live
    /// virtualDisplayLongEdge resize succeeds — PiPPanelController uses this to refresh
    /// panel.maxSize from the real coordinate-space deliverableMaxSize. Distinct from
    /// onSourceMinSizeDiscovered/onSourceMaxSizeDiscovered:
    /// those only ever *tighten* panel.maxSize (an app-imposed bound can't un-discover itself),
    /// but this is the one case where the ceiling can legitimately go back up.
    var onDeliverableSizeChanged: (() -> Void)?

    private func applyWorkspaceResolutionLimit(longEdge _: CGFloat) async {
        guard let host = virtualDisplayHost, let lease = virtualDisplayLease else { return }
        await VirtualDisplayCoordinator.shared.lock()
        guard !isStopping, virtualDisplayHost === host,
              virtualDisplayLease?.layerID == lease.layerID else {
            await VirtualDisplayCoordinator.shared.unlock()
            return
        }
        if presentationState == .pip, let axWindow {
            let capacity = effectiveWorkspaceFrame(for: lease).size
            let fitted = SharedVirtualCanvasLayout.sizeFitting(currentPiPSize, within: capacity)
            if fitted != .zero, fitted != currentPiPSize {
                currentPiPSize = fitted
                try? await moveWindowOntoVirtualDisplay(host: host, axWindow: axWindow, size: fitted)
            }
        }
        try? await applyConfiguration()
        await VirtualDisplayCoordinator.shared.unlock()

        let reportChange = onDeliverableSizeChanged
        await MainActor.run { reportChange?() }
    }

    /// SCStreamConfiguration's output pixel long edge (makeConfiguration's maxLongEdge) — unlike
    /// virtualDisplayLongEdge above, this is just a stream config field, so it applies live to an
    /// already-running session the same way targetFPS does.
    var maxOutputLongEdge: CGFloat = 1280 {
        didSet { Task { try? await applyConfiguration() } }
    }

    init(windowInfo: WindowInfo) {
        self.windowInfo = windowInfo
    }

    /// Empty space reserved on the virtual display around the window on the left/right/bottom
    /// (the top already gets VirtualDisplayHost.menuBarInset). Without this, a window placed
    /// flush against the virtual display's own edge has nowhere for the real cursor to actually
    /// go once it reaches that edge — CGWarpMouseCursorPosition just clamps it at the display
    /// boundary, so InteractionForwarder's fracX/fracYFromTop never crosses past 0/1 and cursor
    /// capture's edge-exit is never detected on that side (observed: left edge exit silently did
    /// nothing, since the pre-fix window sat at x = bounds.origin.x with zero left margin, while
    /// top/right/bottom happened to have incidental slack from the 44pt top inset and the 1280x800
    /// size floor).
    ///
    /// Not private: PiPPanelController reads this (alongside VirtualDisplayHost's own constants)
    /// to cap the PiP panel's own resizability at exactly what clampToDeliverableSize below can
    /// actually deliver — see panel.maxSize's doc comment for why that matters.
    static let edgeMargin: CGFloat = 40

    func start() async throws {
        // Serialized: see VirtualDisplayCoordinator for why concurrent session startups aren't safe.
        await VirtualDisplayCoordinator.shared.lock()
        defer { Task { await VirtualDisplayCoordinator.shared.unlock() } }

        guard let axWindow = AXWindowLocator.locate(windowInfo) else {
            throw CaptureSessionError.windowNotAccessible
        }
        self.axWindow = axWindow
        let originalFrame = AXWindowLocator.frame(of: axWindow) ?? windowInfo.frame
        self.originalFrame = originalFrame
        guard let pooledLease = await MainActor.run(body: { VirtualDisplayPool.shared.lease() }) else {
            throw CaptureSessionError.virtualDisplayCreationFailed
        }
        let host = pooledLease.host
        virtualDisplayLease = pooledLease
        virtualDisplayHost = host
        _ = try await Self.waitForValidBounds(of: host, positionNewDisplay: false)
        currentPiPSize = SharedVirtualCanvasLayout.sizeFitting(
            originalFrame.size,
            within: effectiveWorkspaceFrame(for: pooledLease).size
        )

        try await moveWindowOntoVirtualDisplay(
            host: host,
            axWindow: axWindow,
            size: currentPiPSize,
            positionNewDisplay: false
        )

        let scDisplay = try await Self.waitForShareableDisplay(matching: host.displayID)

        // Window-only filtering is the hard isolation boundary for a shared desktop: even if an
        // application temporarily moves outside the shared workspace, another session's source is never
        // eligible to appear in this stream.
        let filter = SCContentFilter(display: scDisplay, including: [windowInfo.scWindow])
        let config = Self.makeConfiguration(
            for: framedRect,
            displaySize: host.bounds.size,
            displayPixelScale: host.pixelsPerPoint,
            fps: effectiveTargetFPS,
            maxLongEdge: maxOutputLongEdge
        )

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
        presentationState = .pip
        observeScreenParameterChanges()
        startFrameWatch(axWindow: axWindow, host: host)
        startStallWatchdog()
        // panel.maxSize is created before this host exists and can only use the raw slider pixel
        // value. Now that the display has registered and its pixel→point scale is calibrated,
        // publish the real coordinate-space limit. This is what makes a non-default resolution
        // selected before opening a PiP take effect immediately, not only after the slider moves
        // again or the user happens to drag a panel edge.
        let reportInitialDeliverableSize = onDeliverableSizeChanged
        await MainActor.run { reportInitialDeliverableSize?() }
        PiPanelLogger.capture.info("Capture started for window \(self.windowInfo.id) (\(self.windowInfo.ownerAppName)) via virtual display \(host.displayID)")
    }

    /// The portion of the shared workspace currently made available to this source window. The
    /// canvas never changes mode; the user's resolution setting only expands/contracts this local
    /// region from the workspace's top-left corner.
    private func effectiveWorkspaceFrame(for lease: VirtualDisplayPool.Lease) -> CGRect {
        let selectedPixels = VirtualDisplayHost.pixelSize(forLongEdge: virtualDisplayLongEdge)
        let pointsPerPixel = CGSize(
            width: lease.host.pixelsPerPoint.width > 0 ? 1 / lease.host.pixelsPerPoint.width : 1,
            height: lease.host.pixelsPerPoint.height > 0 ? 1 / lease.host.pixelsPerPoint.height : 1
        )
        let selectedSize = VirtualDisplayHost.coordinateSize(
            pixelSize: CGSize(width: selectedPixels.width, height: selectedPixels.height),
            pointsPerPixel: pointsPerPixel
        )
        return CGRect(
            origin: lease.workspaceFrame.origin,
            size: CGSize(
                width: min(lease.workspaceFrame.width, selectedSize.width),
                height: min(lease.workspaceFrame.height, selectedSize.height)
            )
        )
    }

    /// Moves the window onto the virtual display and updates framedRect to match its real
    /// resulting position — shared by start() and enterPiPState() (M3's resume-after-switch-away).
    ///
    /// Tried full-screening the window on the virtual display here (AXFullScreen) instead of
    /// placing it at its own size, on the theory that "full screen" unambiguously means "fills
    /// the display" and would sidestep waitForFrameToSettle's whole reason for existing. Reverted:
    /// the AXFullScreen toggle was issued before the window had actually been repositioned onto
    /// the virtual display, so macOS full-screened it on whichever *real* screen it was still
    /// sitting on at that moment — visibly disrupting the user's actual desktop, which is exactly
    /// what this app exists to avoid. Back to plain windowed placement + waitForFrameToSettle.
    private func moveWindowOntoVirtualDisplay(
        host: VirtualDisplayHost,
        axWindow: AXUIElement,
        size: CGSize,
        positionNewDisplay: Bool = false
    ) async throws {
        guard let lease = virtualDisplayLease, lease.host === host else {
            throw CaptureSessionError.virtualDisplayCreationFailed
        }
        let bounds = try await Self.waitForValidBounds(
            of: host,
            positionNewDisplay: positionNewDisplay
        )

        let workspaceFrame = effectiveWorkspaceFrame(for: lease)
        let fittedSize = SharedVirtualCanvasLayout.sizeFitting(size, within: workspaceFrame.size)
        let targetOrigin = CGPoint(
            x: bounds.origin.x + workspaceFrame.origin.x,
            y: bounds.origin.y + workspaceFrame.origin.y
        )
        let targetFrame = CGRect(origin: targetOrigin, size: fittedSize)
        AXWindowLocator.setFrame(targetFrame, on: axWindow)

        let resultingFrame = await Self.waitForFrameToSettle(axWindow: axWindow, fallback: targetFrame)
        framedRect = CGRect(
            x: resultingFrame.origin.x - bounds.origin.x,
            y: resultingFrame.origin.y - bounds.origin.y,
            width: resultingFrame.width,
            height: resultingFrame.height
        )
    }

    /// Some apps don't immediately honor the exact frame AXWindowLocator.setFrame just requested
    /// — they reposition/resize themselves asynchronously in reaction to landing on a display
    /// (reflowing content to it, restoring a remembered zoomed state relative to it, etc.). A
    /// single fixed-delay read (the original approach: sleep 150ms, read once) could catch the
    /// frame mid-transition, locking framedRect's crop onto a rect the window then grows or
    /// shrinks out of — visible in the PiP mirror as black/empty space around the actual content
    /// instead of a tight crop. Polling until two consecutive reads agree (within a point, to
    /// tolerate float jitter) makes the crop match wherever the window actually settles, however
    /// long that takes for a given app, up to a generous cap before giving up and using whatever
    /// was last read.
    private static func waitForFrameToSettle(axWindow: AXUIElement, fallback: CGRect) async -> CGRect {
        var previous: CGRect?
        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let current = AXWindowLocator.frame(of: axWindow) else { continue }
            if let previous, isApproximatelyEqual(previous, current) {
                return current
            }
            previous = current
        }
        return previous ?? fallback
    }

    private static func isApproximatelyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.origin.x - b.origin.x) < 1 && abs(a.origin.y - b.origin.y) < 1
            && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }

    /// waitForFrameToSettle only guards the moment right after moveWindowOntoVirtualDisplay —
    /// some apps have been observed to shift again a moment *after* two reads already agreed
    /// (e.g. a second, later layout pass, or re-applying a remembered window position on top of
    /// wherever we just placed it), which reads as the content drifting off-center a second or so
    /// into a session that looked correctly framed initially. Polling continuously for as long as
    /// the session is presenting in PiP, and pushing an updated crop whenever the window's live
    /// frame actually differs from what's currently framed, keeps that from ever going stale
    /// instead of only checking once at the start.
    private func startFrameWatch(axWindow: AXUIElement, host: VirtualDisplayHost) {
        guard !isStopping else { return }
        frameWatchTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshFramedRectIfNeeded(axWindow: axWindow, host: host)
        }
        RunLoop.main.add(timer, forMode: .common)
        frameWatchTimer = timer
    }

    private func stopFrameWatch() {
        frameWatchTimer?.invalidate()
        frameWatchTimer = nil
    }

    private func refreshFramedRectIfNeeded(axWindow: AXUIElement, host: VirtualDisplayHost) {
        // A screen-change notification stops this timer immediately, but an already-enqueued timer
        // callback may still arrive. Never turn a transient topology position into a live stream
        // crop while the stabilized re-anchor is pending — that exact update is what let another
        // session's source window appear inside an older PiP in the trace.
        guard presentationState == .pip, !isReanchoring, !isStopping,
              let current = AXWindowLocator.frame(of: axWindow) else { return }
        let bounds = host.bounds
        let updated = CGRect(
            x: current.origin.x - bounds.origin.x,
            y: current.origin.y - bounds.origin.y,
            width: current.width,
            height: current.height
        )
        if let lease = virtualDisplayLease,
           !SharedVirtualCanvasLayout.ownsCenter(of: updated, workspaceFrame: lease.workspaceFrame) {
            debugTrace("vdisplay canvas: source escaped workspace windowID=\(windowInfo.id) layer=\(lease.layerID) localFrame=\(updated) workspace=\(lease.workspaceFrame)")
            queueReanchorIntoSharedWorkspace(reason: "workspace escape")
            return
        }
        guard !Self.isApproximatelyEqual(updated, framedRect) else { return }
        debugTrace("grow: refreshFramedRectIfNeeded correcting framedRect from=\(framedRect) to=\(updated) liveAXFrame=\(current)")
        framedRect = updated
        Task { try? await applyConfiguration() }
    }

    /// A real monitor change can still reflow the global desktop around the one persistent shared
    /// canvas. VirtualDisplayHost.bounds already reads that shift live,
    /// but the window itself isn't guaranteed to move in lockstep with its display through a
    /// reflow, so refreshFramedRectIfNeeded's crop math (live window frame − live display origin)
    /// can end up describing a region that no longer actually contains this session's window —
    /// Re-placing the window into the shared workspace against the display's *current* bounds after
    /// any screen-configuration change fixes that regardless of the exact way it drifted, since
    /// moveWindowOntoVirtualDisplay always re-derives both the placement and framedRect from
    /// scratch rather than trusting incremental deltas.
    private func observeScreenParameterChanges() {
        screenParamsObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.queueReanchorIntoSharedWorkspace(reason: "display reconfiguration")
        }
    }

    private func stopObservingScreenParameterChanges() {
        if let screenParamsObserver { NotificationCenter.default.removeObserver(screenParamsObserver) }
        screenParamsObserver = nil
    }

    private func queueReanchorIntoSharedWorkspace(reason: String) {
        guard presentationState == .pip, !isStopping,
              let host = virtualDisplayHost, let axWindow else { return }

        // Freeze the last known-good crop while the physical-display change settles.
        stopFrameWatch()
        guard !isReanchoring else { return }
        isReanchoring = true
        reanchorTaskGeneration &+= 1
        let generation = reanchorTaskGeneration
        debugTrace("vdisplay: reanchor queued reason=\(reason) windowID=\(windowInfo.id) displayID=\(host.displayID) liveFrame=\(AXWindowLocator.frame(of: axWindow) ?? .zero) displayBounds=\(host.bounds)")
        Task { [weak self] in
            guard let self else { return }

            // Waiting here converts a burst of intermediate screen-change notifications into one
            // correction against the final arrangement and serializes it with workspace moves.
            await VirtualDisplayCoordinator.shared.lock()
            guard self.reanchorTaskGeneration == generation,
                  !self.isStopping, self.presentationState == .pip,
                  self.virtualDisplayHost === host else {
                await VirtualDisplayCoordinator.shared.unlock()
                if self.reanchorTaskGeneration == generation {
                    self.isReanchoring = false
                }
                return
            }

            debugTrace("vdisplay: reanchor stabilized windowID=\(self.windowInfo.id) displayID=\(host.displayID) liveFrame=\(AXWindowLocator.frame(of: axWindow) ?? .zero) displayBounds=\(host.bounds)")
            do {
                try await self.moveWindowOntoVirtualDisplay(host: host, axWindow: axWindow, size: self.currentPiPSize)
                try await self.applyConfiguration()
            } catch {
                PiPanelLogger.capture.error("Failed to re-anchor window \(self.windowInfo.id) after display reconfiguration: \(error)")
            }
            await VirtualDisplayCoordinator.shared.unlock()
            guard self.reanchorTaskGeneration == generation else { return }
            self.isReanchoring = false

            if !self.isStopping, self.presentationState == .pip,
               self.virtualDisplayHost === host {
                self.startFrameWatch(axWindow: axWindow, host: host)
            }
        }
    }

    /// The source app just became frontmost (M3) — pull its window back onto the physical
    /// screen so the user can actually see/use it directly; there's nothing useful left for the
    /// PiP panel to mirror while that's true, so PiPSessionManager hides it in response.
    func enterSourceActiveState() {
        guard presentationState == .pip else { return }
        stopFrameWatch()
        restoreWindowIfNeeded()
        presentationState = .sourceActive
    }

    /// The user switched away from the source app again (M3) — move its window back onto the
    /// (still-alive) virtual display to resume the live PiP mirror, and retarget the running
    /// stream's crop at its new position.
    func enterPiPState() async {
        guard presentationState == .sourceActive,
              let host = virtualDisplayHost, let axWindow else { return }
        await VirtualDisplayCoordinator.shared.lock()
        guard !isStopping, presentationState == .sourceActive,
              virtualDisplayHost === host else {
            await VirtualDisplayCoordinator.shared.unlock()
            return
        }
        do {
            try await moveWindowOntoVirtualDisplay(host: host, axWindow: axWindow, size: currentPiPSize)
            if let stream {
                let config = Self.makeConfiguration(
                    for: framedRect,
                    displaySize: host.bounds.size,
                    displayPixelScale: host.pixelsPerPoint,
                    fps: effectiveTargetFPS,
                    maxLongEdge: maxOutputLongEdge
                )
                try await stream.updateConfiguration(config)
            }
            presentationState = .pip
            startFrameWatch(axWindow: axWindow, host: host)
        } catch {
            PiPanelLogger.capture.error("Failed to resume PiP for window \(self.windowInfo.id): \(error)")
        }
        await VirtualDisplayCoordinator.shared.unlock()
    }

    // MARK: - PiP-panel resize

    /// Entry point for a live PiP-panel resize (PiPVideoLayerView.didResizeTo) — called at
    /// UI-event frequency while the user is actively dragging a panel edge, not just once at the
    /// end, so the mirrored app visibly reflows in real time instead of only catching up once the
    /// drag ends.
    ///
    /// Each request below is a synchronous AX IPC round-trip to a different process (plus that
    /// process's own reflow), so calling straight through on every invocation would pile up a
    /// backlog of stale requests behind whichever one is currently in flight, making the drag lag
    /// further and further behind the cursor. Instead this only *records* the latest requested
    /// panel size and, if no request is currently running, starts a drain loop that keeps applying
    /// whatever the newest recorded size is until nothing's left queued — a depth-1 coalescing
    /// queue, so the source window is always chasing the panel's current size rather than working
    /// through every intermediate size it passed through on the way there.
    ///
    /// panelSize arrives in the PiP panel's own point-space, which is *not* the same as the
    /// source window's: the panel is created at a fixed default thumbnail width (PiPSessionManager
    /// .defaultPanelFrame — currently 340pt), entirely decoupled from however big the real source
    /// window actually is (e.g. a 1400x900 window still gets an ~340x218 panel). That's fine for
    /// just *displaying* the mirror — the video layer scales the picture to fit whatever the
    /// panel's bounds are — but forwarding panelSize straight through as the source window's resize
    /// target isn't: the moment any edge-drag fired, the real window was instantly commanded to
    /// collapse (or balloon) to the panel's own absolute size, e.g. a 1400x900 window snapping down
    /// to ~340x218 on the very first drag tick, rather than scaling proportionally the way the
    /// panel is only ever meant to be a shrunk-down mirror of the source.
    ///
    /// panelToSourceScale fixes that: established once, from this method's very first call in the
    /// session, as a single *uniform* scalar (area ratio, i.e. currentPiPSize's area over
    /// panelSize's area, square-rooted back down to a linear factor) rather than independent
    /// width/height ratios — then held fixed for the rest of the session. Every subsequent
    /// panelSize this method receives has both axes multiplied by that same one number before
    /// anything downstream ever sees it, so growing/shrinking the panel scales the source
    /// proportionally (matching the porthole relationship the user already sees visually) instead
    /// of snapping it to the panel's own absolute size.
    ///
    /// Independent per-axis factors (currentPiPSize.width/panelSize.width and the height
    /// equivalent) were tried first and reverted: they only *approximately* tracked the panel's
    /// current aspect ratio, matching exactly only insofar as the two factors happened to be
    /// nearly equal (true right at the moment they're established, since defaultPanelFrame gives
    /// the panel the same aspect as the window — but not guaranteed to stay that way, and not
    /// remotely true once either axis starts getting clamped independently by
    /// clampedToKnownFloor/Ceiling or clampToDeliverableSize below). In practice that read as the
    /// source staying locked near whatever aspect ratio it started with, no matter how the panel's
    /// own shape was dragged. A single shared scalar guarantees the source's aspect ratio always
    /// exactly matches the panel's *current* one instead, by construction: since both axes are
    /// multiplied by the same number, (panelWidth*scale)/(panelHeight*scale) always reduces to
    /// panelWidth/panelHeight, with zero drift regardless of how far the panel's shape diverges
    /// from where it started — up to the hard physical ceiling of what the virtual display can
    /// actually deliver, at which point the mismatch is exactly what updateContentScalingMode's
    /// letterboxing exists to absorb.
    func resizeSourceWindow(to panelSize: CGSize) {
        let scale = panelToSourceScale ?? {
            let panelArea = panelSize.width * panelSize.height
            let sourceArea = currentPiPSize.width * currentPiPSize.height
            let established: CGFloat = panelArea > 0 ? (sourceArea / panelArea).squareRoot() : 1
            debugTrace("grow: established panelToSourceScale=\(established) from currentPiPSize=\(currentPiPSize) panelSize=\(panelSize)")
            panelToSourceScale = established
            return established
        }()
        let sourceTargetSize = CGSize(width: panelSize.width * scale, height: panelSize.height * scale)

        pendingResizeSize = sourceTargetSize
        guard !isResizingSourceWindow else { return }
        isResizingSourceWindow = true
        Task {
            while let size = pendingResizeSize {
                pendingResizeSize = nil
                await applyPanelResize(to: size)
            }
            isResizingSourceWindow = false
        }
    }

    /// The three-step pipeline for one resize request:
    ///  1. clamp the panel's target size down to whatever the virtual display can actually back
    ///     (clampToDeliverableSize) — the display can't grow to follow an oversized request.
    ///  2. resize the real source window to that target (commitSourceWindowSize) and get back
    ///     whatever frame it actually settled on, which isn't guaranteed to be the target exactly.
    ///  3. update the capture region — framedRect, and therefore the stream's crop — from that
    ///     *actual* resulting frame, not the requested target (syncCaptureRegion).
    ///
    /// Step 3 is what keeps the mirror honest: some apps silently override a request that doesn't
    /// preserve their own locked aspect ratio (common in media/image viewers) or otherwise don't
    /// honor an arbitrary width/height independently (grid/character-cell snapping, separate
    /// min-width/min-height constraints). Deriving the crop from the real result rather than
    /// trusting the request means the mirror always matches whatever the source window actually
    /// is, on every single resize step, rather than drifting until the next frameWatchTimer poll
    /// (startFrameWatch) catches up to it up to 0.5s later.
    ///
    /// Skips all three steps once panelSize is smaller than each axis's own previously-discovered
    /// floor (discoveredMinWidth/discoveredMinHeight) in *both* dimensions at once — that
    /// combination is already known to be pointless (the source app rejected it last time), so
    /// there's no reason to keep asking. The source window, and
    /// therefore framedRect/the stream's crop, both just stay exactly as they already are;
    /// PiPPanelController separately reacts to being below the same threshold by switching
    /// PiPVideoLayerView to a pure visual scale-down instead (see
    /// PiPVideoLayerView.ContentScalingMode) rather than this doing anything on the capture side.
    ///
    /// If only *one* dimension is below the floor (e.g. dragging diagonally back out crosses the
    /// width floor before the height floor), that dimension is pinned at the floor instead
    /// (clampedToKnownFloor) rather than the whole request being skipped — skipping outright here
    /// used to also block the *other* dimension, the one the source was perfectly willing to
    /// track, which is what made growing back out past the floor sometimes leave the source
    /// lagging behind the panel until both dimensions happened to clear it at once.
    private func applyPanelResize(to panelSize: CGSize) async {
        guard presentationState == .pip, !isReanchoring, !isStopping,
              let axWindow, let host = virtualDisplayHost,
              framedRect.width > 0, framedRect.height > 0 else {
            debugTrace("grow: applyPanelResize bailed panelSize=\(panelSize) presentationState=\(presentationState) framedRect=\(framedRect)")
            return
        }

        let widthFloor = discoveredMinWidth ?? 0
        let heightFloor = discoveredMinHeight ?? 0
        if panelSize.width < widthFloor && panelSize.height < heightFloor {
            debugTrace("grow: skipped (both below floor) panelSize=\(panelSize) widthFloor=\(widthFloor) heightFloor=\(heightFloor)")
            return
        }

        let bounds = host.bounds
        let flooredPanelSize = clampedToKnownFloor(panelSize)
        let boundedPanelSize = clampedToKnownCeiling(flooredPanelSize)
        let targetSize = clampToDeliverableSize(boundedPanelSize, within: bounds)
        debugTrace("grow: applyPanelResize panelSize=\(panelSize) boundedPanelSize=\(boundedPanelSize) targetSize=\(targetSize) framedRectBefore=\(framedRect) boundsOrigin=\(bounds.origin) boundsSize=\(bounds.size)")
        let actualFrame = await commitSourceWindowSize(targetSize, requestedSize: boundedPanelSize, axWindow: axWindow, displayOrigin: bounds.origin)
        syncCaptureRegion(to: actualFrame, displayOrigin: bounds.origin)
        debugTrace("grow: applyPanelResize done targetSize=\(targetSize) actualFrame=\(actualFrame) framedRectAfter=\(framedRect)")

        try? await applyConfiguration()
    }

    /// Caps any dimension that's individually above its own discovered ceiling there rather than
    /// asking the source to grow further on just that axis — the mirror image of
    /// clampedToKnownFloor, for the same reason: no point repeating a request already known to be
    /// pointless. A no-op on either axis until that axis has a ceiling discovered.
    private func clampedToKnownCeiling(_ size: CGSize) -> CGSize {
        CGSize(
            width: discoveredMaxWidth.map { min(size.width, $0) } ?? size.width,
            height: discoveredMaxHeight.map { min(size.height, $0) } ?? size.height
        )
    }

    /// Pins any dimension that's individually below its own discovered floor there rather than
    /// asking the source to shrink further on just that axis — the other dimension still tracks
    /// the panel normally. A no-op on either axis until that axis has its own floor discovered.
    private func clampedToKnownFloor(_ size: CGSize) -> CGSize {
        CGSize(width: max(size.width, discoveredMinWidth ?? 0), height: max(size.height, discoveredMinHeight ?? 0))
    }

    /// Step 1: caps the request at what the display can deliver. CaptureSession.start() always
    /// creates the display at VirtualDisplayHost's full maxPixelsWide/maxPixelsHigh ceiling
    /// specifically so this has room for any realistic PiP-panel size without needing to change
    /// the display's own resolution mid-session (see start()'s doc comment for why a live mode
    /// change was tried and abandoned) — PiPPanelController.panel.maxSize keeps the panel itself
    /// from even being draggable past this ceiling in the first place; this is the backend's own
    /// defense in depth against that same limit.
    ///
    /// Clamps *uniformly* (scaling both axes down by the same factor) rather than clamping width
    /// and height independently to maxWidth/maxHeight. Independent clamping was tried first and
    /// reverted: once the request exceeded the deliverable bounds on both axes at once (easy to
    /// reach — resizeSourceWindow's panelToSourceScale is routinely >2x, so a still-modest panel
    /// size already asks for something well past what a ~1200x716 virtual display can back), each
    /// axis got pinned independently at its own ceiling, and the result's aspect ratio collapsed
    /// to whatever the *display's own* fixed maxWidth:maxHeight ratio happens to be rather than
    /// the requested one — e.g. a request for (1893, 1572) — an aspect around 1.2 — coming back as
    /// (1200, 716), an aspect around 1.68, no matter how much further the panel kept changing
    /// shape from there. That's a real, app-independent ceiling (the virtual display's own fixed
    /// canvas), not something any app is refusing — so unlike a genuine app-imposed floor/ceiling,
    /// there's no reason the *shape* has to suffer for it: scaling the whole request down by
    /// whichever axis is tighter preserves the requested aspect ratio exactly, just at a smaller
    /// overall size, so the mirrored window keeps tracking the panel's current proportions even
    /// while pinned at the display's absolute capacity.
    private func clampToDeliverableSize(_ size: CGSize, within bounds: CGRect) -> CGSize {
        guard let lease = virtualDisplayLease else { return size }
        let workspace = effectiveWorkspaceFrame(for: lease)
        let maxWidth = max(workspace.maxX - framedRect.origin.x, 1)
        let maxHeight = max(workspace.maxY - framedRect.origin.y, 1)
        guard size.width > 0, size.height > 0, size.width > maxWidth || size.height > maxHeight else {
            return size
        }
        let scale = min(maxWidth / size.width, maxHeight / size.height)
        let clamped = CGSize(width: size.width * scale, height: size.height * scale)
        debugTrace("grow: clampToDeliverableSize CLAMPED requested=\(size) -> \(clamped) maxWidth=\(maxWidth) maxHeight=\(maxHeight) framedRectOrigin=\(framedRect.origin) boundsSize=\(bounds.size)")
        return clamped
    }

    /// The same ceiling clampToDeliverableSize enforces per-tick, exposed so PiPPanelController
    /// can correct panel.maxSize to match. panel.maxSize is set once, at panel-creation time,
    /// before the virtual display even exists yet — it has to assume VirtualDisplayHost's
    /// aspirational maxPixelsWide/maxPixelsHigh ceiling, since nothing more specific is known yet.
    ///
    /// The shared display has one fixed launch-time mode. The effective ceiling comes from this
    /// session's shared workspace plus its session-local resolution setting, so concurrent
    /// sessions cannot change one another's capacity.
    var deliverableMaxSize: CGSize? {
        guard virtualDisplayHost != nil, let lease = virtualDisplayLease,
              framedRect.width > 0 else { return nil }
        let workspace = effectiveWorkspaceFrame(for: lease)
        return CGSize(
            width: max(workspace.maxX - framedRect.origin.x, 1),
            height: max(workspace.maxY - framedRect.origin.y, 1)
        )
    }

    /// Step 2: resizes the real source window on the virtual display, keeping its top-left
    /// anchored where it already sits (framedRect's origin) — this is a resize, not a move, so
    /// only the size attribute is written (AXWindowLocator.setSize), not position.
    ///
    /// Reading the frame back immediately after the AX set call was found to reliably return the
    /// *pre*-resize frame — AX size requests are processed asynchronously by the target app (the
    /// same lesson moveWindowOntoVirtualDisplay's waitForFrameToSettle already accounts for once
    /// at session start), so a same-tick readback just observes "nothing happened yet." Combined
    /// with this running inside resizeSourceWindow's coalescing loop, that meant every drag tick
    /// sent a *new* size request before the app had even started applying the *previous* one —
    /// the app was perpetually interrupted mid-request and its real window never actually finished
    /// resizing at all, for the whole duration of any drag, no matter how long it continued.
    ///
    /// A short fixed pause between the set and the read gives the app room to actually land one
    /// request before the next is sent — cheap enough to run on every tick (unlike the multi-
    /// second settle budget used once at session start), at the cost of resize commits landing at
    /// roughly that cadence rather than on every individual mouseDragged event. The panel itself
    /// still tracks the cursor instantly (pure local AppKit); only the source window's catch-up
    /// rate is capped, and it now actually catches up instead of never moving at all.
    ///
    /// Many apps refuse to shrink below some minimum of their own (a multi-pane layout that can't
    /// fit its sidebar/list/detail columns any narrower, etc.) — no AX trick can force a window
    /// past a limit the app itself enforces. If the actual result came back bigger than what was
    /// asked for on a genuine shrink attempt on some axis, that axis's floor is talking: it's
    /// recorded in discoveredMinWidth/discoveredMinHeight — independently, per axis — so
    /// applyPanelResize stops asking *that axis* to shrink further, and reported via
    /// onSourceMinSizeDiscovered so PiPPanelController can switch the mirror to a pure visual
    /// scale below it instead of continuing to treat every drag tick as a resize attempt.
    ///
    /// Only ever raised, per axis, on evidence about that specific axis — a request whose width
    /// happens to land exactly on target (nothing new learned about width) must not overwrite an
    /// already-known width floor just because this same call also discovered something new about
    /// height; the two are tracked and updated completely independently.
    ///
    /// The ceiling side (discoveredMaxWidth/discoveredMaxHeight) needs a different signal than the
    /// floor does. A refused *shrink* is unambiguous: actual comes back bigger than target, full
    /// stop. A still-*growing* window is expected to often be behind target too (the settle wait
    /// is deliberately short — see above), so "actual < target" on its own is just normal catch-up
    /// lag, not evidence of a ceiling. What actually distinguishes a real ceiling is zero
    /// progress: comparing this call's actual against framedRect's size *before* this call (the
    /// previous commit's actual) — a window that's still capable of growing keeps inching toward
    /// an increasing target between calls, where one that's hit its ceiling reports back the exact
    /// same size call after call no matter how much bigger the target gets, which is exactly what
    /// was observed for System Settings' Accessibility pane (a settings-window-style app quietly
    /// capping its own width — the mirror image of Notes' minimum-width case).
    ///
    /// Neither signal is trusted off a single sample, though — a "no progress" read 80ms after the
    /// request is also exactly what a window with a longer (e.g. spring-animated, or reflowing a
    /// busy layout) resize looks like *while it's still mid-animation*, especially on the first tick
    /// or two of a drag before anything's had a chance to warm up. Mistaking that for a hard
    /// refusal was observed to permanently cap the mirror near the window's *starting* size for
    /// apps that have no real min/max at all — nothing else ever re-tests a discovered bound once
    /// applyPanelResize starts clamping to it. Requiring the same signal on boundConfirmationStreak
    /// *consecutive* commits (suspectedMin/MaxWidth/Height + their own streak counters) before
    /// actually committing to a discovered bound filters that out: a genuinely capped app reports
    /// the identical actual size call after call, so a short streak is still definitive, while a
    /// merely-slow app usually shows visible progress within a tick or two (each lands ~80-150ms
    /// later, the same cadence as this call), clearing the suspicion before it's confirmed. Was
    /// originally just 2 in a row — see boundConfirmationStreak's own doc comment for the real
    /// false-positive that turned out not to be a strong enough signal in practice.
    ///
    /// requestedSize is what applyPanelResize actually wanted for this axis *before*
    /// clampToDeliverableSize possibly scaled it down to fit the virtual display's own fixed
    /// capacity — targetSize is what was actually sent to the app. The two differ exactly when the
    /// display's capacity, not anything about the app, is what's limiting this request. That case
    /// has to be excluded from floor/ceiling detection on the affected axis, not just tolerated:
    /// when clampToDeliverableSize shrinks a request to, say, 1200 on an axis whose window is
    /// currently sitting at 1203 (a 3pt difference — nothing was actually being asked to shrink in
    /// any meaningful sense), the app's unchanged actual naturally reads as "bigger than target",
    /// which used to get confirmed as a genuine app floor at ~1203. Since that's *above* the
    /// display's own maxWidth (1200), clampedToKnownFloor and clampToDeliverableSize would then
    /// fight each other forever afterward — the floor demanding at least 1203, the display capping
    /// at 1200 — freezing that axis at ~1200-1203 for the rest of the session regardless of
    /// anything the panel does from then on, which is exactly what broke aspect tracking once the
    /// panel grew large enough to hit the display's capacity. Skipping discovery entirely on an
    /// axis (and clearing any pending suspicion on it) whenever the display's own clamp — not the
    /// app — is why requestedSize and targetSize differ avoids ever manufacturing a floor/ceiling
    /// out of our own conservative request instead of the app's real behavior.
    private func commitSourceWindowSize(_ targetSize: CGSize, requestedSize: CGSize, axWindow: AXUIElement, displayOrigin: CGPoint) async -> CGRect {
        let previousActual = framedRect.size
        let absoluteOrigin = CGPoint(x: displayOrigin.x + framedRect.origin.x, y: displayOrigin.y + framedRect.origin.y)
        let requestedFrame = CGRect(origin: absoluteOrigin, size: targetSize)
        AXWindowLocator.setSize(targetSize, on: axWindow)
        try? await Task.sleep(nanoseconds: 80_000_000)
        let actualFrame = AXWindowLocator.frame(of: axWindow) ?? requestedFrame
        debugTrace("grow: commitSourceWindowSize target=\(targetSize) actual=\(actualFrame.size) previousActual=\(previousActual) axWindowFrameReadOK=\(AXWindowLocator.frame(of: axWindow) != nil)")

        let tolerance: CGFloat = 1
        let widthWasDisplayClamped = targetSize.width < requestedSize.width - tolerance
        let heightWasDisplayClamped = targetSize.height < requestedSize.height - tolerance
        // A sample only counts as evidence toward a discovered bound if this tick's target is
        // itself genuinely more extreme than the *previous tick's target* — not just bigger/
        // smaller than wherever the window happens to already sit (previousActual). Without this,
        // a static, unchanging target repeated tick after tick (e.g. resizeSourceWindow's scaled
        // output pinned constant because the panel itself is sitting at its own minSize/maxSize
        // while the user keeps moving the mouse on the *other* axis) trivially satisfies "target
        // exceeds previousActual" forever once the app's own pixel/character-grid rounding first
        // snaps actual to some nearby value — see previousTargetSize's own doc comment for the
        // real regression this was confirmed against.
        let isFreshWidthShrinkProbe = targetSize.width < previousTargetSize.width - tolerance
        let isFreshHeightShrinkProbe = targetSize.height < previousTargetSize.height - tolerance
        let isFreshWidthGrowProbe = targetSize.width > previousTargetSize.width + tolerance
        let isFreshHeightGrowProbe = targetSize.height > previousTargetSize.height + tolerance

        var discoveredFloor = false
        if widthWasDisplayClamped {
            suspectedMinWidth = nil
            suspectedMinWidthStreak = 0
        } else if !isFreshWidthShrinkProbe {
            // Same (or bigger) request repeated — no new evidence either way this tick; leave any
            // existing suspicion exactly as it was rather than resetting or advancing it.
        } else if actualFrame.width > targetSize.width + tolerance {
            if let suspected = suspectedMinWidth, abs(suspected - actualFrame.width) < tolerance {
                suspectedMinWidthStreak += 1
                if suspectedMinWidthStreak >= Self.boundConfirmationStreak {
                    debugTrace("grow: CONFIRMED WIDTH floor actual=\(actualFrame.width) target=\(targetSize.width)")
                    discoveredMinWidth = actualFrame.width
                    discoveredFloor = true
                } else {
                    debugTrace("grow: suspected WIDTH floor actual=\(actualFrame.width) target=\(targetSize.width) streak=\(suspectedMinWidthStreak) (awaiting confirmation)")
                }
            } else {
                suspectedMinWidth = actualFrame.width
                suspectedMinWidthStreak = 1
                debugTrace("grow: suspected WIDTH floor actual=\(actualFrame.width) target=\(targetSize.width) streak=1 (awaiting confirmation)")
            }
        } else {
            suspectedMinWidth = nil
            suspectedMinWidthStreak = 0
        }
        if heightWasDisplayClamped {
            suspectedMinHeight = nil
            suspectedMinHeightStreak = 0
        } else if !isFreshHeightShrinkProbe {
            // See the width branch above.
        } else if actualFrame.height > targetSize.height + tolerance {
            if let suspected = suspectedMinHeight, abs(suspected - actualFrame.height) < tolerance {
                suspectedMinHeightStreak += 1
                if suspectedMinHeightStreak >= Self.boundConfirmationStreak {
                    debugTrace("grow: CONFIRMED HEIGHT floor actual=\(actualFrame.height) target=\(targetSize.height)")
                    discoveredMinHeight = actualFrame.height
                    discoveredFloor = true
                } else {
                    debugTrace("grow: suspected HEIGHT floor actual=\(actualFrame.height) target=\(targetSize.height) streak=\(suspectedMinHeightStreak) (awaiting confirmation)")
                }
            } else {
                suspectedMinHeight = actualFrame.height
                suspectedMinHeightStreak = 1
                debugTrace("grow: suspected HEIGHT floor actual=\(actualFrame.height) target=\(targetSize.height) streak=1 (awaiting confirmation)")
            }
        } else {
            suspectedMinHeight = nil
            suspectedMinHeightStreak = 0
        }
        if discoveredFloor {
            let discovered = CGSize(width: discoveredMinWidth ?? 0, height: discoveredMinHeight ?? 0)
            let reportDiscovery = onSourceMinSizeDiscovered
            Task { @MainActor in reportDiscovery?(discovered) }
        }

        var discoveredCeiling = false
        if widthWasDisplayClamped {
            suspectedMaxWidth = nil
            suspectedMaxWidthStreak = 0
        } else if !isFreshWidthGrowProbe {
            // Same (or smaller) request repeated — see the floor branch above for why this isn't
            // treated as either confirming or clearing progress.
        } else if targetSize.width > previousActual.width + tolerance, abs(actualFrame.width - previousActual.width) < tolerance {
            if let suspected = suspectedMaxWidth, abs(suspected - actualFrame.width) < tolerance {
                suspectedMaxWidthStreak += 1
                if suspectedMaxWidthStreak >= Self.boundConfirmationStreak {
                    debugTrace("grow: CONFIRMED WIDTH ceiling actual=\(actualFrame.width) target=\(targetSize.width)")
                    discoveredMaxWidth = actualFrame.width
                    discoveredCeiling = true
                } else {
                    debugTrace("grow: suspected WIDTH ceiling actual=\(actualFrame.width) target=\(targetSize.width) streak=\(suspectedMaxWidthStreak) (awaiting confirmation)")
                }
            } else {
                suspectedMaxWidth = actualFrame.width
                suspectedMaxWidthStreak = 1
                debugTrace("grow: suspected WIDTH ceiling actual=\(actualFrame.width) target=\(targetSize.width) streak=1 (awaiting confirmation)")
            }
        } else {
            suspectedMaxWidth = nil
            suspectedMaxWidthStreak = 0
        }
        if heightWasDisplayClamped {
            suspectedMaxHeight = nil
            suspectedMaxHeightStreak = 0
        } else if !isFreshHeightGrowProbe {
            // See the width branch above.
        } else if targetSize.height > previousActual.height + tolerance, abs(actualFrame.height - previousActual.height) < tolerance {
            if let suspected = suspectedMaxHeight, abs(suspected - actualFrame.height) < tolerance {
                suspectedMaxHeightStreak += 1
                if suspectedMaxHeightStreak >= Self.boundConfirmationStreak {
                    debugTrace("grow: CONFIRMED HEIGHT ceiling actual=\(actualFrame.height) target=\(targetSize.height)")
                    discoveredMaxHeight = actualFrame.height
                    discoveredCeiling = true
                } else {
                    debugTrace("grow: suspected HEIGHT ceiling actual=\(actualFrame.height) target=\(targetSize.height) streak=\(suspectedMaxHeightStreak) (awaiting confirmation)")
                }
            } else {
                suspectedMaxHeight = actualFrame.height
                suspectedMaxHeightStreak = 1
                debugTrace("grow: suspected HEIGHT ceiling actual=\(actualFrame.height) target=\(targetSize.height) streak=1 (awaiting confirmation)")
            }
        } else {
            suspectedMaxHeight = nil
            suspectedMaxHeightStreak = 0
        }
        if discoveredCeiling {
            let discovered = CGSize(width: discoveredMaxWidth ?? .infinity, height: discoveredMaxHeight ?? .infinity)
            let reportDiscovery = onSourceMaxSizeDiscovered
            Task { @MainActor in reportDiscovery?(discovered) }
        }

        previousTargetSize = targetSize
        return actualFrame
    }

    /// Step 3: framedRect (consumed by makeConfiguration's sourceRect) and currentPiPSize (what
    /// future re-placements onto the display use — see its own doc comment) are both derived from
    /// the source window's actual resulting frame, never the requested target.
    private func syncCaptureRegion(to actualFrame: CGRect, displayOrigin: CGPoint) {
        framedRect = CGRect(
            x: actualFrame.origin.x - displayOrigin.x,
            y: actualFrame.origin.y - displayOrigin.y,
            width: actualFrame.width,
            height: actualFrame.height
        )
        currentPiPSize = actualFrame.size
    }

    /// CGVirtualDisplay's apply(settings:) returning true only means the settings were
    /// accepted — CGDisplayBounds can still read all-zero for a brief moment until the window
    /// server finishes registering the display's geometry. Polls host.isGeometryRegistered
    /// (a live CGDisplayBounds check) rather than host.bounds itself: bounds's size now always
    /// reflects VirtualDisplayHost's own tracked size (non-zero from the moment it's constructed —
    /// see its doc comment), so it can no longer be used to detect window-server readiness.
    private static func waitForValidBounds(
        of host: VirtualDisplayHost,
        positionNewDisplay: Bool
    ) async throws -> CGRect {
        for attempt in 0..<10 {
            if host.isGeometryRegistered {
                if positionNewDisplay {
                    // Only the initial placement may mutate the arrangement. Re-anchors call this
                    // helper too, but they must consume the now-stable bounds without producing a
                    // fresh screen-parameters notification for every already-open session.
                    // Positioning is only safe once registration is confirmed — see
                    // positionOutsideExistingDisplays's own doc comment.
                    await MainActor.run { host.positionOutsideExistingDisplays() }
                }
                return host.bounds
            }
            if attempt < 9 {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        throw CaptureSessionError.virtualDisplayCreationFailed
    }

    /// A newly-created virtual display was observed (Spikes/VirtualDisplaySpike) to take
    /// anywhere from under a second up to ~5s to propagate to this process's
    /// ScreenCaptureKit/AppKit view of the display list — retry with a generous budget rather
    /// than failing outright.
    private static func waitForShareableDisplay(matching displayID: CGDirectDisplayID) async throws -> SCDisplay {
        for attempt in 0..<20 {
            let content = try await SCShareableContent.current
            if let match = content.displays.first(where: { $0.displayID == displayID }) {
                return match
            }
            if attempt < 19 {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        throw CaptureSessionError.virtualDisplayNotVisibleToScreenCaptureKit
    }

    func stop() async {
        // Stop producing transient crop updates immediately, then wait until any in-flight display
        // creation/resize/re-anchor has completed before returning this host to the pool.
        isStopping = true
        stallTimer?.cancel()
        stallTimer = nil
        stopFrameWatch()
        stopObservingScreenParameterChanges()
        await VirtualDisplayCoordinator.shared.lock()
        if let stream {
            self.stream = nil
            try? await stream.stopCapture()
        }
        restoreWindowIfNeeded()
        // restoreWindowIfNeeded only *fires* the AX move back to the real screen — the target app
        // applies it asynchronously. Observe where it lands so the recovery log/guard knows
        // whether an unowned window remains on the shared canvas.
        var hostIsReusable = true
        if let axWindow, let originalFrame, let host = virtualDisplayHost {
            let settledFrame = await Self.waitForFrameToSettle(axWindow: axWindow, fallback: originalFrame)
            // A stale window cannot leak into another stream: each SCContentFilter includes only
            // its own source. The value still tells the pool/intrusion guard whether restoration
            // succeeded and is deliberately retained as a diagnostic signal.
            let overlap = settledFrame.intersection(host.bounds)
            let overlapArea = overlap.isNull ? 0 : overlap.width * overlap.height
            let windowArea = max(settledFrame.width * settledFrame.height, 1)
            hostIsReusable = overlapArea / windowArea < 0.5
        }
        let leaseBeingReleased = virtualDisplayLease
        virtualDisplayLease = nil
        virtualDisplayHost = nil
        if let leaseBeingReleased {
            let reusable = hostIsReusable
            await MainActor.run {
                VirtualDisplayPool.shared.release(leaseBeingReleased, reusable: reusable)
            }
        }
        await VirtualDisplayCoordinator.shared.unlock()
        PiPanelLogger.capture.info("Capture stopped for window \(self.windowInfo.id)")
    }

    /// Moves the source window back to its pre-session position — used both on session stop and
    /// by enterSourceActiveState() (M3), so it reappears on the user's real screen.
    func restoreWindowIfNeeded() {
        guard let axWindow, let originalFrame else { return }
        AXWindowLocator.setFrame(originalFrame, on: axWindow)
    }

    /// The source window's live on-screen frame (Quartz space), used by InteractionForwarder to
    /// map a PiP-panel click onto the window's actual current position on the virtual display.
    /// Re-queried live via AX rather than cached, in case the window resizes/moves on its own.
    func currentSourceWindowFrame() -> CGRect? {
        guard let axWindow else { return nil }
        return AXWindowLocator.frame(of: axWindow)
    }

    /// Identity check used by PiPSessionManager's virtual-display intrusion guard. Comparing the
    /// AX element itself (rather than PID/title) keeps a second window from the same application
    /// ineligible to remain on a PiPanel display.
    func ownsSourceWindow(_ candidate: AXUIElement) -> Bool {
        guard let axWindow else { return false }
        return CFEqual(axWindow, candidate)
    }

    private func applyConfiguration() async throws {
        guard let stream, let host = virtualDisplayHost else { return }
        let config = Self.makeConfiguration(
            for: framedRect,
            displaySize: host.bounds.size,
            displayPixelScale: host.pixelsPerPoint,
            fps: effectiveTargetFPS,
            maxLongEdge: maxOutputLongEdge
        )
        try await stream.updateConfiguration(config)
    }

    private static func makeConfiguration(
        for localRect: CGRect,
        displaySize: CGSize,
        displayPixelScale: CGSize,
        fps: Int,
        maxLongEdge: CGFloat
    ) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(fps, 1)))
        config.queueDepth = 5

        // Crop to just the window's rect within the virtual display, so the surrounding
        // wallpaper/menu bar that every display (real or virtual) renders doesn't show up. Inset
        // a few points past that: macOS gives every window (even this app's own panel) a small
        // native corner radius at the window-server level, but localRect is the window's plain
        // rectangular AX frame with no awareness of that rounding — the crop was landing right up
        // against the true edge, so each corner's few rounded-away pixels showed through as a
        // small black (or wallpaper-colored) triangle. Only became visible once PiP-panel resizing
        // started actually reaching the real window size (previously the resize never landed at
        // all, so the crop was always relative to whatever the window's original, unmoved rect
        // was). A fixed inset crops a sliver of genuine content on all four edges, not just the
        // corners, but that's a far smaller cosmetic cost than a black corner.
        let cornerRadiusInset: CGFloat = 6
        let insetRect = localRect.insetBy(dx: cornerRadiusInset, dy: cornerRadiusInset)
        let clamped = insetRect.intersection(CGRect(origin: .zero, size: displaySize))
        let sourceRect = clamped.isEmpty ? CGRect(origin: .zero, size: displaySize) : clamped
        config.sourceRect = sourceRect

        let outputSize = outputPixelSize(
            for: sourceRect.size,
            pixelsPerPoint: displayPixelScale,
            maxLongEdge: maxLongEdge
        )
        config.width = Int(outputSize.width)
        config.height = Int(outputSize.height)
        return config
    }

    /// Converts ScreenCaptureKit's point-space crop into backing pixels before applying the
    /// user-selected quality ceiling. Treating sourceRect points as pixels made a 2× virtual
    /// display render at half resolution in each dimension, so quality values above the window's
    /// logical width had no visible effect.
    static func outputPixelSize(
        for sourceSize: CGSize,
        pixelsPerPoint: CGSize,
        maxLongEdge: CGFloat
    ) -> CGSize {
        let pixelWidth = sourceSize.width * (pixelsPerPoint.width > 0 ? pixelsPerPoint.width : 1)
        let pixelHeight = sourceSize.height * (pixelsPerPoint.height > 0 ? pixelsPerPoint.height : 1)
        let nativeLongEdge = max(pixelWidth, pixelHeight)
        let qualityScale = nativeLongEdge > maxLongEdge && nativeLongEdge > 0
            ? maxLongEdge / nativeLongEdge
            : 1
        return CGSize(
            width: max((pixelWidth * qualityScale).rounded(), 2),
            height: max((pixelHeight * qualityScale).rounded(), 2)
        )
    }

    private func startStallWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: sampleQueue)
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastFrameDate) > 3 {
                PiPanelLogger.capture.warning("No frames received for 3s+ for window \(self.windowInfo.id)")
            }
        }
        timer.resume()
        stallTimer = timer
    }
}

extension CaptureSession: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }

        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachmentsArray.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete else {
            return
        }

        lastFrameDate = Date()
        delegate?.captureSession(self, didOutput: sampleBuffer)
    }
}

extension CaptureSession: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        PiPanelLogger.capture.error("Stream stopped with error: \(error.localizedDescription)")
        delegate?.captureSessionDidStop(self, error: error)
    }
}
