import CoreGraphics
import AppKit

/// Posts synthetic mouse events at an absolute screen point via CGEvent, delivered globally
/// through .cghidEventTap — this is what actually gets full click/hit-test semantics honored by
/// the target app (CGEventPostToPid, which delivers directly into one process's queue without
/// touching the global cursor, was tried and found unreliable: target apps did not register the
/// clicks at all, likely because it bypasses the normal WindowServer hit-test/dispatch path that
/// AppKit's view responder chain expects).
///
/// Since the target point can be on the invisible virtual display (Capture/VirtualDisplayHost),
/// posting there necessarily relocates the real, visible system cursor there too as a side
/// effect, so it's warped back immediately after. CGWarpMouseCursorPosition alone desyncs the
/// displayed cursor from the physical mouse's HID deltas, so CGAssociateMouseAndMouseCursorPosition
/// is used to resync them afterward.
///
/// Deliberately NOT using CGDisplayHideCursor/CGDisplayShowCursor to mask the brief jump (tried
/// and reverted): that API is a system-wide, cross-process hide counter, not scoped to this app.
/// Activating the source app to deliver a click can itself cause the source app to independently
/// call the same API — e.g. browsers commonly auto-hide the cursor while hovering interactive
/// video content (a Bilibili thumbnail among them) using this exact system call, not just CSS.
/// Two independent callers incrementing/decrementing the same shared counter can leave it
/// permanently non-zero, hiding the cursor for good — which is worse than the brief visual jump
/// this was meant to hide.
///
/// A second, related issue: landing the warped cursor on hover-sensitive content (a link, a text
/// field) makes the source app call NSCursor.set() to switch to a hand/I-beam image, exactly like
/// it would for a real hover. Normally that gets popped again once the mouse continuously moves
/// out of the region (a mouseExited/cursorUpdate event) — but a warp is a teleport, not continuous
/// motion, so the source app never sees that exit and never resets its cursor. Since NSCursor's
/// "current" image is a single shared system resource (not scoped per app/window), that
/// orphaned custom cursor is what's left showing — which can render as broken/invisible — even
/// after the position warps back to the user's real mouse location. NSCursor.arrow.set() forces
/// it back to a known-good image after every forwarded interaction.
enum MouseEventForwarder {
    static func click(at globalPoint: CGPoint, button: CGMouseButton = .left) {
        let originalLocation = CGEvent(source: nil)?.location
        CGAssociateMouseAndMouseCursorPosition(0)

        post(type: .mouseMoved, at: globalPoint, button: button)
        post(type: button == .left ? .leftMouseDown : .rightMouseDown, at: globalPoint, button: button)
        Thread.sleep(forTimeInterval: 0.03)
        post(type: button == .left ? .leftMouseUp : .rightMouseUp, at: globalPoint, button: button)

        if let originalLocation {
            CGWarpMouseCursorPosition(originalLocation)
        }
        CGAssociateMouseAndMouseCursorPosition(1)
        resetCursorToArrow()
    }

    static func scroll(at globalPoint: CGPoint, deltaY: Int32, deltaX: Int32 = 0) {
        let originalLocation = CGEvent(source: nil)?.location
        CGAssociateMouseAndMouseCursorPosition(0)

        // Move (no click) so the scroll lands on the right view under the cursor, matching how
        // real trackpad/mouse scroll events are hit-tested by the target app.
        post(type: .mouseMoved, at: globalPoint, button: .left)
        if let scrollEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        ) {
            scrollEvent.location = globalPoint
            scrollEvent.post(tap: .cghidEventTap)
        }

        if let originalLocation {
            CGWarpMouseCursorPosition(originalLocation)
        }
        CGAssociateMouseAndMouseCursorPosition(1)
        resetCursorToArrow()
    }

    /// The source app's hover-triggered NSCursor.set() call is delivered asynchronously in a
    /// separate process, so it can land after our own reset — a delayed follow-up reset catches
    /// that race without blocking the caller on a longer synchronous wait.
    private static func resetCursorToArrow() {
        NSCursor.arrow.set()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSCursor.arrow.set()
        }
    }

    private static func post(type: CGEventType, at point: CGPoint, button: CGMouseButton) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
        // Without an explicit click count, AppKit's NSEvent(cgEvent:) can report clickCount 0,
        // which several views' mouseDown hit-testing (text caret placement among them) treat as
        // "not a real click" and no-op on — even though the event still activates the window.
        if type == .leftMouseDown || type == .leftMouseUp || type == .rightMouseDown || type == .rightMouseUp {
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        }
        event.post(tap: .cghidEventTap)
    }
}
