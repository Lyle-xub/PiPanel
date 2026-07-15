import AppKit
import CoreGraphics

/// AppKit's NSScreen list can lag behind CoreGraphics after a virtual display is created. Keep the
/// identities of this process's live displays independently so a later PiP session can still read
/// their current CGDisplayBounds and reserve a distinct part of the global desktop.
private final class ActiveVirtualDisplayRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var displayIDs: Set<CGDirectDisplayID> = []

    func insert(_ displayID: CGDirectDisplayID) {
        lock.lock()
        displayIDs.insert(displayID)
        lock.unlock()
    }

    func remove(_ displayID: CGDirectDisplayID) {
        lock.lock()
        displayIDs.remove(displayID)
        lock.unlock()
    }

    func currentFrames() -> [CGDirectDisplayID: CGRect] {
        lock.lock()
        let ids = displayIDs
        lock.unlock()

        return Dictionary(uniqueKeysWithValues: ids.compactMap { displayID in
            let frame = CGDisplayBounds(displayID)
            guard frame.width > 0, frame.height > 0 else { return nil }
            return (displayID, frame)
        })
    }

    func currentIDs() -> Set<CGDirectDisplayID> {
        lock.lock()
        let ids = displayIDs
        lock.unlock()
        return ids
    }
}

/// Owns one CGVirtualDisplay for the lifetime of a PiP session. The virtual display is a
/// genuinely independent, always-composited display — unlike a window's real display, it never
/// goes "inactive" when the user full-screens something else on their physical screen, which is
/// what makes live capture survive full-screen elsewhere (verified in Spikes/VirtualDisplaySpike;
/// SCContentFilter(desktopIndependentWindow:) — the API nominally designed for this — was found
/// to be broken on this OS build, stalling after one status-only frame).
///
/// The virtual display is torn down as soon as this object is deallocated, so callers must hold
/// a strong reference for as long as the session is active.
final class VirtualDisplayHost {
    private static let activeVirtualDisplays = ActiveVirtualDisplayRegistry()

    /// Includes both leased displays and the pre-warmed idle pool. Callers choosing a physical
    /// monitor must exclude this complete set rather than looking only at active PiP sessions.
    static var activeDisplayIDs: Set<CGDirectDisplayID> {
        activeVirtualDisplays.currentIDs()
    }

