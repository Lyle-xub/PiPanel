import ApplicationServices
import AppKit

/// Finds the AXUIElement for a given captured window.
///
/// There is no public API mapping a CGWindowID/SCWindow directly to its AXUIElement, so this
/// matches by asking the owning app's AXUIElement for its kAXWindowsAttribute list and picking
/// the entry whose title and on-screen frame line up with what ScreenCaptureKit reported.
enum AXWindowLocator {
    static func locate(_ windowInfo: WindowInfo) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(windowInfo.ownerPID)
        var windowsValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)
        guard result == .success, let windows = windowsValue as? [AXUIElement] else { return nil }

        var bestMatch: (element: AXUIElement, score: CGFloat)?
        for window in windows {
            guard let frame = frame(of: window) else { continue }
            let distance = abs(frame.origin.x - windowInfo.frame.origin.x)
                + abs(frame.origin.y - windowInfo.frame.origin.y)
                + abs(frame.width - windowInfo.frame.width)
                + abs(frame.height - windowInfo.frame.height)
            if bestMatch == nil || distance < bestMatch!.score {
                bestMatch = (window, distance)
            }
        }
        // Loose tolerance: window server (top-left origin) vs AX (top-left origin too, but
        // rounding/animation can introduce a few points of drift) — 40pt covers that comfortably
        // while still rejecting a clearly-wrong window.
        if let bestMatch, bestMatch.score < 40 {
            return bestMatch.element
        }
        // Fall back to title match if frame drifted more than tolerance (e.g. window mid-animation).
        return windows.first { titleMatches($0, windowInfo.title) }
    }

    static func frame(of window: AXUIElement) -> CGRect? {
        guard let origin = point(window, kAXPositionAttribute),
              let size = size(window, kAXSizeAttribute) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    static func setFrame(_ frame: CGRect, on window: AXUIElement) {
        var origin = frame.origin
        if let positionValue = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        }
        var size = frame.size
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
    }

    private static func titleMatches(_ window: AXUIElement, _ title: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success,
              let axTitle = value as? String else { return false }
        return axTitle == title
    }

    private static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        var point = CGPoint.zero
        guard AXValueGetType(value as! AXValue) == .cgPoint else { return nil }
        AXValueGetValue(value as! AXValue, .cgPoint, &point)
        return point
    }

    private static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        var size = CGSize.zero
        guard AXValueGetType(value as! AXValue) == .cgSize else { return nil }
        AXValueGetValue(value as! AXValue, .cgSize, &size)
        return size
    }
}
