import AppKit
import ApplicationServices

struct FlingCandidateSnapshot {
    let title: String
    let frame: CGRect
}

enum FlingCandidateMatcher {
    /// ScreenCaptureKit can trail the live AX position by several hundred points immediately after
    /// a fast drag. Prefer the stable app/window identity (PID is filtered by the caller, then
    /// title here), using geometry only when the title is unavailable or ambiguous.
    static func matchingIndex(
        candidates: [FlingCandidateSnapshot],
        axTitle: String?,
        liveFrame: CGRect
    ) -> Int? {
        guard !candidates.isEmpty else { return nil }

        if let axTitle, !axTitle.isEmpty {
            let titleMatches = candidates.indices.filter {
                titlesLikelyMatch(candidates[$0].title, axTitle)
            }
            if titleMatches.count == 1 {
                return titleMatches[0]
            }
            if let closestTitleMatch = titleMatches.min(by: {
                distance(candidates[$0].frame, liveFrame) < distance(candidates[$1].frame, liveFrame)
            }), distance(candidates[closestTitleMatch].frame, liveFrame) < 240 {
                return closestTitleMatch
            }
        }

        if let closest = candidates.indices.min(by: {
            distance(candidates[$0].frame, liveFrame) < distance(candidates[$1].frame, liveFrame)
        }), distance(candidates[closest].frame, liveFrame) < 240 {
            return closest
        }

        // A single eligible layer-zero window for this PID is unambiguous even if SC has not yet
        // published its post-shake position. This is the common Bilibili/Electron case.
        return candidates.count == 1 ? 0 : nil
    }

    static func titlesLikelyMatch(_ lhs: String, _ rhs: String) -> Bool {
        let lhs = lhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rhs = rhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        if lhs == rhs { return true }
        let shorter = lhs.count <= rhs.count ? lhs : rhs
        let longer = lhs.count <= rhs.count ? rhs : lhs
        return shorter.count >= 3 && longer.contains(shorter)
    }

    static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.origin.x - b.origin.x)
            + abs(a.origin.y - b.origin.y)
            + abs(a.width - b.width)
            + abs(a.height - b.height)
    }
}

/// Detects "shake a window into PiP" gestures system-wide: grabbing a window anywhere and shaking
/// it back and forth converts that window into a PiP session — the permanently-licensed
/// alternative to WindowCornerPiPController's free/default top-left hover switch.
/// There's no modifier-key gate and no requirement to grab a specific part of the window — any
/// drag that reverses direction with enough accumulated motion is the whole gesture. A plain
/// single-direction pan (drag one way and let go, however fast) deliberately does NOT qualify —
/// requiring an actual reversal is what separates a deliberate shake from someone just quickly
/// repositioning or interacting with a window; the accumulated-speed threshold alone wasn't
/// enough; a brisk ordinary drag-release routinely crossed it too.
///
/// Global NSEvent monitors for mouse events don't themselves require Input Monitoring/
/// Accessibility permission, but resolving *which* window is under the cursor and its live frame
/// goes through the same Accessibility APIs AXWindowLocator already depends on — so this quietly
/// no-ops until that permission is granted, same as every other AX-dependent path in the app.
/// Every rejection point below logs why, via PiPanelLogger.interaction — this gesture has no other
/// feedback (unlike a click, there's no failed-click affordance), so when it doesn't fire, the log
/// is the only way to tell whether the speed threshold or the WindowInfo match is what rejected
/// it.
@MainActor
final class WindowFlingDetector {
    /// The window to convert to PiP.
    var onFling: ((_ windowInfo: WindowInfo) -> Void)?

    private var mouseDownMonitor: Any?
    private var mouseDraggedMonitor: Any?
    private var mouseUpMonitor: Any?

    private struct Tracking {
        let axWindow: AXUIElement
        let pid: pid_t
        var samples: [(point: CGPoint, time: TimeInterval)]
    }
    private var tracking: Tracking?

    /// Below this, the release reads as an ordinary drag, not a deliberate shake/throw. Tuned low
    /// enough that a normal brisk flick or a couple of quick shakes reliably crosses it — false
    /// positives from someone just dragging a window around are judged the lesser problem versus
    /// the gesture not firing at all. Lowered again from 1400 at the user's request to make the
    /// gesture easier to trigger.
    private static let flingVelocityThreshold: CGFloat = 300 // points/second, accumulated (see handleMouseUp)
    /// The trailing window of samples feeds the accumulated-speed estimate, so a fast shake at the
    /// tail of an otherwise slow drag still reads as a fling. Wide enough to span a couple of
    /// back-and-forth reversals of an actual shake, not just one straight-line segment.
    private static let velocitySampleWindow: TimeInterval = 0.25
    /// A segment shorter than this is treated as jitter, not a real direction — without this floor,
    /// sub-pixel noise during an otherwise perfectly straight drag could register a spurious
    /// "reversal" and let a plain pan slip through.
    private static let minSegmentLength: CGFloat = 3
    /// At least this many direction reversals (consecutive segments pointing more than 90° apart)
    /// must show up in the tracked samples — the actual signal that distinguishes a deliberate
    /// shake from a plain single-direction drag-and-release, however fast that release is.
    private static let minReversals = 1