    static func isManagedDisplay(_ screen: NSScreen) -> Bool {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return false
        }
        return activeDisplayIDs.contains(CGDirectDisplayID(number.uint32Value))
    }

    let displayID: CGDirectDisplayID
    private let virtualDisplay: CGVirtualDisplay

    /// Converts the virtual mode's backing-pixel dimensions into the global desktop coordinate
    /// space used by AX window frames and SCStreamConfiguration.sourceRect. Every PiPanel display
    /// is explicitly configured as HiDPI: 2560×1600 backing pixels become a 1280×800 logical
    /// desktop, so pixels and window points must not be treated as interchangeable.
    private var pointsPerPixel = CGSize(width: 1, height: 1)
    private var hasCalibratedCoordinateScale = false

    /// One other currently-active display's own identity and placement, as observed at some
    /// specific moment — see preCreationDisplays' own doc comment for why *when* that snapshot was
    /// taken matters so much here.
    private typealias DisplaySnapshot = (id: CGDirectDisplayID, origin: CGPoint, frame: CGRect)

    /// The arrangement of every *other* real/virtual display, captured at the very start of init —
    /// before CGVirtualDisplay.apply(settings:) ever runs — not a fresh read taken later, once
    /// positionOutsideExistingDisplays actually needs it. This is the fix for a second, distinct
    /// regression positionOutsideExistingDisplays's own re-affirm-every-origin logic didn't
    /// catch: /tmp/pipanel_trace.log's own mainDisplayIDBefore/mainDisplayIDAfter logging showed the
    /// main-display flip (and the accompanying "built-in display shoved to the far left" reflow)
    /// had *already happened* by the time that method's own fresh NSScreen.screens read ran — one
    /// trace line even caught CGMainDisplayID() reporting the brand-new virtual display itself as
    /// main, before this class's own repositioning code had touched anything. That means the
    /// disruption is a side effect of CGVirtualDisplay.apply(settings:) below, not of
    /// CGConfigureDisplayOrigin — apply(_:)'s own automatic placement heuristic appears to consult
    /// whichever screen was "active" at that exact moment (matching the user's own observation that
    /// triggering PiP from the secondary display, specifically, is what reproduces this), and
    /// reshuffles the *entire* arrangement, main display included, before this class ever gets a
    /// chance to run. Re-affirming origins read *after* that already-corrupted point (the previous
    /// version) just re-declares the corruption as if it were correct. Capturing the true
    /// arrangement first and restoring *that* snapshot (not "whatever's currently observed") is the
    /// only way to actually undo it regardless of what apply(_:) did in between.
    private let preCreationDisplays: [DisplaySnapshot]
    /// The user's real main display before CGVirtualDisplay.apply(_:) gets a chance to
    /// temporarily promote the new virtual display to main. Direction decisions must use this
    /// stable identity rather than calling CGMainDisplayID() after creation.
    private let preCreationMainDisplayID: CGDirectDisplayID
    /// IDs already owned by PiPanel before this host was created. They still participate in the
    /// outer-bound calculation (so hosts never overlap), but must not influence whether the user's
    /// real desktop is considered horizontally or vertically arranged.
    private let preCreationManagedDisplayIDs: Set<CGDirectDisplayID>

    /// This object's own record of the size it last successfully told the display to be — the
    /// source of truth for `bounds`'s size component. See `bounds`'s doc comment for why a live
    /// CGDisplayBounds read can't be trusted for this past the very first reading.
    private(set) var currentPixelSize: CGSize
    /// The compositor refresh rate requested for this virtual display. It is initialized from the
    /// fastest currently-connected physical display so a 120/144 Hz source session is not silently
    /// bottlenecked by the old hardcoded 60 Hz virtual mode.
    private(set) var currentRefreshRate: Double

    /// True once the window server has registered real geometry for this display —
    /// CGDisplayBounds can read all-zero for a brief moment right after creation
    /// (waitForValidBounds's own reason for existing).
    var isGeometryRegistered: Bool {
        let raw = CGDisplayBounds(displayID)
        return raw.width > 0 && raw.height > 0
    }

    /// The display's current bounds in global Quartz coordinate space: origin read live from
    /// CGDisplayBounds, size derived from currentPixelSize using the pixel-to-point scale captured
    /// when the display first registers with the window server.
    ///
    /// Origin and size need different treatment because they behave differently after a live
    /// resize(pixelWidth:pixelHeight:) call. Verified in Spikes/VirtualDisplayResizeSpike:
    /// re-applying a bigger CGVirtualDisplayMode against an already-running (possibly already
    /// SCStream-capturing) display does genuinely grow its real, capturable canvas — a running
    /// stream immediately starts delivering full frames at the new size, containing real desktop
    /// content across the whole new area — but CGDisplayBounds's *size* component never updates to
    /// reflect that, no matter how long you poll it (confirmed identical readings 5s later). So
    /// size has to be tracked independently, or every placement/clamp calculation elsewhere in this
    /// app (CaptureSession's moveWindowOntoVirtualDisplay, clampToDeliverableSize,
    /// deliverableMaxSize, ...) would keep measuring against the display's stale original size
    /// forever after the first resize.
    ///
    /// Origin is the opposite case: it must stay a *live* CGDisplayBounds read, not cached. Unlike
    /// size, a display's origin can genuinely change after creation — CaptureSession's own
    /// reanchorAfterDisplayReconfiguration doc comment documents macOS reflowing the whole desktop
    /// arrangement (and therefore this display's origin) whenever a sibling PiP session's virtual
    /// display is created or destroyed (M4: multi-session). Caching origin once, the same way size
    /// is now tracked, was tried and reverted: it left every *other* already-open session's window
    /// placement/crop math computed against a stale pre-reflow origin the moment a new session was
    /// opened, which read as the older PiP's mirrored content drifting into/off of its own frame.
    ///
    /// The live CGDisplayBounds size is sampled only once, for coordinate calibration. It is not
    /// reused as the display's changing capacity because it remains stale after a live mode resize.
    /// The applied pixel mode remains the capacity source of truth; the stable calibration merely
    /// translates that capacity into the point space in which AX windows actually resize.
    var bounds: CGRect {
        let rawBounds = CGDisplayBounds(displayID)
        return CGRect(
            origin: rawBounds.origin,
            size: Self.coordinateSize(pixelSize: currentPixelSize, pointsPerPixel: pointsPerPixel)
        )
    }

    /// The backing-pixel density ScreenCaptureKit must use when converting a crop expressed in
    /// desktop points into an output buffer expressed in pixels. On the virtual HiDPI display this
    /// is normally 2×; exposing it separately keeps window placement in points while preserving
    /// the display's full native detail in the captured frame.
    var pixelsPerPoint: CGSize {
        CGSize(
            width: pointsPerPixel.width > 0 ? 1 / pointsPerPixel.width : 1,
            height: pointsPerPixel.height > 0 ? 1 / pointsPerPixel.height : 1
        )
    }

    static func coordinateSize(pixelSize: CGSize, pointsPerPixel: CGSize) -> CGSize {
        CGSize(
            width: pixelSize.width * pointsPerPixel.width,
            height: pixelSize.height * pointsPerPixel.height
        )
    }

    static func coordinateScale(registeredSize: CGSize, descriptorPixelSize: CGSize) -> CGSize {
        guard descriptorPixelSize.width > 0, descriptorPixelSize.height > 0 else {
            return CGSize(width: 1, height: 1)
        }
        return CGSize(
            width: registeredSize.width / descriptorPixelSize.width,
            height: registeredSize.height / descriptorPixelSize.height
        )
    }

    private func calibrateCoordinateScaleIfNeeded() {
        guard !hasCalibratedCoordinateScale else { return }
        let registeredBounds = CGDisplayBounds(displayID)
        guard registeredBounds.width > 0, registeredBounds.height > 0,
              currentPixelSize.width > 0, currentPixelSize.height > 0 else { return }
        // Calibrate against the descriptor's fixed pixel ceiling, not the mode selected by the
        // settings slider. CGDisplayBounds reports the same 1280×800 logical desktop for several
        // different initial modes (observed for 2560, 2048, 1792 and 1408-wide modes). Dividing by
        // the selected mode therefore normalizes every slider value back to that same 1280×800
        // workspace and makes the setting appear to do nothing. The descriptor ceiling is stable
        // for the host's lifetime, so it gives every mode one common conversion scale instead.
        pointsPerPixel = Self.coordinateScale(
            registeredSize: registeredBounds.size,
            descriptorPixelSize: CGSize(width: Self.maxPixelsWide, height: Self.maxPixelsHigh)
        )
        hasCalibratedCoordinateScale = true
        debugTrace("vdisplay: calibrated coordinate scale pointsPerPixel=\(pointsPerPixel) registeredBounds=\(registeredBounds) descriptorPixelCeiling=(\(Self.maxPixelsWide), \(Self.maxPixelsHigh)) selectedPixelSize=\(currentPixelSize)")
    }

    /// menuBarInset accounts for the strip at the top of every display (real or virtual) that
    /// macOS reserves for a menu bar — window content should be positioned below it so capture
    /// cropping doesn't clip the window's own title bar against it.
    static let menuBarInset: CGFloat = 44

    /// The display is created at a generous, fixed "biggest normal monitor" canvas by default
    /// (CaptureSession.start() passes SettingsStore.virtualDisplayLongEdge-derived dimensions,
    /// which default to this) rather than one sized to the captured window, so a later PiP-panel
    /// resize (CaptureSession.resizeSourceWindow) always has room to grow the window into without
    /// necessarily needing to change the display's own resolution mid-session. It *can* also be
    /// changed live via resize(pixelWidth:pixelHeight:) below — see that method and `bounds`'s own
    /// doc comments for why an earlier attempt at this looked broken and wasn't.
    /// SCStreamConfiguration.sourceRect already crops the capture down to just the window's own
    /// rect regardless of how big this canvas is (see makeConfiguration), so there's no meaningful
    /// capture-bandwidth cost to a generous ceiling.
    static let maxPixelsWide = 2560
    static let maxPixelsHigh = 1600
    static let backingScaleFactor: CGFloat = 2
    static let hiDPISetting = 1

    /// Converts a user-chosen long-edge pixel value (SettingsStore.virtualDisplayLongEdge) into a
    /// concrete (width, height) pair, holding the canvas at the same 2560:1600 aspect ratio this
    /// display has always used — only the overall size is user-adjustable, not the shape, so
    /// nothing about menuBarInset/edgeMargin placement math elsewhere has to change.
    static func pixelSize(forLongEdge longEdge: CGFloat) -> (width: Int, height: Int) {
        let width = Int(longEdge)
        let height = Int((longEdge / CGFloat(maxPixelsWide) * CGFloat(maxPixelsHigh)).rounded())
        return (width, height)
    }

    /// Each concurrent session needs its own (vendorID, productID, serialNum) identity — reusing
    /// the same triple for multiple simultaneous virtual displays risks macOS treating them as
    /// "the same display" reappearing rather than genuinely separate ones (M4: multi-session).
    private static var nextSerialNum: UInt32 = 1

    init?(
        pixelWidth: Int,
        pixelHeight: Int,
        name: String,
        refreshRate: Double = Double(DisplayRefreshRate.maximumPhysicalFPS())
    ) {
        currentPixelSize = CGSize(width: pixelWidth, height: pixelHeight)
        currentRefreshRate = max(refreshRate, 1)
        // Must happen before anything below touches CGVirtualDisplay at all — see
        // preCreationDisplays' own doc comment for why.
        preCreationMainDisplayID = CGMainDisplayID()
        preCreationManagedDisplayIDs = Self.activeDisplayIDs
        preCreationDisplays = Self.otherActiveDisplays(excluding: kCGNullDirectDisplay)
        debugTrace("vdisplay: pre-creation arrangement \(preCreationDisplays.map { ($0.id, $0.frame) })")
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.name = name
        descriptor.maxPixelsWide = UInt32(Self.maxPixelsWide)
        descriptor.maxPixelsHigh = UInt32(Self.maxPixelsHigh)
        descriptor.sizeInMillimeters = CGSize(width: CGFloat(Self.maxPixelsWide) / 4, height: CGFloat(Self.maxPixelsHigh) / 4)
        descriptor.serialNum = Self.nextSerialNum
        Self.nextSerialNum += 1
        // Product ID 2 identifies the fixed-HiDPI display schema. Keeping it distinct from the
        // previous product ID prevents WindowServer from restoring a cached 1× mode for one of
        // the old serial identities.
        descriptor.productID = 0x2
        descriptor.vendorID = 0x1AE7 // arbitrary, unregistered vendor ID block

        virtualDisplay = CGVirtualDisplay(descriptor: descriptor)

        let mode = CGVirtualDisplayMode(
            width: pixelWidth,
            height: pixelHeight,
            refreshRate: currentRefreshRate
        )
        let settings = CGVirtualDisplaySettings()
        settings.modes = [mode]
        settings.hiDPI = Self.hiDPISetting
        guard virtualDisplay.apply(settings) else { return nil }

        displayID = virtualDisplay.displayID
        guard displayID != kCGNullDirectDisplay else { return nil }
        // Register immediately after the display has a real identity. Session startup is
        // serialized, so by the time the next host takes its pre-creation snapshot this one has
        // completed positioning; reading CGDisplayBounds then bypasses NSScreen's observed lag.
        Self.activeVirtualDisplays.insert(displayID)

        // Defense in depth: a small (roughly window-sized) virtual display was observed to
        // sometimes make macOS mirror the physical display onto it instead of extending it
        // (shrinking the user's real screen) — CaptureSession now always requests a "normal
        // monitor" floor size specifically to avoid that, but explicitly disabling mirroring
        // here too costs nothing if it's a no-op.
        var config: CGDisplayConfigRef?
        if CGBeginDisplayConfiguration(&config) == .success, let config {
            CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay)
            CGCompleteDisplayConfiguration(config, .forSession)
        }
        // Explicit outside-of-existing-displays positioning happens separately, in
        // positionOutsideExistingDisplays(), called once the display is confirmed *registered*
        // (CaptureSession.waitForValidBounds/isGeometryRegistered) — see that method's own doc
        // comment for why attempting it here, synchronously and immediately after creation, doesn't
        // work.
    }

    deinit {
        Self.activeVirtualDisplays.remove(displayID)
    }

    /// Explicitly places this virtual display just outside the user's physical display topology:
    /// horizontal real displays continue left/right, while vertically stacked real displays
    /// continue above/below. Existing PiPanel displays extend that same outer edge so multiple
    /// virtual displays never overlap. This avoids trusting the unpredictable automatic position
    /// macOS chooses when another monitor is connected.
    /// CGConfigureDisplayOrigin is the same public, documented API System Settings' own
    /// Displays > Arrangement pane uses to reposition a display within the current layout, so
    /// unlike everything else in this file it needs no private-API bridging.
    ///
    /// Must be called only *after* the display is confirmed registered with the window server
    /// (CaptureSession.waitForValidBounds polls exactly this via isGeometryRegistered) — an earlier
    /// version called this synchronously from init, immediately after CGVirtualDisplay.apply(_:)
    /// returned true, and /tmp/pipanel_trace.log showed CGConfigureDisplayOrigin failing every
    /// single time with error 1001 (kCGErrorIllegalArgument), silently falling back to whatever
    /// arbitrary spot macOS's own default placement heuristic picked instead — which is exactly the
    /// "wedged between my two real monitors" symptom this was reported as causing. apply(_:)
    /// returning true only means the requested mode was *accepted*, not that the window server has
    /// finished registering the display as a real, addressable member of the display arrangement
    /// yet (the same asynchronous-registration gap CGDisplayBounds' own doc comment already
    /// documents for reading a virtual display's geometry) — CGConfigureDisplayOrigin apparently
    /// needs that same registration to have completed before it'll accept a target display at all.
    ///
    /// Also re-affirms every *other* currently-active display's own current origin within the same
    /// configuration transaction, not just this new display's — a version that only configured this
    /// one display's origin was reported to have a second, separate side effect: it silently forced
    /// the built-in display back to being the main display (the one at global origin (0,0)),
    /// overriding whatever the user had actually configured in System Settings, regardless of how
    /// the other real monitor was arranged. A CGBeginDisplayConfiguration/CGCompleteDisplay
    /// Configuration transaction declares a *complete* arrangement, the same way System Settings'
    /// own Displays > Arrangement pane does — any display left unmentioned in the transaction
    /// appears to get renormalized by macOS to some default layout rather than simply left alone,
    /// and "which display is main" is exactly the kind of global fact that renormalization can
    /// reset. Explicitly telling the transaction each existing display's own unchanged origin closes
    /// that gap: nothing is left implicit for macOS to re-decide.
    /// Guards this method to a single genuine invocation per host — see its own doc comment just
    /// below for why calling it more than once is actively harmful, not just redundant.
    private var hasPositioned = false

    func positionOutsideExistingDisplays() {
        // This is the first point at which isGeometryRegistered has already succeeded, so the
        // window server's initial logical size is available for a reliable pixel→point calibration.
        calibrateCoordinateScaleIfNeeded()
        // Idempotent by design, not just "cheap to skip": this method's own
        // CGCompleteDisplayConfiguration call is itself a global display-configuration change, which
        // fires NSApplication.didChangeScreenParametersNotification for every open session
        // (CaptureSession.observeScreenParameterChanges). That handler
        // (reanchorAfterDisplayReconfiguration) re-places the real source window via
        // moveWindowOntoVirtualDisplay, which calls waitForValidBounds, which — before this guard
        // existed — called back into this exact method again on an already-registered host,
        // producing a self-sustaining loop: reposition → notification → reanchor → reposition →
        // notification → ... With two or more sessions open, each one's reposition also retriggers
        // every *other* session's reanchor, roughly doubling the cadence — confirmed via
        // /tmp/pipanel_trace.log as the cause of a real regression: source windows inside PiP
        // visibly jittering/jumping position continuously once a second session was open, tracked
        // to repeated "positionOutsideExistingDisplays" log lines for both displays interleaved
        // with "grow: refreshFramedRectIfNeeded" lines snapping the window back each time. The
        // actual arrangement-correcting work below is only ever needed once, right after
        // CGVirtualDisplay.apply(settings:)'s own disruptive placement — waitForValidBounds's later
        // calls (from reanchorAfterDisplayReconfiguration) only need bounds's own live origin read,
        // which already tracks genuine reflows (another session's display being torn down, etc.)
        // without needing to actively re-declare the whole arrangement again.
        guard !hasPositioned else { return }
        hasPositioned = true
        // preCreationDisplays, not a fresh Self.otherActiveDisplays(excluding:) read — see that
        // property's own doc comment for why a snapshot taken now, after CGVirtualDisplay.apply(_:)
        // has already run, can no longer be trusted to reflect the arrangement as the user actually
        // configured it.
        let others = preCreationDisplays
        let physicalFrames = Dictionary(uniqueKeysWithValues: others.compactMap { display -> (CGDirectDisplayID, CGRect)? in
            guard !preCreationManagedDisplayIDs.contains(display.id) else { return nil }
            return (display.id, display.frame)
        })
        let managedFrames = Dictionary(uniqueKeysWithValues: others.compactMap { display -> (CGDirectDisplayID, CGRect)? in
            guard preCreationManagedDisplayIDs.contains(display.id) else { return nil }
            return (display.id, display.frame)
        })
        // Display arrangement is expressed in CGDisplayBounds' topology space. On the fixed-HiDPI
        // virtual display that is currently 2560×1600, even though AX window placement uses the
        // calibrated 1280×800 logical `bounds` size. Passing the logical size here makes the next
        // vertical slot overlap the preceding display by 800 points; WindowServer resolves that
        // overlap by pushing the display sideways, which is exactly the staggered arrangement the
        // user sees in System Settings.
        let registeredBounds = CGDisplayBounds(displayID)
        let topologySize = Self.topologySize(
            registeredBounds: registeredBounds,
            logicalSize: bounds.size
        )
        let targetOrigin = Self.placementOrigin(
            physicalFrames: physicalFrames,
            managedFrames: managedFrames,
            mainDisplayID: preCreationMainDisplayID,
            newDisplaySize: topologySize
        )
        let mainDisplayIDBefore = CGMainDisplayID()

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else {
            debugTrace("vdisplay: positionOutsideExistingDisplays CGBeginDisplayConfiguration FAILED displayID=\(displayID)")
            return
        }
        for other in others {
            CGConfigureDisplayOrigin(config, other.id, Int32(other.origin.x), Int32(other.origin.y))
        }
        let originResult = CGConfigureDisplayOrigin(
            config,
            displayID,
            Int32(targetOrigin.x.rounded()),
            Int32(targetOrigin.y.rounded())
        )
        let completeResult = CGCompleteDisplayConfiguration(config, .forSession)

        let mainDisplayIDAfter = CGMainDisplayID()
        debugTrace("vdisplay: positionOutsideExistingDisplays displayID=\(displayID) physicalFrames=\(physicalFrames) managedFrames=\(managedFrames) topologySize=\(topologySize) targetOrigin=\(targetOrigin) originResult=\(originResult.rawValue) completeResult=\(completeResult.rawValue) postBounds=\(CGDisplayBounds(displayID)) mainDisplayIDBefore=\(mainDisplayIDBefore) mainDisplayIDAfter=\(mainDisplayIDAfter)")
    }

    enum PlacementEdge: Equatable {
        case left
        case right
        case above
        case below
    }

    /// Chooses the dominant arrangement axis from physical display centers, then continues toward
    /// the side already occupied away from the main display. Quartz Y grows downward, hence
    /// `.above` uses the minimum Y edge and `.below` the maximum Y edge.
    static func preferredPlacementEdge(
        physicalFrames: [CGDirectDisplayID: CGRect],
        mainDisplayID: CGDirectDisplayID
    ) -> PlacementEdge {
        guard physicalFrames.count > 1,
              let mainFrame = physicalFrames[mainDisplayID] ?? physicalFrames.values.first else {
            return .right
        }

        let centers = physicalFrames.values.map { CGPoint(x: $0.midX, y: $0.midY) }
        let horizontalSpread = (centers.map(\.x).max() ?? 0) - (centers.map(\.x).min() ?? 0)
        let verticalSpread = (centers.map(\.y).max() ?? 0) - (centers.map(\.y).min() ?? 0)

        if verticalSpread > horizontalSpread {
            let distanceAbove = mainFrame.midY - (physicalFrames.values.map(\.minY).min() ?? mainFrame.minY)
            let distanceBelow = (physicalFrames.values.map(\.maxY).max() ?? mainFrame.maxY) - mainFrame.midY
            return distanceBelow >= distanceAbove ? .below : .above
        }

        let distanceLeft = mainFrame.midX - (physicalFrames.values.map(\.minX).min() ?? mainFrame.minX)
        let distanceRight = (physicalFrames.values.map(\.maxX).max() ?? mainFrame.maxX) - mainFrame.midX
        return distanceRight >= distanceLeft ? .right : .left
    }

    /// The arrangement transaction uses the registered display's topology size, not the smaller
    /// logical coordinate size used for AX windows on a HiDPI display.
    static func topologySize(registeredBounds: CGRect, logicalSize: CGSize) -> CGSize {
        guard registeredBounds.width > 0, registeredBounds.height > 0 else { return logicalSize }
        return registeredBounds.size
    }

    /// Returns an integral global Quartz origin outside all current displays. `physicalFrames`
    /// selects direction. Once a PiPanel display exists, the virtual stack continues from and
    /// aligns with that display instead of re-anchoring to a physical display whose global origin
    /// macOS may have rebased while the previous virtual display was connected.
    static func placementOrigin(
        physicalFrames: [CGDirectDisplayID: CGRect],
        managedFrames: [CGDirectDisplayID: CGRect],
        mainDisplayID: CGDirectDisplayID,
        newDisplaySize: CGSize
    ) -> CGPoint {
        let mainFrame = physicalFrames[mainDisplayID]
            ?? physicalFrames.values.first
            ?? .zero
        let managedAnchor = managedFrames.min { $0.key < $1.key }?.value
        let occupied = managedFrames.isEmpty ? Array(physicalFrames.values) : Array(managedFrames.values)

        switch preferredPlacementEdge(physicalFrames: physicalFrames, mainDisplayID: mainDisplayID) {
        case .right:
            return CGPoint(
                x: occupied.map(\.maxX).max() ?? mainFrame.maxX,
                y: managedAnchor?.minY ?? mainFrame.minY
            )
        case .left:
            return CGPoint(
                x: (occupied.map(\.minX).min() ?? mainFrame.minX) - newDisplaySize.width,
                y: managedAnchor?.minY ?? mainFrame.minY
            )
        case .above:
            return CGPoint(
                x: managedAnchor?.minX ?? mainFrame.minX,
                y: (occupied.map(\.minY).min() ?? mainFrame.minY) - newDisplaySize.height
            )
        case .below:
            return CGPoint(
                x: managedAnchor?.minX ?? mainFrame.minX,
                y: occupied.map(\.maxY).max() ?? mainFrame.maxY
            )
        }
    }

    /// Every currently-active display except excludedDisplayID, with its own current (displayID,
    /// origin, frame) — called exactly once, from init, to build preCreationDisplays (see that
    /// property's own doc comment for why that specific moment, and no other, is when this is safe
    /// to trust); excludedDisplayID is kCGNullDirectDisplay there since nothing needs excluding yet.
    ///
    /// Starts with NSScreen.screens, not CGGetActiveDisplayList, despite everything this feeds into
    /// being CG-level calls — a CGGetActiveDisplayList-based version was tried first and
    /// reported still wrong: it consistently placed only the very *first* virtual display created in
    /// a fresh run to the right of just the main display, ignoring an already-connected second
    /// monitor, while every later virtual display (by which point CGGetActiveDisplayList had already
    /// been called at least once before) correctly saw the full arrangement. That's the same "first
    /// call to a low-level CoreGraphics/ScreenCaptureKit display API in this process returns an
    /// incomplete or stale snapshot" pattern this app has already hit more than once elsewhere
    /// (CGDisplayBounds reading all-zero right after a virtual display's own creation,
    /// SCShareableContent's first sighting of a fresh display reporting a placeholder size) —
    /// CGGetActiveDisplayList apparently isn't exempt. NSScreen.screens is AppKit's own,
    /// independently-maintained screen list and is the more reliable source for discovering the
    /// complete set of physical display IDs; each ID's frame is then read from CGDisplayBounds so
    /// it is already in Quartz topology coordinates.
    /// It can still lag specifically after creating a virtual display, though: a real trace showed
    /// display 819 alive at x=1920 while the next session's NSScreen snapshot omitted it and placed
    /// display 820 at the same x=1920. The process-local registry supplies live CGDisplayBounds for
    /// those PiPanel-owned displays only, while NSScreen remains authoritative for discovering the
    /// physical display set.
    static func mergedActiveDisplayFrames(
        observed: [CGDirectDisplayID: CGRect],
        registeredVirtual: [CGDirectDisplayID: CGRect],
        excluding excludedDisplayID: CGDirectDisplayID
    ) -> [CGDirectDisplayID: CGRect] {
        var result = observed
        // Prefer the registry's live CGDisplayBounds for PiPanel-owned virtual displays. Besides
        // filling an NSScreen omission, this also replaces an AppKit frame that has not caught up
        // with a recent global display reflow yet.
        for (displayID, frame) in registeredVirtual
        where displayID != excludedDisplayID && frame.width > 0 && frame.height > 0 {
            result[displayID] = frame
        }
        result.removeValue(forKey: excludedDisplayID)
        return result
    }

    private static func otherActiveDisplays(excluding excludedDisplayID: CGDirectDisplayID) -> [(id: CGDirectDisplayID, origin: CGPoint, frame: CGRect)] {
        let observed = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, CGRect)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            // NSScreen is used only to discover the reliable set of physical display IDs.
            // Its global frame uses AppKit coordinates and cannot be converted with a single
            // `primaryHeight - maxY` formula when the user's main screen is above/below another
            // screen. CGDisplayBounds is already in the exact Quartz topology space consumed by
            // CGConfigureDisplayOrigin and preserves which display is truly at (0, 0).
            let quartzFrame = CGDisplayBounds(id)
            guard quartzFrame.width > 0, quartzFrame.height > 0 else { return nil }
            return (id, quartzFrame)
        })
        let frames = mergedActiveDisplayFrames(
            observed: observed,
            registeredVirtual: activeVirtualDisplays.currentFrames(),
            excluding: excludedDisplayID
        )
        return frames.map { (id: $0.key, origin: $0.value.origin, frame: $0.value) }
    }

    /// Live-resizes an already-created — possibly already SCStream-capturing — virtual display, by
    /// re-applying a new single-mode CGVirtualDisplaySettings against the same CGVirtualDisplay
    /// instance. Confirmed working in Spikes/VirtualDisplayResizeSpike, including against a display
    /// an SCStream is actively capturing: the compositor genuinely grows to the new size (a running
    /// stream immediately starts delivering full frames at the new dimensions, containing real
    /// desktop content across the whole new area, once its SCStreamConfiguration.width/height is
    /// also updated to match — CaptureSession's own applyConfiguration already does that for other
    /// reasons on every resize tick). What doesn't happen is CGDisplayBounds updating to reflect
    /// it — see `bounds`'s doc comment for why this class stopped trusting that for its own size
    /// tracking, and why an earlier attempt at exactly this concluded (wrongly) that it "didn't
    /// reliably take effect": it was watching CGDisplayBounds, the one signal that never moves.
    ///
    /// Must run on the main thread, same as init — CGVirtualDisplay is an undocumented private API
    /// with no guarantee it's thread-safe, and init's own doc comment already documents an observed
    /// failure mode from calling it off-main.
    @discardableResult
    func resize(pixelWidth: Int, pixelHeight: Int) -> Bool {
        let mode = CGVirtualDisplayMode(
            width: pixelWidth,
            height: pixelHeight,
            refreshRate: currentRefreshRate
        )
        let settings = CGVirtualDisplaySettings()
        settings.modes = [mode]
        settings.hiDPI = Self.hiDPISetting
        guard virtualDisplay.apply(settings) else { return false }
        currentPixelSize = CGSize(width: pixelWidth, height: pixelHeight)
        return true
    }
}

