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
    /// - Parameters:
    ///   - localPoint: click location in the video view's own bounds (AppKit space).
    ///   - viewBounds: the video view's bounds.
    ///   - nativeSize: the captured window's actual size (CaptureSession.framedRect.size).
    ///   - windowGlobalFrame: the source window's current on-screen frame (Quartz space, e.g.
    ///     from AXWindowLocator.frame — top-left origin), on whichever display it currently sits.
    /// - Returns: nil if the point falls in the video's letterbox bars (outside the actual
    ///   image content) rather than on the window itself.
    static func globalPoint(
        forLocalPoint localPoint: CGPoint,
        viewBounds: CGRect,
        nativeSize: CGSize,
        displayedVideoRect: CGRect,
        windowGlobalFrame: CGRect
    ) -> CGPoint? {
        guard displayedVideoRect.width > 0, displayedVideoRect.height > 0 else { return nil }
        guard displayedVideoRect.contains(localPoint) else { return nil }

        let fracX = (localPoint.x - displayedVideoRect.minX) / displayedVideoRect.width
        let fracYFromBottom = (localPoint.y - displayedVideoRect.minY) / displayedVideoRect.height
        let fracYFromTop = 1 - fracYFromBottom

        let windowLocalX = fracX * nativeSize.width
        let windowLocalY = fracYFromTop * nativeSize.height

        return CGPoint(
            x: windowGlobalFrame.origin.x + windowLocalX,
            y: windowGlobalFrame.origin.y + windowLocalY
        )
    }
}