    func start() {
        guard mouseDownMonitor == nil else { return }
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.handleMouseDown(event)
        }
        mouseDraggedMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            self?.handleMouseDragged(event)
        }
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            self?.handleMouseUp(event)
        }
        PiPanelLogger.interaction.debug("WindowFlingDetector started")
    }

    func stop() {
        for monitor in [mouseDownMonitor, mouseDraggedMonitor, mouseUpMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        mouseDownMonitor = nil
        mouseDraggedMonitor = nil
        mouseUpMonitor = nil
        tracking = nil
    }

    private func handleMouseDown(_ event: NSEvent) {
        tracking = nil
        guard AXIsProcessTrusted() else {
            debugTrace("fling: rejected mouseDown because Accessibility is not trusted")
            return
        }

        let quartzPoint = Self.quartzPoint(from: Self.appKitScreenPoint(from: event))
        let systemWide = AXUIElementCreateSystemWide()
        var elementRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(quartzPoint.x), Float(quartzPoint.y), &elementRef) == .success,
              let element = elementRef else {
            debugTrace("fling: AX hit-test failed point=\(quartzPoint)")
            return
        }
        // Any mouseDown that resolves to some app's window starts tracking, regardless of where
        // on it — the accumulated-speed threshold in handleMouseUp is what separates a deliberate
        // shake/fling from ordinary interaction, not where the grab landed. Not gating on
        // title-bar geometry also means a genuine shake started from a toolbar/content area
        // (which the OS won't actually move the window for) is still tracked; it just won't cross
        // the speed threshold unless the window is actually being thrown around.
        guard let axWindow = Self.enclosingWindow(of: element) else {
            PiPanelLogger.interaction.debug("Fling: mouseDown hit element has no enclosing AXWindow")
            debugTrace("fling: hit element has no enclosing AXWindow role=\(Self.role(of: element) ?? "nil") point=\(quartzPoint)")
            return
        }

        var pid: pid_t = 0
        guard AXUIElementGetPid(axWindow, &pid) == .success, pid != ProcessInfo.processInfo.processIdentifier else { return }

        tracking = Tracking(axWindow: axWindow, pid: pid, samples: [(quartzPoint, event.timestamp)])
        PiPanelLogger.interaction.debug("Fling: tracking started for pid \(pid)")
        debugTrace("fling: tracking started pid=\(pid) title=\(AXWindowLocator.title(of: axWindow) ?? "nil") frame=\(AXWindowLocator.frame(of: axWindow) ?? .zero)")
    }

    private func handleMouseDragged(_ event: NSEvent) {
        guard tracking != nil else { return }
        let point = Self.quartzPoint(from: Self.appKitScreenPoint(from: event))
        tracking?.samples.append((point, event.timestamp))
        if let newest = tracking?.samples.last?.time {
            tracking?.samples.removeAll { newest - $0.time > Self.velocitySampleWindow }
        }
    }

    private func handleMouseUp(_ event: NSEvent) {
        defer { tracking = nil }
        guard let tracking, let oldest = tracking.samples.first else { return }

        let point = Self.quartzPoint(from: Self.appKitScreenPoint(from: event))
        let dt = event.timestamp - oldest.time
        guard dt > 0.01 else { return } // avoid an inflated estimate from a near-zero time delta

        // Sum of consecutive-sample segment lengths, not straight-line displacement from oldest to
        // newest — a real shake reverses direction, so its net displacement can read as near zero
        // even while the cursor is covering plenty of ground. Accumulating path length instead
        // means a back-and-forth shake and a straight-line flick both register by how much motion
        // actually happened, rather than a shake needing to also end up somewhere far from where
        // it started.
        var path = tracking.samples
        path.append((point, event.timestamp))
        var totalDistance: CGFloat = 0
        for (previous, current) in zip(path, path.dropFirst()) {
            let dx = current.point.x - previous.point.x
            let dy = current.point.y - previous.point.y
            totalDistance += sqrt(dx * dx + dy * dy)
        }
        let speed = totalDistance / dt
        let reversals = Self.reversalCount(in: path)
        PiPanelLogger.interaction.debug("Fling: accumulated speed \(speed, format: .fixed(precision: 0)) pt/s (threshold \(Self.flingVelocityThreshold, format: .fixed(precision: 0))), \(reversals) reversal(s) (need \(Self.minReversals))")
        debugTrace("fling: gesture speed=\(speed) reversals=\(reversals) samples=\(path.count)")
        guard speed >= Self.flingVelocityThreshold, reversals >= Self.minReversals else { return }

        let axWindow = tracking.axWindow
        let pid = tracking.pid
        Task { [weak self] in
            await self?.attemptStartSession(axWindow: axWindow, pid: pid)
        }
    }

    /// There's no public API mapping an AXUIElement to a CGWindowID (the same gap
    /// AXWindowLocator works around in the other direction), so the flung window is matched back
    /// to a WindowInfo by owning PID, AX title, then live-frame proximity as a fallback.
    private func attemptStartSession(axWindow: AXUIElement, pid: pid_t) async {
        guard let quartzFrame = AXWindowLocator.frame(of: axWindow) else {
            debugTrace("fling: rejected pid=\(pid) because live AX frame is unavailable")
            return
        }
        guard let candidates = try? await WindowEnumerator.listPiPCandidateWindows() else {
            PiPanelLogger.interaction.debug("Fling: WindowEnumerator lookup failed (screen recording permission?)")
            debugTrace("fling: WindowEnumerator lookup failed pid=\(pid)")
            return
        }
        let pidCandidates = candidates.filter { $0.ownerPID == pid }
        let snapshots = pidCandidates.map { FlingCandidateSnapshot(title: $0.title, frame: $0.frame) }
        let axTitle = AXWindowLocator.title(of: axWindow)
        guard let matchIndex = FlingCandidateMatcher.matchingIndex(
            candidates: snapshots,
            axTitle: axTitle,
            liveFrame: quartzFrame
        ) else {
            PiPanelLogger.interaction.debug("Fling: no WindowInfo matched pid \(pid) within tolerance")
            debugTrace("fling: no candidate matched pid=\(pid) axTitle=\(axTitle ?? "nil") liveFrame=\(quartzFrame) candidates=\(snapshots.map { "\($0.title):\($0.frame)" })")
            return
        }

        var windowInfo = pidCandidates[matchIndex]
        let staleDistance = FlingCandidateMatcher.distance(windowInfo.frame, quartzFrame)
        // The AX frame is read after the drag ended and is therefore authoritative for both the
        // source move and the monitor on which the PiP should appear. Passing SC's possibly stale
        // pre-shake frame was also why a secondary-screen shake opened the panel on the main one.
        windowInfo.frame = quartzFrame

        PiPanelLogger.interaction.debug("Fling: starting PiP session for \(windowInfo.title)")
        debugTrace("fling: matched title=\(windowInfo.title) pid=\(pid) staleDistance=\(staleDistance) liveFrame=\(quartzFrame)")
        onFling?(windowInfo)
    }

    /// Counts direction reversals across consecutive segments of the tracked path — segments
    /// shorter than minSegmentLength are skipped (jitter, no reliable direction), and a reversal is
    /// a segment pointing more than 90° away from the last real direction (negative dot product of
    /// the two segment vectors), i.e. the cursor is now heading back the way it came rather than
    /// merely curving.
    private static func reversalCount(in path: [(point: CGPoint, time: TimeInterval)]) -> Int {
        var reversals = 0
        var previousDirection: CGVector?
        for (previous, current) in zip(path, path.dropFirst()) {
            let dx = current.point.x - previous.point.x
            let dy = current.point.y - previous.point.y
            guard dx * dx + dy * dy >= minSegmentLength * minSegmentLength else { continue }
            let direction = CGVector(dx: dx, dy: dy)
            if let previousDirection, previousDirection.dx * direction.dx + previousDirection.dy * direction.dy < 0 {
                reversals += 1
            }
            previousDirection = direction
        }
        return reversals
    }

    /// AXUIElementCopyElementAtPosition and window frames (AXWindowLocator, WindowInfo.frame) all
    /// use top-left-origin Quartz space; NSEvent.locationInWindow (screen coords, for a global-
    /// monitor event with no real window)/NSScreen.frame use bottom-left-origin AppKit space.
    /// The conversion pivots on the primary screen's height — the screen at index 0 of
    /// NSScreen.screens is documented to be the one containing the menu bar, whose AppKit frame
    /// origin is .zero and which sits at Quartz global (0,0) at its top-left.
    private static func quartzPoint(from appKitPoint: NSPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CoordinateTranslator.quartzPoint(
            fromAppKitPoint: appKitPoint,
            primaryScreenHeight: primaryHeight
        )
    }

    /// Preserve the position attached to each historical drag event rather than sampling the
    /// cursor's latest position repeatedly (queued events could otherwise collapse to one point).
    /// Global-monitor events normally have no NSWindow and already report screen coordinates; the
    /// conversion also handles the defensive case where AppKit supplies a window-relative event.
    private static func appKitScreenPoint(from event: NSEvent) -> CGPoint {
        guard let window = event.window else { return event.locationInWindow }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    private static func role(of element: AXUIElement) -> String? {
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success else { return nil }
        return role as? String
    }

    private static func enclosingWindow(of element: AXUIElement, maxDepth: Int = 32) -> AXUIElement? {
        // Electron apps such as Bilibili expose deeply nested custom title-bar/web-content
        // elements. AXWindow/AXTopLevelUIElement jump directly to the owning window when those
        // attributes are available, avoiding an arbitrary parent-depth dependency.
        for attribute in [kAXWindowAttribute, kAXTopLevelUIElementAttribute] {
            if let candidate = elementAttribute(element, attribute), role(of: candidate) == kAXWindowRole {
                return candidate
            }
        }

        var current = element
        for _ in 0..<maxDepth {
            if role(of: current) == kAXWindowRole {
                return current
            }
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parent = parentRef else { return nil }
            current = (parent as! AXUIElement)
        }
        return nil
    }

    private static func elementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