/// Application-lifetime pool of private displays. Creating or destroying CGVirtualDisplay is the
/// operation that makes WindowServer rebuild the desktop and visibly flash; moving a window onto
/// an already-registered display does not. PiPanel therefore creates two displays once during
/// launch, leases one per CaptureSession, and returns it to the pool when that session closes. A
/// third display can be created on demand and retained; displays beyond that are reclaimed when
/// their sessions close.
enum VirtualDisplayPoolPolicy {
    static let initialWarmCapacity = 2
    static let retainedCapacity = 3

    static func shouldRetainReleasedDisplay(reusable: Bool, currentPoolCount: Int) -> Bool {
        reusable && currentPoolCount <= retainedCapacity
    }
}

@MainActor
final class VirtualDisplayPool {
    struct Lease {
        let host: VirtualDisplayHost
        /// True only for a mode resize performed while leasing. The usual pre-warmed path is false
        /// and can skip all sibling topology repair work during CaptureSession.start().
        let mutatedTopology: Bool
    }

    static let shared = VirtualDisplayPool()
    static let warmCapacity = VirtualDisplayPoolPolicy.retainedCapacity

    private struct Slot {
        let host: VirtualDisplayHost
        var isLeased: Bool
    }

    private var slots: [Slot] = []
    private var isWarming = false
    private var warmupWaiters: [CheckedContinuation<Void, Never>] = []
    private var availableResizeTask: Task<Void, Never>?

