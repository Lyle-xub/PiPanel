import ApplicationServices
import AppKit

/// Finds the AXUIElement for a given captured window.
///
/// There is no public API mapping a CGWindowID/SCWindow directly to its AXUIElement, so this
/// matches by asking the owning app's AXUIElement for its kAXWindowsAttribute list and picking
/// the entry whose title and on-screen frame line up with what ScreenCaptureKit reported.
enum AXWindowLocator {
    static func locate(_ windowInfo: WindowInfo) -> AXUIElement? {
        locate(
            ownerPID: windowInfo.ownerPID,
            approximateFrame: windowInfo.frame,
            title: windowInfo.title
        )
    }

    /// Locates an arbitrary application's window without requiring an SCWindow. The virtual-
    /// display intrusion guard gets its cheap first-pass snapshots from CGWindowList, then uses
    /// this overload only for the rare window that actually appears inside a managed display.
    static func locate(ownerPID: pid_t, approximateFrame: CGRect, title: String?) -> AXUIElement? {
        let windows = windows(ownerPID: ownerPID)
        guard !windows.isEmpty else { return nil }

        var bestMatch: (element: AXUIElement, score: CGFloat)?
        for window in windows {
            guard let frame = frame(of: window) else { continue }
            let distance = abs(frame.origin.x - approximateFrame.origin.x)
                + abs(frame.origin.y - approximateFrame.origin.y)
                + abs(frame.width - approximateFrame.width)
                + abs(frame.height - approximateFrame.height)
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
        guard let title, !title.isEmpty else { return nil }
        return windows.first { titleMatches($0, title) }
    }

    /// Returns fresh AX window elements for an application. Native fullscreen transitions may
    /// replace the element returned before the transition with a companion element, so callers
    /// restoring a window must not rely exclusively on a cached AXUIElement.
    static func windows(ownerPID: pid_t) -> [AXUIElement] {
        let appElement = AXUIElementCreateApplication(ownerPID)
        var windowsValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &windowsValue
        )
        guard result == .success else { return [] }
        return windowsValue as? [AXUIElement] ?? []
    }

    /// Reads the WindowServer's current frame for the original CGWindowID. This remains the
    /// authoritative identity when a fullscreen transition leaves the cached AX element stale.
    static func currentFrame(ofWindowID windowID: CGWindowID) -> CGRect? {
        guard let rawList = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow, .excludeDesktopElements],
            windowID
        ) as? [[String: Any]],
        let entry = rawList.first,
        let bounds = entry[kCGWindowBounds as String] as? [String: Any],
        let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
        frame.width > 0, frame.height > 0 else {
            return nil
        }
        return frame
    }

    static func frame(of window: AXUIElement) -> CGRect? {
        guard let origin = point(window, kAXPositionAttribute),
              let size = size(window, kAXSizeAttribute) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    static func title(of window: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    /// "AXFullScreen" isn't among ApplicationServices' published kAX*Attribute constants, but it's
    /// the conventional (if undocumented) boolean attribute apps that support native macOS
    /// fullscreen expose — used here by PiPSessionManager.pipAllEligibleWindows to skip windows
    /// already fullscreen (PiP-ing a fullscreen window's own Space doesn't make sense the way it
    /// does for a normal windowed one). An app that doesn't support fullscreen at all, or doesn't
    /// expose this attribute, reads as false here — treated as "not fullscreen" (eligible), which
    /// is the correct default for a window there's simply no fullscreen state to check.
    static func fullScreenState(of window: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &value) == .success else {
            return nil
        }
        return value as? Bool
    }

    static func isFullScreen(_ window: AXUIElement) -> Bool {
        fullScreenState(of: window) ?? false
    }

    /// Requests native macOS fullscreen on/off for an arbitrary application's window. PiPanel
    /// writes `false` when a source enters a fullscreen Space while parked on a hidden display,
    /// because AX frame writes are ineffective until that Space transition has ended.
    @discardableResult
    static func setFullScreen(_ fullScreen: Bool, on window: AXUIElement) -> AXError {
        let value = NSNumber(value: fullScreen)
        return AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, value)
    }

    /// kAXMinimizedAttribute, unlike AXFullScreen above, *is* a standard published attribute — used
    /// alongside isFullScreen by PiPSessionManager.pipAllEligibleWindows to skip minimized windows
    /// too. WindowEnumerator's own candidate list can still include a minimized window (it
    /// deliberately passes onScreenWindowsOnly: false so windows on other/full-screen Spaces are
    /// included, and a minimized window is "off-screen" for the same reason a Space-switched one
    /// is) — PiP-ing a window the user just explicitly tucked away into the Dock would immediately
    /// un-tuck it back onto a virtual display, working against what minimizing it was for.
    static func isMinimized(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success else {
            return false
        }
        return (value as? Bool) ?? false
    }

    static func setFrame(_ frame: CGRect, on window: AXUIElement) {
        var origin = frame.origin
        if let positionValue = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        }
        setSize(frame.size, on: window)
    }

    /// Size-only counterpart to setFrame — for a pure resize (top-left anchor unchanged, e.g.
    /// CaptureSession's PiP-panel resize), skips the redundant position write. Beyond saving one
    /// IPC round trip per call, that extra write was found to matter: sending a "moved" and a
    /// "resized" request together, repeatedly, gave some apps' AX handling more to arbitrate on
    /// each call, making them less likely to actually land the size change before the next
    /// request arrived — see CaptureSession.commitSourceWindowSize's doc for the full story.
    ///
    /// Returns the raw AXError instead of discarding it (every other call site in this file
    /// silently drops it) — CaptureSession logs this, since a resize that's silently rejected
    /// outright (.actionUnsupported, the attribute not being settable at all, etc.) looks
    /// identical from the outside to one that's just slow to apply, and those need different
    /// fixes.
    @discardableResult
    static func setSize(_ size: CGSize, on window: AXUIElement) -> AXError {
        var size = size
        guard let sizeValue = AXValueCreate(.cgSize, &size) else { return .failure }
        return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
    }

    /// Whether the window's AX layer will even accept a size write at all — checked once so a
    /// silently-doomed resize (some apps expose kAXSizeAttribute as read-only) can be told apart
    /// from one that's merely slow.
    static func isSizeSettable(on window: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        let result = AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &settable)
        return result == .success && settable.boolValue
    }

    private static func titleMatches(_ window: AXUIElement, _ title: String) -> Bool {
        self.title(of: window) == title
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
