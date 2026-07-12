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

/// Owns one PiP capture session: creates a private virtual display, relocates the source
/// window onto it via Accessibility, and streams that display via ScreenCaptureKit.
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
        case pip
        case sourceActive
    }

    let windowInfo: WindowInfo
    weak var delegate: CaptureSessionDelegate?

    private(set) var virtualDisplayHost: VirtualDisplayHost?
    private(set) var originalFrame: CGRect?
    private(set) var axWindow: AXUIElement?
    private(set) var framedRect: CGRect = .zero
    private(set) var presentationState: PresentationState = .pip
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

    /// Set by InteractionForwarder right before it activates the source app just to deliver a
    /// forwarded click/keystroke — PiPSessionManager consumes (and clears) this to tell that
    /// apart from the user genuinely switching to the app (Cmd+Tab, Dock, "jump to source"), so
    /// operating the PiP thumbnail doesn't itself yank the window onto the physical screen and
    /// hide the panel (M3's transition is for real switches only).
    var suppressNextActivationTransition = false

    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "com.anypip.mac.capture.sampleQueue")
    private var lastFrameDate = Date()
    private var stallTimer: DispatchSourceTimer?
    /// Keeps the crop in sync with the window's live frame for as long as the session is
    /// presenting in PiP — see startFrameWatch.
    private var frameWatchTimer: Timer?
    /// See observeScreenParameterChanges/reanchorAfterDisplayReconfiguration.
    private var screenParamsObserver: NSObjectProtocol?
    private var isReanchoring = false

    var targetFPS: Int = 15 {
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
        currentPiPSize = originalFrame.size

        // Always created at VirtualDisplayHost's full maxPixelsWide/maxPixelsHigh ceiling —
        // *not* floored/sized to just the window's own size the way this used to work — so a
        // later PiP-panel resize (resizeSourceWindow) always has room to grow the window into
        // without needing to change the display's own resolution mid-session.
        //
        // That used to be handled by re-applying a bigger CGVirtualDisplayMode at resize time
        // (VirtualDisplayHost.resize), on the theory that it's the same applySettings call used
        // at creation, just invoked again — the pattern BetterDisplay/DeskPad document for this
        // private API. In practice that didn't reliably take effect against a display an SCStream
        // was already actively capturing (bounds/config staying pinned at the original mode), so
        // a PiP resize would track correctly only up to whatever slack the *initial* size
        // happened to leave, then silently clamp there — "changes a bit, then stops matching the
        // panel" is exactly that ceiling being hit. Starting at the ceiling instead sidesteps the
        // question entirely: SCStreamConfiguration.sourceRect already crops the capture down to
        // just the window's own rect regardless of how big the underlying display canvas is (see
        // makeConfiguration), so there's no meaningful capture-bandwidth cost to the display being
        // bigger than the window actually needs.
        //
        // CGVirtualDisplay must be created on the main thread — off-main creation was
        // observed to silently produce a display that never shows up in
        // SCShareableContent's display list.
        let host = try await MainActor.run { () -> VirtualDisplayHost in
            guard let host = VirtualDisplayHost(
                pixelWidth: VirtualDisplayHost.maxPixelsWide,
                pixelHeight: VirtualDisplayHost.maxPixelsHigh,
                name: "AnyPiP – \(windowInfo.ownerAppName)"
            ) else {
                throw CaptureSessionError.virtualDisplayCreationFailed
            }
            return host
        }
        virtualDisplayHost = host

        try await moveWindowOntoVirtualDisplay(host: host, axWindow: axWindow, size: currentPiPSize)
        presentationState = .pip
        startFrameWatch(axWindow: axWindow, host: host)
        observeScreenParameterChanges()

        let scDisplay = try await Self.waitForShareableDisplay(matching: host.displayID)

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let config = Self.makeConfiguration(for: framedRect, displaySize: host.bounds.size, fps: targetFPS)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
        startStallWatchdog()
        AnyPiPLogger.capture.info("Capture started for window \(self.windowInfo.id) (\(self.windowInfo.ownerAppName)) via virtual display \(host.displayID)")
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
    private func moveWindowOntoVirtualDisplay(host: VirtualDisplayHost, axWindow: AXUIElement, size: CGSize) async throws {
        let margin = VirtualDisplayHost.menuBarInset
        let bounds = try await Self.waitForValidBounds(of: host)

        let targetOrigin = CGPoint(x: bounds.origin.x + Self.edgeMargin, y: bounds.origin.y + margin)
        let targetFrame = CGRect(origin: targetOrigin, size: size)
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
        guard presentationState == .pip, let current = AXWindowLocator.frame(of: axWindow) else { return }
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

    /// Destroying one session's CGVirtualDisplay (M4: another session's stop()) can make macOS
    /// reflow the global desktop arrangement — the same way unplugging a physical monitor shifts
    /// where the *remaining* ones sit. VirtualDisplayHost.bounds already reads that shift live,
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
        guard presentationState == .pip, !isReanchoring,
              let host = virtualDisplayHost, let axWindow else { return }
        isReanchoring = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isReanchoring = false }
            do {
                try await self.moveWindowOntoVirtualDisplay(host: host, axWindow: axWindow, size: self.currentPiPSize)
                try await self.applyConfiguration()
            } catch {
                AnyPiPLogger.capture.error("Failed to re-anchor window \(self.windowInfo.id) after display reconfiguration: \(error)")
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
        do {
            try await moveWindowOntoVirtualDisplay(host: host, axWindow: axWindow, size: currentPiPSize)
            if let stream {
                let config = Self.makeConfiguration(for: framedRect, displaySize: host.bounds.size, fps: targetFPS)
                try await stream.updateConfiguration(config)
            }
            presentationState = .pip
            startFrameWatch(axWindow: axWindow, host: host)
        } catch {
            AnyPiPLogger.capture.error("Failed to resume PiP for window \(self.windowInfo.id): \(error)")
        }
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
    func resizeSourceWindow(to panelSize: CGSize) {
        pendingResizeSize = panelSize
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
        guard presentationState == .pip, let axWindow, let host = virtualDisplayHost,
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
        let actualFrame = await commitSourceWindowSize(targetSize, axWindow: axWindow, displayOrigin: bounds.origin)
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
    private func clampToDeliverableSize(_ size: CGSize, within bounds: CGRect) -> CGSize {
        let maxWidth = max(bounds.width - framedRect.origin.x - Self.edgeMargin, 1)
        let maxHeight = max(bounds.height - framedRect.origin.y - Self.edgeMargin, 1)
        let clamped = CGSize(width: min(size.width, maxWidth), height: min(size.height, maxHeight))
        if clamped.width < size.width - 1 || clamped.height < size.height - 1 {
            debugTrace("grow: clampToDeliverableSize CLAMPED requested=\(size) -> \(clamped) maxWidth=\(maxWidth) maxHeight=\(maxHeight) framedRectOrigin=\(framedRect.origin) boundsSize=\(bounds.size)")
        }
        return clamped
    }

    /// The same ceiling clampToDeliverableSize enforces per-tick, exposed so PiPPanelController
    /// can correct panel.maxSize to match. panel.maxSize is set once, at panel-creation time,
    /// before the virtual display even exists yet — it has to assume VirtualDisplayHost's
    /// aspirational maxPixelsWide/maxPixelsHigh ceiling, since nothing more specific is known yet.
    /// CGVirtualDisplay is an undocumented private API with no guarantee it honors the exact mode
    /// requested — observed in practice: with several concurrent PiP sessions' virtual displays
    /// active, a newly-created one's live bounds sometimes come back smaller than what was
    /// requested (likely some internal resource limit). If that happens, the panel would otherwise
    /// keep being draggable well past what this backend can actually deliver, forever silently
    /// clamped by clampToDeliverableSize while looking, to the user, exactly like the source
    /// window simply refusing to keep up — the same failure mode as an undiscovered app-level
    /// ceiling, just caused by the display instead of the app.
    var deliverableMaxSize: CGSize? {
        guard let bounds = virtualDisplayHost?.bounds, framedRect.width > 0 else { return nil }
        return CGSize(
            width: max(bounds.width - framedRect.origin.x - Self.edgeMargin, 1),
            height: max(bounds.height - framedRect.origin.y - Self.edgeMargin, 1)
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
    private func commitSourceWindowSize(_ targetSize: CGSize, axWindow: AXUIElement, displayOrigin: CGPoint) async -> CGRect {
        let previousActual = framedRect.size
        let absoluteOrigin = CGPoint(x: displayOrigin.x + framedRect.origin.x, y: displayOrigin.y + framedRect.origin.y)
        let requestedFrame = CGRect(origin: absoluteOrigin, size: targetSize)
        AXWindowLocator.setSize(targetSize, on: axWindow)
        try? await Task.sleep(nanoseconds: 80_000_000)
        let actualFrame = AXWindowLocator.frame(of: axWindow) ?? requestedFrame
        debugTrace("grow: commitSourceWindowSize target=\(targetSize) actual=\(actualFrame.size) previousActual=\(previousActual) axWindowFrameReadOK=\(AXWindowLocator.frame(of: axWindow) != nil)")

        let tolerance: CGFloat = 1
        var discoveredFloor = false
        if actualFrame.width > targetSize.width + tolerance {
            debugTrace("grow: discovered WIDTH floor actual=\(actualFrame.width) target=\(targetSize.width)")
            discoveredMinWidth = actualFrame.width
            discoveredFloor = true
        }
        if actualFrame.height > targetSize.height + tolerance {
            debugTrace("grow: discovered HEIGHT floor actual=\(actualFrame.height) target=\(targetSize.height)")
            discoveredMinHeight = actualFrame.height
            discoveredFloor = true
        }
        if discoveredFloor {
            let discovered = CGSize(width: discoveredMinWidth ?? 0, height: discoveredMinHeight ?? 0)
            let reportDiscovery = onSourceMinSizeDiscovered
            Task { @MainActor in reportDiscovery?(discovered) }
        }

        var discoveredCeiling = false
        if targetSize.width > previousActual.width + tolerance, abs(actualFrame.width - previousActual.width) < tolerance {
            debugTrace("grow: discovered WIDTH ceiling actual=\(actualFrame.width) target=\(targetSize.width)")
            discoveredMaxWidth = actualFrame.width
            discoveredCeiling = true
        }
        if targetSize.height > previousActual.height + tolerance, abs(actualFrame.height - previousActual.height) < tolerance {
            debugTrace("grow: discovered HEIGHT ceiling actual=\(actualFrame.height) target=\(targetSize.height)")
            discoveredMaxHeight = actualFrame.height
            discoveredCeiling = true
        }
        if discoveredCeiling {
            let discovered = CGSize(width: discoveredMaxWidth ?? .infinity, height: discoveredMaxHeight ?? .infinity)
            let reportDiscovery = onSourceMaxSizeDiscovered
            Task { @MainActor in reportDiscovery?(discovered) }
        }

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
    /// server finishes registering the display's geometry.
    private static func waitForValidBounds(of host: VirtualDisplayHost) async throws -> CGRect {
        for attempt in 0..<10 {
            let bounds = host.bounds
            if bounds.width > 0, bounds.height > 0 {
                return bounds
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
        stallTimer?.cancel()
        stallTimer = nil
        stopFrameWatch()
        stopObservingScreenParameterChanges()
        if let stream {
            self.stream = nil
            try? await stream.stopCapture()
        }
        restoreWindowIfNeeded()
        virtualDisplayHost = nil // deallocating tears the virtual display down
        AnyPiPLogger.capture.info("Capture stopped for window \(self.windowInfo.id)")
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

    private func applyConfiguration() async throws {
        guard let stream, let host = virtualDisplayHost else { return }
        let config = Self.makeConfiguration(for: framedRect, displaySize: host.bounds.size, fps: targetFPS)
        try await stream.updateConfiguration(config)
    }

    private static func makeConfiguration(for localRect: CGRect, displaySize: CGSize, fps: Int) -> SCStreamConfiguration {
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

        let maxLongEdge: CGFloat = 1280
        let longEdge = max(sourceRect.width, sourceRect.height)
        let scale = longEdge > maxLongEdge ? maxLongEdge / longEdge : 1
        config.width = max(Int(sourceRect.width * scale), 2)
        config.height = max(Int(sourceRect.height * scale), 2)
        return config
    }

    private func startStallWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: sampleQueue)
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastFrameDate) > 3 {
                AnyPiPLogger.capture.warning("No frames received for 3s+ for window \(self.windowInfo.id)")
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
        AnyPiPLogger.capture.error("Stream stopped with error: \(error.localizedDescription)")
        delegate?.captureSessionDidStop(self, error: error)
    }
}