    var totalCount: Int { slots.count }
    var availableCount: Int { slots.filter { !$0.isLeased }.count }

    /// Called once from AppDelegate. It owns the topology lock across the complete batch so a user
    /// triggering PiP immediately after launch simply waits for the stable pool instead of racing
    /// a half-created display arrangement.
    func warmUp(capacity: Int = VirtualDisplayPoolPolicy.initialWarmCapacity, longEdge: CGFloat) async {
        let target = min(max(capacity, 1), Self.warmCapacity)
        if slots.count >= target { return }
        if isWarming {
            await withCheckedContinuation { continuation in
                warmupWaiters.append(continuation)
            }
            return
        }
        isWarming = true
        let pixelSize = VirtualDisplayHost.pixelSize(forLongEdge: longEdge)

        await VirtualDisplayCoordinator.shared.lock()
        var attempts = 0
        while slots.count < target, attempts < target * 2 {
            attempts += 1
            let ordinal = slots.count + 1
            guard let host = VirtualDisplayHost(
                pixelWidth: pixelSize.width,
                pixelHeight: pixelSize.height,
                name: "PiPanel Virtual Display \(ordinal)"
            ) else {
                debugTrace("vdisplay pool: failed to create warm display ordinal=\(ordinal)")
                break
            }

            slots.append(Slot(host: host, isLeased: false))
            guard await prepareNewHost(host) else {
                slots.removeAll { $0.host === host }
                debugTrace("vdisplay pool: warm display failed to register ordinal=\(ordinal)")
                continue
            }
            debugTrace("vdisplay pool: warmed displayID=\(host.displayID) count=\(slots.count)")
        }
        await VirtualDisplayCoordinator.shared.unlock()
        isWarming = false
        let waiters = warmupWaiters
        warmupWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        debugTrace("vdisplay pool: warm-up complete total=\(totalCount) available=\(availableCount)")
    }

