import AppKit
import ApplicationServices

/// Detects "shake a window into PiP" gestures system-wide: grabbing a window anywhere and shaking
/// it back and forth converts that window into a PiP session — an alternative to the menu-bar
/// picker for a window you're already looking at, without having to break flow to open the menu.
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
        guard AXIsProcessTrusted() else { return }

        let quartzPoint = Self.quartzPoint(from: event.locationInWindow)
        let systemWide = AXUIElementCreateSystemWide()
        var elementRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(quartzPoint.x), Float(quartzPoint.y), &elementRef) == .success,
              let element = elementRef else {
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
            return
        }

        var pid: pid_t = 0
        guard AXUIElementGetPid(axWindow, &pid) == .success, pid != ProcessInfo.processInfo.processIdentifier else { return }

        tracking = Tracking(axWindow: axWindow, pid: pid, samples: [(quartzPoint, event.timestamp)])
        PiPanelLogger.interaction.debug("Fling: tracking started for pid \(pid)")
    }

    private func handleMouseDragged(_ event: NSEvent) {
        guard tracking != nil else { return }
        let point = Self.quartzPoint(from: event.locationInWindow)
        tracking?.samples.append((point, event.timestamp))
        if let newest = tracking?.samples.last?.time {
            tracking?.samples.removeAll { newest - $0.time > Self.velocitySampleWindow }
        }
    }

    private func handleMouseUp(_ event: NSEvent) {
        defer { tracking = nil }
        guard let tracking, let oldest = tracking.samples.first else { return }

        let point = Self.quartzPoint(from: event.locationInWindow)
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
        guard speed >= Self.flingVelocityThreshold, reversals >= Self.minReversals else { return }

        let axWindow = tracking.axWindow
        let pid = tracking.pid
        Task { [weak self] in
            await self?.attemptStartSession(axWindow: axWindow, pid: pid)
        }
    }

    /// There's no public API mapping an AXUIElement to a CGWindowID (the same gap
    /// AXWindowLocator works around in the other direction), so the flung window is matched back
    /// to a WindowInfo by owning pid + current frame proximity.
    private func attemptStartSession(axWindow: AXUIElement, pid: pid_t) async {
        guard let quartzFrame = AXWindowLocator.frame(of: axWindow) else { return }
        guard let candidates = try? await WindowEnumerator.listPiPCandidateWindows() else {
            PiPanelLogger.interaction.debug("Fling: WindowEnumerator lookup failed (screen recording permission?)")
            return
        }
        let match = candidates
            .filter { $0.ownerPID == pid }
            .min { Self.distance($0.frame, quartzFrame) < Self.distance($1.frame, quartzFrame) }
        guard let windowInfo = match, Self.distance(windowInfo.frame, quartzFrame) < 60 else {
            PiPanelLogger.interaction.debug("Fling: no WindowInfo matched pid \(pid) within tolerance")
            return
        }

        PiPanelLogger.interaction.debug("Fling: starting PiP session for \(windowInfo.title)")
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

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.origin.x - b.origin.x) + abs(a.origin.y - b.origin.y) + abs(a.width - b.width) + abs(a.height - b.height)
    }

    /// AXUIElementCopyElementAtPosition and window frames (AXWindowLocator, WindowInfo.frame) all
    /// use top-left-origin Quartz space; NSEvent.locationInWindow (screen coords, for a global-
    /// monitor event with no real window)/NSScreen.frame use bottom-left-origin AppKit space.
    /// The conversion pivots on the primary screen's height — the screen at index 0 of
    /// NSScreen.screens is documented to be the one containing the menu bar, whose AppKit frame
    /// origin is .zero and which sits at Quartz global (0,0) at its top-left.
    private static func quartzPoint(from appKitPoint: NSPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: appKitPoint.x, y: primaryHeight - appKitPoint.y)
    }

    private static func role(of element: AXUIElement) -> String? {
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success else { return nil }
        return role as? String
    }

    private static func enclosingWindow(of element: AXUIElement, maxDepth: Int = 8) -> AXUIElement? {
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
}
