import AppKit
import ApplicationServices

/// Detects "fling a window into PiP" gestures system-wide: dragging a window by its title bar and
/// releasing with enough velocity converts that window into a PiP session — an alternative to
/// the menu-bar picker for a window you're already looking at, without having to break flow to
/// open the menu. There's no modifier-key gate — grabbing the title bar and throwing it is the
/// whole gesture — so the release-velocity threshold is the only thing separating a deliberate
/// fling from someone just quickly repositioning a window.
///
/// Global NSEvent monitors for mouse events don't themselves require Input Monitoring/
/// Accessibility permission, but resolving *which* window is under the cursor and its live frame
/// goes through the same Accessibility APIs AXWindowLocator already depends on — so this quietly
/// no-ops until that permission is granted, same as every other AX-dependent path in the app.
/// Every rejection point below logs why, via AnyPiPLogger.interaction — this gesture has no other
/// feedback (unlike a click, there's no failed-click affordance), so when it doesn't fire, the log
/// is the only way to tell whether the title-bar hit test, the velocity threshold, or the
/// WindowInfo match is what rejected it.
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

    /// Below this, the release reads as an ordinary reposition, not a deliberate throw. Tuned low
    /// enough that a normal brisk flick reliably crosses it — false positives from someone just
    /// quickly repositioning a window are judged the lesser problem versus the gesture not firing
    /// at all, since the title-bar-hit requirement already rules out the much more common case of
    /// fast mouse movement over a window's content.
    private static let flingVelocityThreshold: CGFloat = 1400 // points/second
    /// Only the trailing window of samples feeds the release-velocity estimate, so a fast flick
    /// at the tail of an otherwise slow drag still reads as a fling.
    private static let velocitySampleWindow: TimeInterval = 0.12
    /// A mouseDown within this many points of a window's top edge counts as grabbing its title
    /// bar — approximates "title bar" geometrically rather than walking AX roles per app, since
    /// hit-testing a title bar's AX element isn't consistent across every app. Generous enough to
    /// cover unified-toolbar-style title bars, which run taller than the classic ~22pt bar.
    private static let titleBarHitHeight: CGFloat = 44

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
        AnyPiPLogger.interaction.debug("WindowFlingDetector started")
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
        // If the hit element itself is the window (not some content view inside it), that's
        // already a strong signal the click landed on chrome rather than content — accept it
        // regardless of the geometric title-bar-height check below, which exists for the more
        // common case where the hit resolves to some title-bar subelement instead.
        let hitElementIsWindow = Self.role(of: element) == kAXWindowRole
        guard let axWindow = Self.enclosingWindow(of: element) else {
            AnyPiPLogger.interaction.debug("Fling: mouseDown hit element has no enclosing AXWindow")
            return
        }

        var pid: pid_t = 0
        guard AXUIElementGetPid(axWindow, &pid) == .success, pid != ProcessInfo.processInfo.processIdentifier else { return }
        guard let frame = AXWindowLocator.frame(of: axWindow) else {
            AnyPiPLogger.interaction.debug("Fling: could not read frame of hit window")
            return
        }
        guard hitElementIsWindow || quartzPoint.y - frame.origin.y <= Self.titleBarHitHeight else {
            return // a plain click/drag inside the window's content — not a title-bar grab
        }

        tracking = Tracking(axWindow: axWindow, pid: pid, samples: [(quartzPoint, event.timestamp)])
        AnyPiPLogger.interaction.debug("Fling: tracking started for pid \(pid)")
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
        let dx = point.x - oldest.point.x
        let dy = point.y - oldest.point.y
        let speed = sqrt(dx * dx + dy * dy) / dt
        AnyPiPLogger.interaction.debug("Fling: release speed \(speed, format: .fixed(precision: 0)) pt/s (threshold \(Self.flingVelocityThreshold, format: .fixed(precision: 0)))")
        guard speed >= Self.flingVelocityThreshold else { return }

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
            AnyPiPLogger.interaction.debug("Fling: WindowEnumerator lookup failed (screen recording permission?)")
            return
        }
        let match = candidates
            .filter { $0.ownerPID == pid }
            .min { Self.distance($0.frame, quartzFrame) < Self.distance($1.frame, quartzFrame) }
        guard let windowInfo = match, Self.distance(windowInfo.frame, quartzFrame) < 60 else {
            AnyPiPLogger.interaction.debug("Fling: no WindowInfo matched pid \(pid) within tolerance")
            return
        }

        AnyPiPLogger.interaction.debug("Fling: starting PiP session for \(windowInfo.title)")
        onFling?(windowInfo)
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