    /// Must be called while CaptureSession owns VirtualDisplayCoordinator's lock. Resizing here is
    /// only a fallback for a resolution preference changed before idle slots were updated.
    func lease(pixelWidth: Int, pixelHeight: Int) -> Lease? {
        guard let index = slots.firstIndex(where: { !$0.isLeased }) else { return nil }
        let host = slots[index].host
        let requestedSize = CGSize(width: pixelWidth, height: pixelHeight)
        var mutatedTopology = false
        if host.currentPixelSize != requestedSize {
            guard host.resize(pixelWidth: pixelWidth, pixelHeight: pixelHeight) else { return nil }
            mutatedTopology = true
        }
        slots[index].isLeased = true
        debugTrace("vdisplay pool: leased displayID=\(host.displayID) available=\(availableCount)")
        return Lease(host: host, mutatedTopology: mutatedTopology)
    }

    /// Registers an overflow host created by CaptureSession while it already owns the topology
    /// lock. It remains usable while leased, but release trims the pool back to warmCapacity.
    func adoptLeased(_ host: VirtualDisplayHost) {
        guard !slots.contains(where: { $0.host === host }) else { return }
        slots.append(Slot(host: host, isLeased: true))
        debugTrace("vdisplay pool: adopted overflow displayID=\(host.displayID) total=\(totalCount)")
    }

