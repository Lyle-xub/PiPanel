import CoreGraphics

/// Maps a click inside the PiP panel's video view to the corresponding point on the real
/// source window, so it can be replayed there via CGEvent.
///
/// Two coordinate spaces are in play:
///  - AppKit view space: origin bottom-left, y grows up (NSView is not flipped here).
///  - Quartz/CG global space: origin top-left, y grows down — what CGEvent and window frames
///    (AXWindowLocator.frame, CaptureSession's window tracking) use.
/// The video image itself renders "right side up" in the (non-flipped) view, i.e. the top of
/// the captured window appears at the high-Y end of the view — so mapping to the image's
/// top-down fraction requires flipping Y once, then everything downstream stays in Quartz space.
enum CoordinateTranslator {
    /// Converts a Quartz/AX global frame (top-left origin, Y grows downward) into AppKit's global
    /// screen space (bottom-left origin, Y grows upward). The primary/menu-bar display is the
    /// shared pivot for the whole multi-display desktop, including displays arranged above or
    /// below it.
    static func appKitFrame(fromQuartzFrame frame: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: frame.minX,
            y: primaryScreenHeight - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    static func quartzPoint(fromAppKitPoint point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    /// - Parameters:
    ///   - localPoint: click location in the video view's own bounds (AppKit space).
    ///   - viewBounds: the video view's bounds.
    ///   - nativeSize: the displayed sample's aspect-ratio size. It may be briefly stale while a
    ///     new ScreenCaptureKit crop is taking effect, so global distances come from
    ///     windowGlobalFrame rather than trusting this value.
    ///   - windowGlobalFrame: the source window's current on-screen frame (Quartz space, e.g.
    ///     from AXWindowLocator.frame — top-left origin), on whichever display it currently sits.
    /// - Returns: nil if the point falls in the video's letterbox bars (outside the actual
    ///   image content) rather than on the window itself.
    static func globalPoint(
        forLocalPoint localPoint: CGPoint,
        viewBounds: CGRect,
        nativeSize _: CGSize,
        displayedVideoRect: CGRect,
        windowGlobalFrame: CGRect
    ) -> CGPoint? {
        guard displayedVideoRect.width > 0, displayedVideoRect.height > 0 else { return nil }
        guard displayedVideoRect.contains(localPoint) else { return nil }

        let fracX = (localPoint.x - displayedVideoRect.minX) / displayedVideoRect.width
        let fracYFromBottom = (localPoint.y - displayedVideoRect.minY) / displayedVideoRect.height
        let fracYFromTop = 1 - fracYFromBottom

        let windowLocalX = fracX * windowGlobalFrame.width
        let windowLocalY = fracYFromTop * windowGlobalFrame.height

        return CGPoint(
            x: windowGlobalFrame.origin.x + windowLocalX,
            y: windowGlobalFrame.origin.y + windowLocalY
        )
    }
}
