import AppKit
import CoreGraphics

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
    let displayID: CGDirectDisplayID
    /// The window server registers a virtual display's geometry asynchronously — apply(settings)
    /// returning true only means the settings were accepted, not that CGDisplayBounds is
    /// populated yet, so this reads live rather than being cached at init time.
    var bounds: CGRect { CGDisplayBounds(displayID) }

    private let virtualDisplay: CGVirtualDisplay

    /// menuBarInset accounts for the strip at the top of every display (real or virtual) that
    /// macOS reserves for a menu bar — window content should be positioned below it so capture
    /// cropping doesn't clip the window's own title bar against it.
    static let menuBarInset: CGFloat = 44

    /// The display is always created at this size (CaptureSession.start() passes it directly as
    /// both the descriptor's ceiling and the initial applied mode) — a generous, fixed "biggest
    /// normal monitor" canvas rather than one sized to the captured window, so a later PiP-panel
    /// resize (CaptureSession.resizeSourceWindow) always has room to grow the window into without
    /// needing to change the display's own resolution mid-session. (An earlier version tried
    /// exactly that — re-applying a bigger CGVirtualDisplayMode after creation, the pattern
    /// BetterDisplay/DeskPad document for this private API — but it didn't reliably take effect
    /// against a display an SCStream was already actively capturing, so a PiP resize would only
    /// track correctly up to whatever slack the *initial*, window-sized mode happened to leave.)
    /// SCStreamConfiguration.sourceRect already crops the capture down to just the window's own
    /// rect regardless of how big this canvas is (see makeConfiguration), so there's no meaningful
    /// capture-bandwidth cost to always using the full ceiling.
    static let maxPixelsWide = 2560
    static let maxPixelsHigh = 1600

    /// Each concurrent session needs its own (vendorID, productID, serialNum) identity — reusing
    /// the same triple for multiple simultaneous virtual displays risks macOS treating them as
    /// "the same display" reappearing rather than genuinely separate ones (M4: multi-session).
    private static var nextSerialNum: UInt32 = 1

    init?(pixelWidth: Int, pixelHeight: Int, name: String) {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.name = name
        descriptor.maxPixelsWide = UInt32(Self.maxPixelsWide)
        descriptor.maxPixelsHigh = UInt32(Self.maxPixelsHigh)
        descriptor.sizeInMillimeters = CGSize(width: CGFloat(Self.maxPixelsWide) / 4, height: CGFloat(Self.maxPixelsHigh) / 4)
        descriptor.serialNum = Self.nextSerialNum
        Self.nextSerialNum += 1
        descriptor.productID = 0x1
        descriptor.vendorID = 0x1AE7 // arbitrary, unregistered vendor ID block

        virtualDisplay = CGVirtualDisplay(descriptor: descriptor)

        let mode = CGVirtualDisplayMode(width: pixelWidth, height: pixelHeight, refreshRate: 60)
        let settings = CGVirtualDisplaySettings()
        settings.modes = [mode]
        settings.hiDPI = 0
        guard virtualDisplay.apply(settings) else { return nil }

        displayID = virtualDisplay.displayID
        guard displayID != kCGNullDirectDisplay else { return nil }

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
    }
}
