import ScreenCaptureKit
import CoreMedia
import AppKit
import ApplicationServices

/// Separates an app-imposed resize refusal from the virtual display's own hard edge.
///
/// `clampToDeliverableSize` scales both axes uniformly to preserve aspect ratio. When height is
/// the limiting axis, width is reduced too even though plenty of horizontal space remains. That
/// reduced width is still a valid probe of the source app's width limit; treating every uniformly
/// scaled axis as "display constrained" suppresses width-ceiling discovery forever.
enum ResizeConstraintProbePolicy {
    static func displayOwnsAxis(
        requested: CGFloat,
        target: CGFloat,
        capacity: CGFloat,
        tolerance: CGFloat = 1
    ) -> Bool {
        requested > capacity + tolerance && target >= capacity - tolerance
    }
}

protocol CaptureSessionDelegate: AnyObject {
    func captureSessionDidStop(_ session: CaptureSession, error: Error?)
}

enum CaptureSessionError: Error {
    case windowNotAccessible
    case virtualDisplayCreationFailed
    case virtualDisplayNotVisibleToScreenCaptureKit
}

/// Lightweight WindowServer record used to detect an application replacing its launcher/start
/// window with a newly-created document or editor window while the PiP session is already live.
struct SourceWindowSnapshot: Equatable {
    let id: CGWindowID
    let title: String?
    let frame: CGRect
}