    /// Returns true when the slot was removed and its host should be destroyed by the caller while
    /// it still owns VirtualDisplayCoordinator's topology lock. Besides contaminated displays,
    /// every capacity above three is reclaimed as its PiP closes, shrinking 5→4→3 naturally.
    @discardableResult
    func release(_ host: VirtualDisplayHost, reusable: Bool) -> Bool {
        guard let index = slots.firstIndex(where: { $0.host === host }) else { return true }
        if VirtualDisplayPoolPolicy.shouldRetainReleasedDisplay(
            reusable: reusable,
            currentPoolCount: slots.count
        ) {
            slots[index].isLeased = false
            debugTrace("vdisplay pool: returned displayID=\(host.displayID) available=\(availableCount)")
            return false
        } else {
            slots.remove(at: index)
            let reason = reusable ? "overflow" : "contaminated"
            debugTrace("vdisplay pool: reclaimed \(reason) displayID=\(host.displayID) total=\(totalCount)")
            return true
        }
    }

    /// Debounces the settings slider before touching idle displays. Without this, every slider
    /// tick would re-apply a mode to multiple hosts and recreate the exact flashing this pool is
    /// meant to eliminate. Active slots retain CaptureSession's own depth-1 coalescing path.
    func scheduleAvailableDisplayResize(longEdge: CGFloat) {
        availableResizeTask?.cancel()
        availableResizeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await self?.resizeAvailableDisplays(longEdge: longEdge)
        }
    }

    /// Keeps idle slots aligned with the setting so the next lease remains topology-free. Active
    /// slots are resized by their own CaptureSession and are deliberately skipped here.
    private func resizeAvailableDisplays(longEdge: CGFloat) async {
        let pixelSize = VirtualDisplayHost.pixelSize(forLongEdge: longEdge)
        await VirtualDisplayCoordinator.shared.lock()
        for slot in slots where !slot.isLeased {
            guard slot.host.currentPixelSize != CGSize(width: pixelSize.width, height: pixelSize.height) else {
                continue
            }
            _ = slot.host.resize(pixelWidth: pixelSize.width, pixelHeight: pixelSize.height)
        }
        await VirtualDisplayCoordinator.shared.unlock()
    }

    private func prepareNewHost(_ host: VirtualDisplayHost) async -> Bool {
        for attempt in 0..<20 {
            if host.isGeometryRegistered {
                host.positionOutsideExistingDisplays()
                return await waitForStableBounds(of: host)
            }
            if attempt < 19 {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        return false
    }

    private func waitForStableBounds(of host: VirtualDisplayHost) async -> Bool {
        var previous = host.bounds
        var stableSamples = 0
        for _ in 0..<15 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let current = host.bounds
            let unchanged = abs(previous.minX - current.minX) < 1
                && abs(previous.minY - current.minY) < 1
                && abs(previous.width - current.width) < 1
                && abs(previous.height - current.height) < 1
            if host.isGeometryRegistered, unchanged {
                stableSamples += 1
                if stableSamples >= 2 { return true }
            } else {
                stableSamples = 0
            }
            previous = current
        }
        return host.isGeometryRegistered
    }
}