/// Owns one PiP capture session: leases a private virtual display from VirtualDisplayPool,
/// relocates the source window onto it via Accessibility, and streams that display via
/// ScreenCaptureKit. The display normally outlives this session and is returned to the pool.
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
    private let framePresenter: LatestVideoFramePresenter

    private(set) var virtualDisplayHost: VirtualDisplayHost?
    private(set) var originalFrame: CGRect?
    private(set) var axWindow: AXUIElement?
    /// Unlike windowInfo, which identifies the window the user originally selected, these track
    /// the live window currently owned by the session. Word, CapCut/Jianying, and similar apps
    /// replace a launcher window with a different CGWindow/AXWindow when a document is created.
    private var currentSourceWindowID: CGWindowID
    private var currentSourceWindowTitle: String
    /// Window IDs already visible when this session started (plus every window subsequently
    /// adopted). A newly-visible physical-screen window from the same PID is only eligible for
    /// handoff when its ID is genuinely new, preventing another document that was already open
    /// before PiP from being stolen by this session.
    private var knownSourceAppWindowIDs: Set<CGWindowID> = []
    private var isAdoptingReplacementWindow = false
    /// Supplies the other active sessions when a replacement window forces this virtual display
    /// to grow. The same topology repair used during initial startup must also protect siblings.
    var siblingSessionsProvider: (() -> [CaptureSession])?
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
    /// Brackets the actual Accessibility move from a physical screen onto the private display.
    /// PiPPanelController uses these main-actor callbacks to show glass only for the migration
    /// itself, rather than from the moment an otherwise-empty panel is constructed.
    var onSourceWindowWillMoveOntoVirtualDisplay: (() -> Void)?
    var onSourceWindowDidMoveOntoVirtualDisplay: (() -> Void)?
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
    /// True while the source fills the private display. Some apps expose AXFullScreen; Chromium-
    /// based apps and Bilibili can instead grow a normal AX window to the display's raw pixel
    /// dimensions. Both cases must use the full-display capture coordinate space.
    private var isSourceNativeFullScreen = false
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
    /// Refresh ceiling of the private display ScreenCaptureKit actually captures. The source
    /// window no longer lives on its original physical display once PiP starts, so capping against
    /// that old screen incorrectly kept a 120/144 Hz PiP at 60 fps even though the private display
    /// and the panel's destination screen could both present faster.
    var captureDisplayMaximumFPS: Int = DisplayRefreshRate.fallbackFPS {
        didSet { Task { try? await applyConfiguration() } }
    }
    /// Refresh ceiling of the physical screen currently presenting the PiP panel. Capturing more
    /// frames than this screen can scan out only makes AVSampleBufferDisplayLayer discard them.
    var presentationDisplayMaximumFPS: Int = DisplayRefreshRate.fallbackFPS {
        didSet { Task { try? await applyConfiguration() } }
    }

    private var effectiveTargetFPS: Int {
        Self.effectiveFrameRate(
            requested: targetFPS,
            captureMaximum: captureDisplayMaximumFPS,
            presentationMaximum: presentationDisplayMaximumFPS
        )
    }

    static func effectiveFrameRate(requested: Int, displayMaximum: Int) -> Int {
        min(max(requested, 1), max(displayMaximum, 1))
    }

    static func effectiveFrameRate(
        requested: Int,
        captureMaximum: Int,
        presentationMaximum: Int
    ) -> Int {
        min(
            max(requested, 1),
            max(captureMaximum, 1),
            max(presentationMaximum, 1)
        )
    }
    /// The private virtual display's pixel long edge. Before start() runs (virtualDisplayHost ==
    /// nil), setting this just records the size start() will create the display at — set once by
    /// PiPSessionManager right after construction, same as targetFPS. Once a session is live, a
    /// change instead live-resizes the *existing* VirtualDisplayHost via
    /// VirtualDisplayHost.resize(pixelWidth:pixelHeight:) — confirmed working in
    /// Spikes/VirtualDisplayResizeSpike even against a display an SCStream is already actively
    /// capturing (see that method's own doc comment for why an earlier attempt at this looked
    /// broken and wasn't).
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
                    await applyVirtualDisplayResize(longEdge: longEdge)
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

    private func applyVirtualDisplayResize(longEdge: CGFloat) async {
        guard let host = virtualDisplayHost else { return }
        // Applying a new CGVirtualDisplay mode is a process-wide topology mutation, just like
        // creating/destroying a host. Serialize it with startup, teardown and re-anchoring so an
        // old session can never read the half-reflowed desktop produced between apply(_:) and the
        // window server's final arrangement notification.
        await VirtualDisplayCoordinator.shared.lock()
        guard !isStopping, virtualDisplayHost === host else {
            await VirtualDisplayCoordinator.shared.unlock()
            return
        }
        // Freeze the last valid crop before WindowServer republishes the display topology. The
        // frame watcher must never commit an intermediate carried/reflowed window frame.
        stopFrameWatch()
        let pixelSize = VirtualDisplayHost.pixelSize(forLongEdge: longEdge)
        let resized = await MainActor.run { host.resize(pixelWidth: pixelSize.width, pixelHeight: pixelSize.height) }
        guard resized else {
            if presentationState == .pip { startFrameWatch(host: host) }
            await VirtualDisplayCoordinator.shared.unlock()
            debugTrace("vdisplay: live resize FAILED requestedLongEdge=\(longEdge) pixelSize=(\(pixelSize.width), \(pixelSize.height))")
            return
        }
        debugTrace("vdisplay: live resize applied requestedLongEdge=\(longEdge) pixelSize=(\(pixelSize.width), \(pixelSize.height)) coordinateBounds=\(host.bounds)")

        // Repair the source synchronously while this topology mutation still owns the coordinator
        // lock. Previously we updated SCStream immediately with the old framedRect, unlocked, and
        // relied on a later screen-change notification to repair the source. The controller's
        // deliverable-size callback raced that queued repair, so its resize request bailed while
        // isReanchoring was true and the stream kept rendering the old aspect/crop.
        await Self.waitForStableTopology(hosts: [host])
        do {
            if isSourceNativeFullScreen || sourceOccupiesFullVirtualDisplay() {
                isSourceNativeFullScreen = true
                framedRect = Self.nativeFullScreenCaptureRect(displaySize: host.captureCanvasSize)
            } else if let axWindow {
                try await moveWindowOntoVirtualDisplay(
                    host: host,
                    axWindow: axWindow,
                    size: currentPiPSize
                )
            }
            try await applyConfiguration()
        } catch {
            PiPanelLogger.capture.error("Failed to repair source after live virtual-display resize: \(error)")
        }

        // Invalidate any didChangeScreenParameters task queued by this same mode switch; the
        // synchronous repair above has already consumed it against the stable final topology.
        reanchorTaskGeneration &+= 1
        isReanchoring = false
        if !isStopping, presentationState == .pip, virtualDisplayHost === host {
            startFrameWatch(host: host)
        }
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

    init(windowInfo: WindowInfo, framePresenter: LatestVideoFramePresenter) {
        self.windowInfo = windowInfo
        self.framePresenter = framePresenter
        currentSourceWindowID = windowInfo.id
        currentSourceWindowTitle = windowInfo.title
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
    /// macOS moves the Dock to another display when the pointer dwells against that display's
    /// exposed bottom edge. InteractionForwarder deliberately warps the real pointer onto a
    /// virtual display, so source content must end before that trigger strip. A generous inset
    /// also leaves enough travel for the global mouse monitor to return the pointer to the PiP
    /// before it can reach the physical display boundary.
    static let dockAvoidanceInset: CGFloat = 80

    static func sourceSizeFittingSafeArea(
        _ size: CGSize,
        displaySize: CGSize,
        localOrigin: CGPoint
    ) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        let capacity = CGSize(
            width: max(displaySize.width - localOrigin.x - edgeMargin, 1),
            height: max(displaySize.height - localOrigin.y - dockAvoidanceInset, 1)
        )
        let scale = min(1, capacity.width / size.width, capacity.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    /// ScreenCaptureKit crop used while the source fills a CGVirtualDisplay. Runtime traces show
    /// this path reports and captures the raw display canvas (for example 2560×1600), unlike the
    /// ordinary windowed path whose AX crop is in the logical 1280×800 space.
    static func nativeFullScreenCaptureRect(displaySize: CGSize) -> CGRect {
        CGRect(origin: .zero, size: displaySize)
    }

    /// Detects apps that implement fullscreen/zoom without publishing AXFullScreen. Their AX
    /// frame still covers essentially the complete raw virtual-display canvas.
    static func isFullVirtualDisplayFrame(
        _ frame: CGRect,
        displayOrigin: CGPoint,
        displayPixelSize: CGSize
    ) -> Bool {
        guard displayPixelSize.width > 0, displayPixelSize.height > 0 else { return false }
        let displayFrame = CGRect(origin: displayOrigin, size: displayPixelSize)
        // Bilibili/Chromium's borderless fullscreen surface may retain a ~30pt top inset even
        // though it does not publish AXFullScreen. A merely maximized PiP source deliberately
        // keeps 40pt side and 80pt bottom safety margins, so checking all four edges with a
        // tighter tolerance cleanly separates the two. The former percentage-only test accepted
        // 90%×85%; the trace showed an ordinary 1526×916 window on a 1664×1040 display crossing
        // that threshold and getting permanently switched to full-display capture mid-drag.
        let edgeTolerance: CGFloat = 36
        return frame.width >= displayPixelSize.width * 0.95
            && frame.height >= displayPixelSize.height * 0.95
            && abs(frame.minX - displayFrame.minX) <= edgeTolerance
            && abs(frame.minY - displayFrame.minY) <= edgeTolerance
            && abs(frame.maxX - displayFrame.maxX) <= edgeTolerance
            && abs(frame.maxY - displayFrame.maxY) <= edgeTolerance
    }

    static func excludesSystemUI(bundleIdentifier: String?) -> Bool {
        bundleIdentifier == "com.apple.dock"
    }

    /// `SCContentFilter(display:excludingApplications:exceptingWindows:)` treats an exception
    /// as a toggle, not as an unconditional include. The source window must therefore only be
    /// listed when its own application was excluded (for example, another PiP window belongs to
    /// the same process). Listing an otherwise-included source window would exclude it and make
    /// the stream deliver only the empty virtual-display background.
    static func shouldExceptSourceWindow(
        sourceProcessID: pid_t?,
        excludedApplicationProcessIDs: Set<pid_t>
    ) -> Bool {
        guard let sourceProcessID else { return false }
        return excludedApplicationProcessIDs.contains(sourceProcessID)
    }

    static func isOutsideDockTriggerZone(_ globalPoint: CGPoint, displayBounds: CGRect) -> Bool {
        guard displayBounds.width > 0, displayBounds.height > 0 else { return false }
        return displayBounds.contains(globalPoint)
            && globalPoint.y < displayBounds.maxY - dockAvoidanceInset
    }

    static func canForwardInteraction(
        at globalPoint: CGPoint,
        displayBounds: CGRect,
        capturedContentFrame: CGRect?
    ) -> Bool {
        guard displayBounds.contains(globalPoint) else { return false }
        if isOutsideDockTriggerZone(globalPoint, displayBounds: displayBounds) {
            return true
        }

        // Normally sourceSizeFittingSafeArea keeps content out of this strip. Electron-style apps
        // such as Bilibili and RedNote can reject that requested shrink and extend all the way to
        // the display edge. In that case the strip contains real, visible controls (often the
        // player's fullscreen button), so rejecting it makes the PiP advertise controls that can
        // never be clicked. Limit the exception to a captured frame that genuinely reaches into
        // the strip; ordinary windows retain the Dock-avoidance guard.
        guard let capturedContentFrame,
              capturedContentFrame.maxY > displayBounds.maxY - dockAvoidanceInset else {
            return false
        }
        return capturedContentFrame.contains(globalPoint)
    }

    func canForwardInteraction(at globalPoint: CGPoint) -> Bool {
        if isSourceNativeFullScreen, let axWindow,
           let fullScreenFrame = AXWindowLocator.frame(of: axWindow) {
            return fullScreenFrame.contains(globalPoint)
        }
        guard let bounds = virtualDisplayHost?.bounds else { return false }
        return Self.canForwardInteraction(
            at: globalPoint,
            displayBounds: bounds,
            capturedContentFrame: currentCapturedContentFrame()
        )
    }

    func start(reanchoring siblingSessions: [CaptureSession] = []) async throws {
        // Serialized: see VirtualDisplayCoordinator for why concurrent session startups aren't safe.
        await VirtualDisplayCoordinator.shared.lock()
        defer { Task { await VirtualDisplayCoordinator.shared.unlock() } }

        guard let axWindow = AXWindowLocator.locate(windowInfo) else {
            throw CaptureSessionError.windowNotAccessible
        }
        self.axWindow = axWindow
        let originalFrame = AXWindowLocator.frame(of: axWindow) ?? windowInfo.frame
        self.originalFrame = originalFrame
        currentPiPSize = originalFrame.size
        knownSourceAppWindowIDs = Set(
            Self.onScreenSourceWindowSnapshots(ownerPID: windowInfo.ownerPID).map(\.id)
        )
        knownSourceAppWindowIDs.insert(windowInfo.id)

        // Leased from the application-level pool at whatever SettingsStore.virtualDisplayLongEdge
        // currently is. The lower-resource default remains larger than a typical PiP source and
        // oversized apps can expand their own live mode automatically, so a later PiP-panel resize
        // (resizeSourceWindow) can still grow without every session starting at the descriptor's
        // full maxPixelsWide/maxPixelsHigh ceiling. The mode also *can*
        // change mid-session now, live, via virtualDisplayLongEdge's own didSet calling
        // VirtualDisplayHost.resize(pixelWidth:pixelHeight:) — see that method's doc comment for
        // how this was verified to actually work even against an actively-capturing SCStream, and
        // VirtualDisplayHost.bounds's doc comment for the one wrinkle (CGDisplayBounds itself never
        // reflects the new size, so bounds tracks it independently instead). SCStreamConfiguration.
        // sourceRect already crops the capture down to just the window's own rect regardless of how
        // big the underlying display canvas is (see makeConfiguration), so there's no meaningful
        // capture-bandwidth cost to the display being bigger than the window actually needs.
        //
        // CGVirtualDisplay must be created on the main thread — off-main creation was
        // observed to silently produce a display that never shows up in
        // SCShareableContent's display list.
        let virtualDisplayPixelSize = VirtualDisplayHost.pixelSize(forLongEdge: virtualDisplayLongEdge)
        let pooledLease = await MainActor.run {
            VirtualDisplayPool.shared.lease(
                pixelWidth: virtualDisplayPixelSize.width,
                pixelHeight: virtualDisplayPixelSize.height
            )
        }
        let host: VirtualDisplayHost
        let createdDuringStart: Bool
        let mutatedTopology: Bool
        if let pooledLease {
            host = pooledLease.host
            createdDuringStart = false
            mutatedTopology = pooledLease.mutatedTopology
        } else {
            host = try await MainActor.run { () -> VirtualDisplayHost in
                guard let host = VirtualDisplayHost(
                    pixelWidth: virtualDisplayPixelSize.width,
                    pixelHeight: virtualDisplayPixelSize.height,
                    name: "PiPanel Overflow – \(windowInfo.ownerAppName)"
                ) else {
                    throw CaptureSessionError.virtualDisplayCreationFailed
                }
                VirtualDisplayPool.shared.adoptLeased(host)
                return host
            }
            createdDuringStart = true
            mutatedTopology = true
        }
        virtualDisplayHost = host
        captureDisplayMaximumFPS = max(Int(host.currentRefreshRate.rounded()), 1)

        // The normal path leases an already-registered host and performs no display mutation at
        // all. Only an overflow creation or a resolution-mismatch resize needs the expensive
        // topology barrier and sibling repair used by the former per-session-display design.
        _ = try await Self.waitForValidBounds(of: host, positionNewDisplay: createdDuringStart)
        if mutatedTopology {
            let topologyHosts = [host] + siblingSessions.compactMap(\.virtualDisplayHost)
            await Self.waitForStableTopology(hosts: topologyHosts)
            for sibling in siblingSessions where sibling !== self {
                await sibling.reanchorWhileTopologyLockIsHeld()
            }
        }

        try await moveWindowOntoVirtualDisplay(
            host: host,
            axWindow: axWindow,
            size: currentPiPSize,
            positionNewDisplay: false
        )
        try await expandVirtualDisplayToFitSourceIfNeeded(
            host: host,
            axWindow: axWindow,
            siblingSessions: siblingSessions
        )
        refreshCurrentSourceWindowIdentity(using: axWindow)

        let shareable = try await Self.waitForShareableDisplay(matching: host.displayID)

        // Defense in depth: even if WindowServer produces another late transient placement, an
        // older session's source is never eligible to appear in this brand-new stream. Excluding
        // Dock by application identity (rather than only its current windows) also covers Dock
        // recreating its overlay window after the stream starts.
        let siblingWindows = siblingSessions.map { $0.windowInfo.scWindow }
        let dockApplications = shareable.content.applications.filter {
            Self.excludesSystemUI(bundleIdentifier: $0.bundleIdentifier)
        }
        let excludedApplicationsByPID = Dictionary(
            grouping: dockApplications + siblingWindows.compactMap(\.owningApplication),
            by: \.processID
        )
        let filter: SCContentFilter
        if !dockApplications.isEmpty {
            let excludedApplications = excludedApplicationsByPID.values.compactMap { $0.first }
            let excludedApplicationProcessIDs = Set(excludedApplications.map(\.processID))
            let sourceProcessID = windowInfo.scWindow.owningApplication?.processID
            let sourceExceptions = Self.shouldExceptSourceWindow(
                sourceProcessID: sourceProcessID,
                excludedApplicationProcessIDs: excludedApplicationProcessIDs
            ) ? [windowInfo.scWindow] : []
            filter = SCContentFilter(
                display: shareable.display,
                excludingApplications: excludedApplications,
                exceptingWindows: sourceExceptions
            )
        } else {
            // Defensive fallback for an OS build that omits Dock from content.applications.
            let dockWindows = shareable.content.windows.filter {
                Self.excludesSystemUI(bundleIdentifier: $0.owningApplication?.bundleIdentifier)
            }
            filter = SCContentFilter(
                display: shareable.display,
                excludingWindows: siblingWindows + dockWindows
            )
        }
        let config = captureConfiguration(for: host)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
        presentationState = .pip
        observeScreenParameterChanges()
        startFrameWatch(host: host)
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
        let margin = VirtualDisplayHost.menuBarInset
        let bounds = try await Self.waitForValidBounds(
            of: host,
            positionNewDisplay: positionNewDisplay
        )

        let localOrigin = CGPoint(x: Self.edgeMargin, y: margin)
        let targetOrigin = CGPoint(x: bounds.origin.x + localOrigin.x, y: bounds.origin.y + localOrigin.y)
        let fittedSize = Self.sourceSizeFittingSafeArea(
            size,
            displaySize: bounds.size,
            localOrigin: localOrigin
        )
        currentPiPSize = fittedSize
        let targetFrame = CGRect(origin: targetOrigin, size: fittedSize)
        let reportWillMove = onSourceWindowWillMoveOntoVirtualDisplay
        await MainActor.run { reportWillMove?() }
        AXWindowLocator.setFrame(targetFrame, on: axWindow)

        let resultingFrame = await Self.waitForFrameToSettle(axWindow: axWindow, fallback: targetFrame)
        isSourceNativeFullScreen = false
        framedRect = CGRect(
            x: resultingFrame.origin.x - bounds.origin.x,
            y: resultingFrame.origin.y - bounds.origin.y,
            width: resultingFrame.width,
            height: resultingFrame.height
        )
        // The requested fitted size is only an aspiration. Bilibili and RedNote enforce a larger
        // minimum height, so all later panel/source scaling must start from what the app actually
        // accepted, not the rejected request.
        currentPiPSize = resultingFrame.size
        let reportDidMove = onSourceWindowDidMoveOntoVirtualDisplay
        await MainActor.run { reportDidMove?() }
    }

    static func requiredDisplaySize(forSourceFrame localFrame: CGRect) -> CGSize {
        CGSize(
            width: localFrame.maxX + edgeMargin,
            height: localFrame.maxY + dockAvoidanceInset
        )
    }

    static func sourceFrameFitsSafeArea(_ localFrame: CGRect, displaySize: CGSize) -> Bool {
        let required = requiredDisplaySize(forSourceFrame: localFrame)
        return required.width <= displaySize.width + 0.5
            && required.height <= displaySize.height + 0.5
    }

    /// Some Electron apps expose a minimum AX size larger than the user's selected virtual
    /// display mode can hold. Shrinking was previously attempted once, then the capture sourceRect
    /// simply intersected the oversized result with the display and permanently discarded its
    /// lower edge. Grow the already-leased display before SCStream starts, re-stabilize topology,
    /// and place the actual accepted window size again so every pixel exists on the canvas.
    private func expandVirtualDisplayToFitSourceIfNeeded(
        host: VirtualDisplayHost,
        axWindow: AXUIElement,
        siblingSessions: [CaptureSession]
    ) async throws {
        for attempt in 0..<2 {
            guard !Self.sourceFrameFitsSafeArea(framedRect, displaySize: host.bounds.size) else {
                return
            }

            let requiredCoordinateSize = Self.requiredDisplaySize(forSourceFrame: framedRect)
            guard let targetPixelSize = host.pixelSizeFitting(
                coordinateSize: requiredCoordinateSize
            ) else {
                debugTrace(
                    "vdisplay: source exceeds maximum canvas windowID=\(windowInfo.id) "
                    + "sourceFrame=\(framedRect) requiredCoordinates=\(requiredCoordinateSize)"
                )
                throw CaptureSessionError.virtualDisplayCreationFailed
            }

            let targetWidth = Int(targetPixelSize.width)
            let targetHeight = Int(targetPixelSize.height)
            guard targetWidth > Int(host.currentPixelSize.width)
                    || targetHeight > Int(host.currentPixelSize.height) else {
                throw CaptureSessionError.virtualDisplayCreationFailed
            }

            let resized = await MainActor.run {
                host.resize(pixelWidth: targetWidth, pixelHeight: targetHeight)
            }
            guard resized else { throw CaptureSessionError.virtualDisplayCreationFailed }

            debugTrace(
                "vdisplay: expanded for source windowID=\(windowInfo.id) attempt=\(attempt + 1) "
                + "sourceFrame=\(framedRect) requiredCoordinates=\(requiredCoordinateSize) "
                + "pixelMode=(\(targetWidth), \(targetHeight)) coordinateBounds=\(host.bounds)"
            )

            let topologyHosts = [host] + siblingSessions.compactMap(\.virtualDisplayHost)
            await Self.waitForStableTopology(hosts: topologyHosts)
            for sibling in siblingSessions where sibling !== self {
                await sibling.reanchorWhileTopologyLockIsHeld()
            }

            let actualSize = currentPiPSize
            try await moveWindowOntoVirtualDisplay(
                host: host,
                axWindow: axWindow,
                size: actualSize
            )
        }

        guard Self.sourceFrameFitsSafeArea(framedRect, displaySize: host.bounds.size) else {
            throw CaptureSessionError.virtualDisplayCreationFailed
        }
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
    private func startFrameWatch(host: VirtualDisplayHost) {
        guard !isStopping else { return }
        frameWatchTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshFramedRectIfNeeded(host: host)
        }
        RunLoop.main.add(timer, forMode: .common)
        frameWatchTimer = timer
    }

    private func stopFrameWatch() {
        frameWatchTimer?.invalidate()
        frameWatchTimer = nil
    }

    private func refreshFramedRectIfNeeded(host: VirtualDisplayHost) {
        // A screen-change notification stops this timer immediately, but an already-enqueued timer
        // callback may still arrive. Never turn a transient topology position into a live stream
        // crop while the stabilized re-anchor is pending — that exact update is what let another
        // session's source window appear inside an older PiP in the trace.
        guard presentationState == .pip, !isReanchoring, !isStopping,
              !isAdoptingReplacementWindow else { return }

        // Launcher-style apps often create the real document/editor as a brand-new window on a
        // physical display, then close or hide the launcher parked on this virtual display. Scan
        // before reading the cached AX element so handoff also works during the short overlap in
        // which both old and new elements still exist.
        if beginReplacementWindowAdoptionIfNeeded(host: host) { return }

        guard let axWindow else { return }
        guard let current = AXWindowLocator.frame(of: axWindow) else { return }
        let fillsDisplay = AXWindowLocator.isFullScreen(axWindow)
            || Self.isFullVirtualDisplayFrame(
                current,
                displayOrigin: host.bounds.origin,
                displayPixelSize: host.captureCanvasSize
            )
        if fillsDisplay {
            let fullDisplayRect = Self.nativeFullScreenCaptureRect(displaySize: host.captureCanvasSize)
            guard !isSourceNativeFullScreen
                    || !Self.isApproximatelyEqual(framedRect, fullDisplayRect) else { return }
            isSourceNativeFullScreen = true
            framedRect = fullDisplayRect
            debugTrace(
                "fullscreen: expanded capture windowID=\(windowInfo.id) "
                + "axFrame=\(current) sourceRect=\(fullDisplayRect) "
                + "logicalBounds=\(host.bounds) modeSize=\(host.currentPixelSize) "
                + "captureCanvas=\(host.captureCanvasSize)"
            )
            Task { try? await applyConfiguration() }
            return
        }

        if isSourceNativeFullScreen {
            isSourceNativeFullScreen = false
            debugTrace("fullscreen: source exited native fullscreen windowID=\(windowInfo.id)")
        }
        let bounds = host.bounds
        let updated = CGRect(
            x: current.origin.x - bounds.origin.x,
            y: current.origin.y - bounds.origin.y,
            width: current.width,
            height: current.height
        )
        guard !Self.isApproximatelyEqual(updated, framedRect) else { return }
        debugTrace("grow: refreshFramedRectIfNeeded correcting framedRect from=\(framedRect) to=\(updated) liveAXFrame=\(current)")
        framedRect = updated
        Task { try? await applyConfiguration() }
    }

    /// Selects the frontmost same-process window that either reuses the current CGWindowID after
    /// moving itself back to a physical display, or has a genuinely new ID that was not present
    /// when PiP began. Snapshots are already ordered front-to-back by CGWindowList.
    static func replacementWindowCandidate(
        snapshots: [SourceWindowSnapshot],
        currentWindowID: CGWindowID,
        knownWindowIDs: Set<CGWindowID>,
        physicalDisplayFrames: [CGRect]
    ) -> SourceWindowSnapshot? {
        snapshots.first { snapshot in
            guard snapshot.id == currentWindowID || !knownWindowIDs.contains(snapshot.id) else {
                return false
            }
            let center = CGPoint(x: snapshot.frame.midX, y: snapshot.frame.midY)
            return physicalDisplayFrames.contains { displayFrame in
                displayFrame.contains(center)
            }
        }
    }

    private static func onScreenSourceWindowSnapshots(ownerPID: pid_t) -> [SourceWindowSnapshot] {
        guard let rawWindows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        return rawWindows.compactMap { info in
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ownerPID,
                  ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0.01,
                  let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.width > 60, frame.height > 60 else { return nil }
            return SourceWindowSnapshot(
                id: CGWindowID(id),
                title: info[kCGWindowName as String] as? String,
                frame: frame
            )
        }
    }

    private static func physicalDisplayFrames() -> [CGRect] {
        let managedDisplayIDs = VirtualDisplayHost.activeDisplayIDs
        return NSScreen.screens.compactMap { screen -> CGRect? in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { return nil }
            let displayID = CGDirectDisplayID(number.uint32Value)
            guard !managedDisplayIDs.contains(displayID) else { return nil }
            let bounds = CGDisplayBounds(displayID)
            return bounds.width > 0 && bounds.height > 0 ? bounds : nil
        }
    }

    @discardableResult
    private func beginReplacementWindowAdoptionIfNeeded(host: VirtualDisplayHost) -> Bool {
        let snapshots = Self.onScreenSourceWindowSnapshots(ownerPID: windowInfo.ownerPID)
        guard let candidate = Self.replacementWindowCandidate(
            snapshots: snapshots,
            currentWindowID: currentSourceWindowID,
            knownWindowIDs: knownSourceAppWindowIDs,
            physicalDisplayFrames: Self.physicalDisplayFrames()
        ),
        let replacementAXWindow = AXWindowLocator.locate(
            ownerPID: windowInfo.ownerPID,
            approximateFrame: candidate.frame,
            title: candidate.title
        ),
        !AXWindowLocator.isMinimized(replacementAXWindow),
        let replacementPhysicalFrame = AXWindowLocator.frame(of: replacementAXWindow) else {
            return false
        }

        isAdoptingReplacementWindow = true
        stopFrameWatch()
        Task { [weak self] in
            guard let self else { return }
            await VirtualDisplayCoordinator.shared.lock()
            guard !self.isStopping, self.presentationState == .pip,
                  self.virtualDisplayHost === host else {
                await VirtualDisplayCoordinator.shared.unlock()
                self.isAdoptingReplacementWindow = false
                return
            }

            let replacedWindowID = self.currentSourceWindowID
            self.currentSourceWindowID = candidate.id
            self.currentSourceWindowTitle = candidate.title
                ?? AXWindowLocator.title(of: replacementAXWindow)
                ?? self.windowInfo.ownerAppName
            self.knownSourceAppWindowIDs.insert(candidate.id)
            self.originalFrame = replacementPhysicalFrame
            self.axWindow = replacementAXWindow
            self.currentPiPSize = replacementPhysicalFrame.size
            self.resetSourceSizingStateForReplacement()

            debugTrace(
                "source handoff: adopting windowID=\(candidate.id) "
                + "title=\(self.currentSourceWindowTitle) physicalFrame=\(replacementPhysicalFrame) "
                + "replacingWindowID=\(replacedWindowID)"
            )

            do {
                try await self.moveWindowOntoVirtualDisplay(
                    host: host,
                    axWindow: replacementAXWindow,
                    size: replacementPhysicalFrame.size
                )
                let siblings = self.siblingSessionsProvider?() ?? []
                try await self.expandVirtualDisplayToFitSourceIfNeeded(
                    host: host,
                    axWindow: replacementAXWindow,
                    siblingSessions: siblings
                )
                self.refreshCurrentSourceWindowIdentity(using: replacementAXWindow)
                try await self.applyConfiguration()
                debugTrace(
                    "source handoff: completed windowID=\(self.currentSourceWindowID) "
                    + "virtualFrame=\(AXWindowLocator.frame(of: replacementAXWindow) ?? .zero)"
                )
            } catch {
                PiPanelLogger.capture.error(
                    "Failed to adopt replacement window \(candidate.id): \(error.localizedDescription)"
                )
                debugTrace("source handoff: failed windowID=\(candidate.id) error=\(error)")
            }

            await VirtualDisplayCoordinator.shared.unlock()
            self.isAdoptingReplacementWindow = false
            if !self.isStopping, self.presentationState == .pip,
               self.virtualDisplayHost === host {
                self.startFrameWatch(host: host)
            }
        }
        return true
    }

    private func resetSourceSizingStateForReplacement() {
        panelToSourceScale = nil
        pendingResizeSize = nil
        discoveredMinWidth = nil
        discoveredMinHeight = nil
        discoveredMaxWidth = nil
        discoveredMaxHeight = nil
        suspectedMinWidth = nil
        suspectedMinHeight = nil
        suspectedMaxWidth = nil
        suspectedMaxHeight = nil
        suspectedMinWidthStreak = 0
        suspectedMinHeightStreak = 0
        suspectedMaxWidthStreak = 0
        suspectedMaxHeightStreak = 0
        previousTargetSize = .zero
        onSourceMinSizeDiscovered?(.zero)
        onSourceMaxSizeDiscovered?(
            CGSize(width: CGFloat.infinity, height: CGFloat.infinity)
        )
    }

    private func refreshCurrentSourceWindowIdentity(using axWindow: AXUIElement) {
        guard let liveFrame = AXWindowLocator.frame(of: axWindow) else { return }
        let snapshots = Self.onScreenSourceWindowSnapshots(ownerPID: windowInfo.ownerPID)
        guard let best = snapshots.min(by: {
            Self.windowFrameDistance($0.frame, liveFrame)
                < Self.windowFrameDistance($1.frame, liveFrame)
        }), Self.windowFrameDistance(best.frame, liveFrame) < 40 else { return }
        currentSourceWindowID = best.id
        knownSourceAppWindowIDs.insert(best.id)
        if let title = best.title,
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            currentSourceWindowTitle = title
        }
    }

    private static func windowFrameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.origin.x - rhs.origin.x)
            + abs(lhs.origin.y - rhs.origin.y)
            + abs(lhs.width - rhs.width)
            + abs(lhs.height - rhs.height)
    }

    /// Any real display-topology change (an overflow host being created/discarded, a virtual mode
    /// resize, a physical monitor change, or app shutdown) can make macOS reflow the global desktop
    /// arrangement. VirtualDisplayHost.bounds already reads that shift live,
    /// but the window itself isn't guaranteed to move in lockstep with its display through a
    /// reflow, so refreshFramedRectIfNeeded's crop math (live window frame − live display origin)
    /// can end up describing a region that no longer actually contains this session's window —
    /// observed as a still-open PiP silently switching to a different app's content the instant a
    /// sibling PiP is closed. Re-placing the window onto its own display's *current* bounds after
    /// any screen-configuration change fixes that regardless of the exact way it drifted, since
    /// moveWindowOntoVirtualDisplay always re-derives both the placement and framedRect from
    /// scratch rather than trusting incremental deltas.
    private func observeScreenParameterChanges() {
        screenParamsObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reanchorAfterDisplayReconfiguration()
        }
    }

    private func stopObservingScreenParameterChanges() {
        if let screenParamsObserver { NotificationCenter.default.removeObserver(screenParamsObserver) }
        screenParamsObserver = nil
    }

    private func reanchorAfterDisplayReconfiguration() {
        guard presentationState == .pip, !isStopping, !isAdoptingReplacementWindow,
              let host = virtualDisplayHost, let axWindow else { return }

        // Freeze the last known-good crop before doing anything asynchronous. Creating a sibling
        // display can move this window several thousand points for a fraction of a second; the old
        // frame watcher used to observe that position and update SCStream immediately, before the
        // later re-anchor had a chance to correct it.
        stopFrameWatch()
        guard !isReanchoring else { return }
        isReanchoring = true
        reanchorTaskGeneration &+= 1
        let generation = reanchorTaskGeneration
        debugTrace("vdisplay: reanchor queued windowID=\(windowInfo.id) displayID=\(host.displayID) liveFrame=\(AXWindowLocator.frame(of: axWindow) ?? .zero) displayBounds=\(host.bounds)")
        Task { [weak self] in
            guard let self else { return }

            // CaptureSession.start() holds this same lock from before CGVirtualDisplay.apply(_:)
            // until its two-phase startup has synchronously repaired every existing session and
            // started the new stream. A sibling-barrier repair invalidates this queued task; in
            // every other case waiting here converts a burst of intermediate screen-change
            // notifications into one correction against the final arrangement. It also serializes
            // against live mode changes and display teardown below.
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
                if self.isSourceNativeFullScreen
                    || self.sourceOccupiesFullVirtualDisplay(axWindow: axWindow, host: host) {
                    self.isSourceNativeFullScreen = true
                    self.framedRect = Self.nativeFullScreenCaptureRect(displaySize: host.captureCanvasSize)
                } else {
                    try await self.moveWindowOntoVirtualDisplay(
                        host: host,
                        axWindow: axWindow,
                        size: self.currentPiPSize
                    )
                }
                try await self.applyConfiguration()
            } catch {
                PiPanelLogger.capture.error("Failed to re-anchor window \(self.windowInfo.id) after display reconfiguration: \(error)")
            }
            await VirtualDisplayCoordinator.shared.unlock()
            guard self.reanchorTaskGeneration == generation else { return }
            self.isReanchoring = false

            if !self.isStopping, self.presentationState == .pip,
               self.virtualDisplayHost === host {
                self.startFrameWatch(host: host)
            }
        }
    }

    /// Called only by another CaptureSession.start while that startup owns
    /// VirtualDisplayCoordinator's lock. Creating its display may have carried this source window
    /// along with a transient global reflow; repair this session before the newcomer moves its own
    /// source or starts capturing. This deliberately does not acquire the coordinator again.
    private func reanchorWhileTopologyLockIsHeld() async {
        guard presentationState == .pip, !isStopping,
              let host = virtualDisplayHost, let axWindow,
              currentPiPSize.width > 0, currentPiPSize.height > 0 else { return }

        stopFrameWatch()
        debugTrace("vdisplay: sibling barrier reanchor begin windowID=\(windowInfo.id) displayID=\(host.displayID) liveFrame=\(AXWindowLocator.frame(of: axWindow) ?? .zero) displayBounds=\(host.bounds)")
        do {
            if isSourceNativeFullScreen
                || sourceOccupiesFullVirtualDisplay(axWindow: axWindow, host: host) {
                isSourceNativeFullScreen = true
                framedRect = Self.nativeFullScreenCaptureRect(displaySize: host.captureCanvasSize)
            } else {
                try await moveWindowOntoVirtualDisplay(
                    host: host,
                    axWindow: axWindow,
                    size: currentPiPSize
                )
            }
            try await applyConfiguration()
        } catch {
            PiPanelLogger.capture.error("Failed sibling-barrier re-anchor for window \(self.windowInfo.id): \(error)")
        }

        // Any didChangeScreenParameters task queued by the same topology mutation is now stale:
        // this synchronous correction consumed it against the stable arrangement.
        reanchorTaskGeneration &+= 1
        isReanchoring = false
        if !isStopping, presentationState == .pip, virtualDisplayHost === host {
            startFrameWatch(host: host)
        }
        debugTrace("vdisplay: sibling barrier reanchor end windowID=\(windowInfo.id) displayID=\(host.displayID) liveFrame=\(AXWindowLocator.frame(of: axWindow) ?? .zero) displayBounds=\(host.bounds)")
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
                let config = captureConfiguration(for: host)
                try await stream.updateConfiguration(config)
            }
            presentationState = .pip
            startFrameWatch(host: host)
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

    /// Predicts the exact source-window target the resize pipeline can send for a panel size.
    /// The controller uses this alongside the unconstrained panel-equivalent size when deciding
    /// whether the mirror must show the whole source. This matters when one panel axis is large
    /// enough to hit the virtual-display edge: the uniform capacity clamp can pull the *other*
    /// axis below an app-imposed minimum even though panelSize × panelToSourceScale is above it.
    func projectedSourceResizeTarget(forPanelSize panelSize: CGSize) -> CGSize {
        let scale = panelToSourceScale ?? 1
        let sourceRequest = CGSize(
            width: panelSize.width * scale,
            height: panelSize.height * scale
        )

        let widthFloor = discoveredMinWidth ?? 0
        let heightFloor = discoveredMinHeight ?? 0
        if sourceRequest.width < widthFloor && sourceRequest.height < heightFloor {
            return currentPiPSize
        }

        let bounded = clampedToKnownCeiling(clampedToKnownFloor(sourceRequest))
        guard let bounds = virtualDisplayHost?.bounds else { return bounded }
        return clampToDeliverableSize(bounded, within: bounds, shouldTrace: false)
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
              !isAdoptingReplacementWindow,
              !isSourceNativeFullScreen,
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
        let deliverableSize = deliverableSize(within: bounds)
        let targetSize = clampToDeliverableSize(boundedPanelSize, within: bounds)
        debugTrace("grow: applyPanelResize panelSize=\(panelSize) boundedPanelSize=\(boundedPanelSize) targetSize=\(targetSize) framedRectBefore=\(framedRect) boundsOrigin=\(bounds.origin) boundsSize=\(bounds.size)")
        let actualFrame = await commitSourceWindowSize(
            targetSize,
            requestedSize: boundedPanelSize,
            deliverableSize: deliverableSize,
            axWindow: axWindow,
            displayOrigin: bounds.origin
        )
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
    private func clampToDeliverableSize(
        _ size: CGSize,
        within bounds: CGRect,
        shouldTrace: Bool = true
    ) -> CGSize {
        let capacity = deliverableSize(within: bounds)
        let maxWidth = capacity.width
        let maxHeight = capacity.height
        guard size.width > 0, size.height > 0, size.width > maxWidth || size.height > maxHeight else {
            return size
        }
        let scale = min(maxWidth / size.width, maxHeight / size.height)
        let clamped = CGSize(width: size.width * scale, height: size.height * scale)
        if shouldTrace {
            debugTrace("grow: clampToDeliverableSize CLAMPED requested=\(size) -> \(clamped) maxWidth=\(maxWidth) maxHeight=\(maxHeight) framedRectOrigin=\(framedRect.origin) boundsSize=\(bounds.size)")
        }
        return clamped
    }

    private func deliverableSize(within bounds: CGRect) -> CGSize {
        CGSize(
            width: max(bounds.width - framedRect.origin.x - Self.edgeMargin, 1),
            height: max(bounds.height - framedRect.origin.y - Self.dockAvoidanceInset, 1)
        )
    }

    /// The same ceiling clampToDeliverableSize enforces per-tick, exposed so PiPPanelController
    /// can correct panel.maxSize to match. panel.maxSize is set once, at panel-creation time,
    /// before the virtual display even exists yet — it has to assume VirtualDisplayHost's
    /// aspirational maxPixelsWide/maxPixelsHigh ceiling, since nothing more specific is known yet.
    ///
    /// This originally carried a warning that CGVirtualDisplay might silently grant less than
    /// requested under resource pressure (several concurrent sessions active, etc.), with the
    /// implication that something should poll a live API to detect and correct for it. Two such
    /// attempts (CGDisplayBounds-based, then SCShareableContent-based — see VirtualDisplayHost.
    /// bounds's own doc comment for the detailed history) were built and both reverted: neither API
    /// ever reliably reflects this private API's true applied mode, so "detecting" the supposed
    /// under-grant just meant clamping every session to one of a small set of bogus placeholder
    /// sizes, which is strictly worse than the original theoretical risk (never actually confirmed
    /// to happen) ever was. VirtualDisplayHost.currentPixelSize — what was actually requested via
    /// init/resize — is trusted unconditionally now.
    var deliverableMaxSize: CGSize? {
        guard let bounds = virtualDisplayHost?.bounds, framedRect.width > 0 else { return nil }
        return CGSize(
            width: max(bounds.width - framedRect.origin.x - Self.edgeMargin, 1),
            height: max(bounds.height - framedRect.origin.y - Self.dockAvoidanceInset, 1)
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
    /// capacity — targetSize is what was actually sent to the app. The display owns an axis only
    /// when that target actually lands at that axis's deliverable edge; uniform aspect-preserving
    /// scaling may also reduce the other axis, but that other target remains a valid app-limit
    /// probe while it still has unused display space. A genuinely display-owned axis has to be
    /// excluded from floor/ceiling detection, not just tolerated:
    /// when clampToDeliverableSize shrinks a request to, say, 1200 on an axis whose window is
    /// currently sitting at 1203 (a 3pt difference — nothing was actually being asked to shrink in
    /// any meaningful sense), the app's unchanged actual naturally reads as "bigger than target",
    /// which used to get confirmed as a genuine app floor at ~1203. Since that's *above* the
    /// display's own maxWidth (1200), clampedToKnownFloor and clampToDeliverableSize would then
    /// fight each other forever afterward — the floor demanding at least 1203, the display capping
    /// at 1200 — freezing that axis at ~1200-1203 for the rest of the session regardless of
    /// anything the panel does from then on, which is exactly what broke aspect tracking once the
    /// panel grew large enough to hit the display's capacity. Skipping discovery entirely on the
    /// axis that actually reaches that capacity avoids manufacturing a floor/ceiling out of our
    /// own conservative request while still detecting a fixed-width app when height is the only
    /// display-owned dimension.
    private func commitSourceWindowSize(
        _ targetSize: CGSize,
        requestedSize: CGSize,
        deliverableSize: CGSize,
        axWindow: AXUIElement,
        displayOrigin: CGPoint
    ) async -> CGRect {
        let previousActual = framedRect.size
        let absoluteOrigin = CGPoint(x: displayOrigin.x + framedRect.origin.x, y: displayOrigin.y + framedRect.origin.y)
        let requestedFrame = CGRect(origin: absoluteOrigin, size: targetSize)
        AXWindowLocator.setSize(targetSize, on: axWindow)
        try? await Task.sleep(nanoseconds: 80_000_000)
        let actualFrame = AXWindowLocator.frame(of: axWindow) ?? requestedFrame
        debugTrace("grow: commitSourceWindowSize target=\(targetSize) actual=\(actualFrame.size) previousActual=\(previousActual) axWindowFrameReadOK=\(AXWindowLocator.frame(of: axWindow) != nil)")

        let tolerance: CGFloat = 1
        // Uniform aspect-preserving clamping can reduce both axes even when only one axis reaches
        // the display edge. Suppress app-bound discovery only on the axis that actually landed on
        // its capacity. In the reproduced fixed-width case, height landed at 776 while width was
        // scaled to 971 with 1360 available; width therefore remains a valid ceiling probe.
        let widthWasDisplayClamped = ResizeConstraintProbePolicy.displayOwnsAxis(
            requested: requestedSize.width,
            target: targetSize.width,
            capacity: deliverableSize.width,
            tolerance: tolerance
        )
        let heightWasDisplayClamped = ResizeConstraintProbePolicy.displayOwnsAxis(
            requested: requestedSize.height,
            target: targetSize.height,
            capacity: deliverableSize.height,
            tolerance: tolerance
        )
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

    /// CGVirtualDisplay destruction is asynchronous from WindowServer's point of view. Keep the
    /// topology lock until both PiPanel's registry and CoreGraphics stop reporting the overflow
    /// display, otherwise a queued startup can lease/read screens during the removal reflow.
    private static func waitForDisplayRemoval(_ displayID: CGDirectDisplayID) async {
        for attempt in 0..<20 {
            let isStillRegisteredByPiPanel = VirtualDisplayHost.activeDisplayIDs.contains(displayID)
            let bounds = CGDisplayBounds(displayID)
            if !isStillRegisteredByPiPanel,
               (CGDisplayIsActive(displayID) == 0 || bounds.width <= 0 || bounds.height <= 0) {
                debugTrace("vdisplay pool: removal stabilized displayID=\(displayID) attempt=\(attempt)")
                return
            }
            if attempt < 19 {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        debugTrace("vdisplay pool: removal wait timed out displayID=\(displayID) bounds=\(CGDisplayBounds(displayID))")
    }

    /// CGCompleteDisplayConfiguration returning success does not mean AppKit/CoreGraphics have
    /// finished publishing the same final arrangement to every client. Require the new display
    /// and all existing PiP displays to report unchanged bounds for two consecutive samples before
    /// repairing any carried-along source windows.
    private static func waitForStableTopology(hosts: [VirtualDisplayHost]) async {
        var hostsByDisplayID: [CGDirectDisplayID: VirtualDisplayHost] = [:]
        for host in hosts {
            hostsByDisplayID[host.displayID] = host
        }
        let uniqueHosts = hostsByDisplayID.values.sorted { $0.displayID < $1.displayID }
        var previousFrames = uniqueHosts.map(\.bounds)
        var stableSamples = 0

        for _ in 0..<15 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let currentFrames = uniqueHosts.map(\.bounds)
            let allRegistered = uniqueHosts.allSatisfy(\.isGeometryRegistered)
            let unchanged = zip(previousFrames, currentFrames).allSatisfy {
                isApproximatelyEqual($0.0, $0.1)
            }

            if allRegistered, unchanged {
                stableSamples += 1
                if stableSamples >= 2 {
                    debugTrace("vdisplay: topology barrier stable displays=\(zip(uniqueHosts, currentFrames).map { "\($0.0.displayID):\($0.1)" })")
                    return
                }
            } else {
                stableSamples = 0
            }
            previousFrames = currentFrames
        }

        debugTrace("vdisplay: topology barrier timed out displays=\(uniqueHosts.map { "\($0.displayID):\($0.bounds)" })")
    }

    /// A newly-created virtual display was observed (Spikes/VirtualDisplaySpike) to take
    /// anywhere from under a second up to ~5s to propagate to this process's
    /// ScreenCaptureKit/AppKit view of the display list — retry with a generous budget rather
    /// than failing outright.
    private static func waitForShareableDisplay(
        matching displayID: CGDirectDisplayID
    ) async throws -> (display: SCDisplay, content: SCShareableContent) {
        for attempt in 0..<20 {
            let content = try await SCShareableContent.current
            if let match = content.displays.first(where: { $0.displayID == displayID }) {
                return (match, content)
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
        framePresenter.invalidate()
        stallTimer?.cancel()
        stallTimer = nil
        stopFrameWatch()
        stopObservingScreenParameterChanges()
        await VirtualDisplayCoordinator.shared.lock()
        if let stream {
            self.stream = nil
            try? await stream.stopCapture()
        }
        let settledFrame = await restoreWindowOntoPhysicalDisplay()
        // Wait for a verified restore before marking this display available; otherwise a new
        // session could lease it while the previous source still occupies it.
        var hostIsReusable = virtualDisplayHost == nil
        if let settledFrame, let host = virtualDisplayHost {
            // An app that rejected the restore may still be sitting on this virtual desktop. Do
            // not hand that desktop to another session, whose display-wide stream could otherwise
            // include the stale window. Exceptional failed restores discard just this slot.
            hostIsReusable = !Self.frameOccupiesVirtualDisplay(settledFrame, host: host)
        }
        var hostBeingReleased = virtualDisplayHost
        virtualDisplayHost = nil
        var removedDisplayID: CGDirectDisplayID?
        if let host = hostBeingReleased {
            let reusable = hostIsReusable
            let wasRemoved = await MainActor.run {
                VirtualDisplayPool.shared.release(host, reusable: reusable)
            }
            if wasRemoved { removedDisplayID = host.displayID }
        }
        // Dropping the last strong reference is what actually unregisters CGVirtualDisplay.
        // Do it while the topology lock is held, then wait until CoreGraphics confirms removal so
        // a queued startup cannot observe the half-reflowed arrangement.
        hostBeingReleased = nil
        if let removedDisplayID {
            await Self.waitForDisplayRemoval(removedDisplayID)
        }
        await VirtualDisplayCoordinator.shared.unlock()
        PiPanelLogger.capture.info("Capture stopped for window \(self.currentSourceWindowID)")
    }

    /// Moves the source window back to its pre-session position — used both on session stop and
    /// by enterSourceActiveState() (M3), so it reappears on the user's real screen.
    func restoreWindowIfNeeded() {
        guard let originalFrame else { return }
        guard !sourceOccupiesFullVirtualDisplay() else {
            Task { [weak self] in _ = await self?.restoreWindowOntoPhysicalDisplay() }
            return
        }
        let liveWindow = AXWindowLocator.currentFrame(ofWindowID: currentSourceWindowID).flatMap {
            AXWindowLocator.locate(
                ownerPID: windowInfo.ownerPID,
                approximateFrame: $0,
                title: currentSourceWindowTitle
            )
        } ?? axWindow
        guard let liveWindow, AXWindowLocator.frame(of: liveWindow) != nil else {
            Task { [weak self] in _ = await self?.restoreWindowOntoPhysicalDisplay() }
            return
        }
        axWindow = liveWindow
        AXWindowLocator.setFrame(originalFrame, on: liveWindow)
    }

    /// Leaves a native fullscreen Space before restoring geometry. macOS ignores AX position and
    /// size writes while AXFullScreen is true, which previously stranded the source window on the
    /// private desktop when the PiP was closed.
    private func restoreWindowOntoPhysicalDisplay() async -> CGRect? {
        guard let originalFrame else { return nil }
        let cachedWindow = axWindow

        // Fullscreen may create a replacement/companion AX element. Exit every fullscreen element
        // from this PID that actually occupies this session's private display, not every window of
        // the app and not only the stale element cached before the transition.
        let fullscreenWindows = AXWindowLocator.windows(ownerPID: windowInfo.ownerPID).filter { window in
            guard AXWindowLocator.isFullScreen(window) else { return false }
            if let cachedWindow, CFEqual(cachedWindow, window) { return true }
            guard let frame = AXWindowLocator.frame(of: window), let host = virtualDisplayHost else {
                return false
            }
            return Self.frameOccupiesVirtualDisplay(frame, host: host)
        }
        for window in fullscreenWindows {
            let result = AXWindowLocator.setFullScreen(false, on: window)
            debugTrace(
                "fullscreen: stop requested exit windowID=\(currentSourceWindowID) axError=\(result.rawValue) "
                + "candidateFrame=\(AXWindowLocator.frame(of: window) ?? .zero)"
            )
        }

        // AXFullScreen can flip to false before the Space-closing animation releases geometry
        // writes. More importantly, the pre-transition AX element can report the requested frame
        // even while the real CGWindowID remains on the private display. Re-query that original
        // WindowServer identity on every pass, locate its current AX peer by the fresh frame, and
        // verify the WindowServer frame itself before declaring the restore complete.
        var lastReadableFrame: CGRect?
        var previousPhysicalFrame: CGRect?
        for attempt in 0..<60 {
            let serverFrame = AXWindowLocator.currentFrame(ofWindowID: currentSourceWindowID)
            let liveWindow = serverFrame.flatMap {
                AXWindowLocator.locate(
                    ownerPID: windowInfo.ownerPID,
                    approximateFrame: $0,
                    title: currentSourceWindowTitle
                )
            } ?? cachedWindow.flatMap { AXWindowLocator.frame(of: $0) != nil ? $0 : nil }

            if let liveWindow {
                axWindow = liveWindow
                if AXWindowLocator.isFullScreen(liveWindow) {
                    _ = AXWindowLocator.setFullScreen(false, on: liveWindow)
                }
                AXWindowLocator.setFrame(originalFrame, on: liveWindow)
            } else if attempt.isMultiple(of: 4), let cachedWindow {
                // Useful during the short interval where WindowServer temporarily removes the
                // original CGWindowID while closing its fullscreen companion.
                if AXWindowLocator.isFullScreen(cachedWindow) {
                    _ = AXWindowLocator.setFullScreen(false, on: cachedWindow)
                }
                AXWindowLocator.setFrame(originalFrame, on: cachedWindow)
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let current = AXWindowLocator.currentFrame(ofWindowID: currentSourceWindowID)
                    ?? liveWindow.flatMap({ AXWindowLocator.frame(of: $0) }) else { continue }
            lastReadableFrame = current

            let isOffManagedDisplay = virtualDisplayHost.map {
                !Self.frameOccupiesVirtualDisplay(current, host: $0)
            } ?? true
            guard isOffManagedDisplay else {
                previousPhysicalFrame = nil
                continue
            }

            if Self.isApproximatelyEqual(current, originalFrame)
                || previousPhysicalFrame.map({ Self.isApproximatelyEqual($0, current) }) == true {
                debugTrace(
                    "fullscreen: restored source windowID=\(currentSourceWindowID) "
                    + "target=\(originalFrame) settled=\(current) attempts=\(attempt + 1)"
                )
                return current
            }
            previousPhysicalFrame = current
        }

        let settled = lastReadableFrame
        debugTrace(
            "fullscreen: restore timed out windowID=\(currentSourceWindowID) target=\(originalFrame) "
            + "lastReadable=\(settled ?? .zero)"
        )
        return settled
    }

    private static func frameOccupiesVirtualDisplay(_ frame: CGRect, host: VirtualDisplayHost) -> Bool {
        let logicalFrame = host.bounds
        let rawFrame = CGRect(origin: logicalFrame.origin, size: host.captureCanvasSize)
        let area = max(frame.width * frame.height, 1)
        return [logicalFrame, rawFrame].contains { displayFrame in
            let overlap = frame.intersection(displayFrame)
            let overlapArea = overlap.isNull ? 0 : overlap.width * overlap.height
            return overlapArea / area >= 0.5
        }
    }

    /// The exact global region represented by the pixels in the PiP.
    ///
    /// This is deliberately not always the source window's complete AX frame. ScreenCaptureKit
    /// captures `framedRect` only after the same corner inset and display-bound intersection used
    /// by `makeConfiguration`. Bilibili and RedNote can report AX windows taller than the private
    /// display; their lower edge is therefore absent from the stream. Mapping the visible PiP
    /// against that untrimmed AX height made the error grow toward the bottom of the panel and
    /// could turn RedNote's in-app fullscreen click into a hit on macOS window chrome.
    func currentCapturedContentFrame() -> CGRect? {
        guard let host = virtualDisplayHost else { return nil }

        let displaySize: CGSize
        let localWindowRect: CGRect
        if isSourceNativeFullScreen {
            displaySize = host.captureCanvasSize
            localWindowRect = framedRect
        } else {
            displaySize = host.bounds.size
            if let axWindow, let liveFrame = AXWindowLocator.frame(of: axWindow) {
                localWindowRect = CGRect(
                    x: liveFrame.minX - host.bounds.minX,
                    y: liveFrame.minY - host.bounds.minY,
                    width: liveFrame.width,
                    height: liveFrame.height
                )
            } else {
                localWindowRect = framedRect
            }
        }

        return Self.globalCaptureFrame(
            localRect: localWindowRect,
            displayOrigin: host.bounds.origin,
            displaySize: displaySize
        )
    }

    /// Aspect ratio consumed by PiPVideoLayerView must come from the same crop as interaction
    /// mapping. Using framedRect.size here distorted the displayed-video geometry whenever an app
    /// extended beyond a virtual-display edge, even though the sample buffer only contained the
    /// clipped intersection.
    func currentCapturedContentSize() -> CGSize {
        guard let host = virtualDisplayHost else { return framedRect.size }
        let displaySize = isSourceNativeFullScreen ? host.captureCanvasSize : host.bounds.size
        return Self.captureSourceRect(for: framedRect, displaySize: displaySize).size
    }

    /// Identity check used by PiPSessionManager's virtual-display intrusion guard. Comparing the
    /// AX element itself (rather than PID/title) keeps a second window from the same application
    /// ineligible to remain on a PiPanel display.
    func ownsSourceWindow(_ candidate: AXUIElement) -> Bool {
        guard let axWindow else { return false }
        return CFEqual(axWindow, candidate)
    }

    /// The fullscreen companion window can be a different AX element from `axWindow`. The
    /// intrusion guard uses this source-level state together with the PID so it does not require
    /// an identity match that native fullscreen does not preserve.
    func sourceIsNativeFullScreen() -> Bool {
        isSourceNativeFullScreen || sourceOccupiesFullVirtualDisplay()
    }

    private func sourceOccupiesFullVirtualDisplay(
        axWindow: AXUIElement? = nil,
        host: VirtualDisplayHost? = nil
    ) -> Bool {
        guard let window = axWindow ?? self.axWindow,
              let host = host ?? virtualDisplayHost else { return false }
        if AXWindowLocator.isFullScreen(window) { return true }
        guard let frame = AXWindowLocator.frame(of: window) else { return false }
        return Self.isFullVirtualDisplayFrame(
            frame,
            displayOrigin: host.bounds.origin,
            displayPixelSize: host.captureCanvasSize
        )
    }

    private func captureConfiguration(for host: VirtualDisplayHost) -> SCStreamConfiguration {
        let displaySize: CGSize
        let pixelScale: CGSize
        if isSourceNativeFullScreen {
            // Fullscreen CGVirtualDisplay surfaces are already expressed in backing pixels.
            displaySize = host.captureCanvasSize
            pixelScale = CGSize(width: 1, height: 1)
        } else {
            displaySize = host.bounds.size
            pixelScale = host.pixelsPerPoint
        }
        return Self.makeConfiguration(
            for: framedRect,
            displaySize: displaySize,
            displayPixelScale: pixelScale,
            fps: effectiveTargetFPS,
            maxLongEdge: maxOutputLongEdge
        )
    }

    private func applyConfiguration() async throws {
        guard let stream, let host = virtualDisplayHost else { return }
        let config = captureConfiguration(for: host)
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

        let sourceRect = captureSourceRect(for: localRect, displaySize: displaySize)
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

    /// Crops to just the window's rect within the virtual display, so the surrounding
    /// wallpaper/menu bar that every display (real or virtual) renders doesn't show up. Insets a
    /// few points past that because macOS gives windows a small WindowServer corner radius while
    /// the AX frame remains rectangular. The display intersection is equally important: apps
    /// such as Bilibili and RedNote can report a window larger than the capture canvas.
    static func captureSourceRect(for localRect: CGRect, displaySize: CGSize) -> CGRect {
        let cornerRadiusInset: CGFloat = 6
        let fullDisplayRect = CGRect(origin: .zero, size: displaySize)
        let capturesWholeDisplay = isApproximatelyEqual(localRect, fullDisplayRect)
        // A native-fullscreen surface has no rounded window corners. Applying the ordinary 6pt
        // inset here would reintroduce the exact bug this mode fixes by trimming all four edges.
        let insetRect = capturesWholeDisplay
            ? localRect
            : localRect.insetBy(dx: cornerRadiusInset, dy: cornerRadiusInset)
        let clamped = insetRect.intersection(CGRect(origin: .zero, size: displaySize))
        return clamped.isEmpty ? fullDisplayRect : clamped
    }

    static func globalCaptureFrame(
        localRect: CGRect,
        displayOrigin: CGPoint,
        displaySize: CGSize
    ) -> CGRect {
        let sourceRect = captureSourceRect(for: localRect, displaySize: displaySize)
        return CGRect(
            x: displayOrigin.x + sourceRect.minX,
            y: displayOrigin.y + sourceRect.minY,
            width: sourceRect.width,
            height: sourceRect.height
        )
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
        let nativeSize = currentCapturedContentSize()
        framePresenter.submit(
            sampleBuffer,
            nativeSize: nativeSize.width > 0 ? nativeSize : windowInfo.frame.size
        )
    }
}

extension CaptureSession: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        PiPanelLogger.capture.error("Stream stopped with error: \(error.localizedDescription)")
        delegate?.captureSessionDidStop(self, error: error)
    }
}
