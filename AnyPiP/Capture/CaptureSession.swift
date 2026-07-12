import ScreenCaptureKit
import CoreMedia
import AppKit
import ApplicationServices

protocol CaptureSessionDelegate: AnyObject {
    func captureSession(_ session: CaptureSession, didOutput sampleBuffer: CMSampleBuffer)
    func captureSessionDidStop(_ session: CaptureSession, error: Error?)
}

enum CaptureSessionError: Error {
    case windowNotAccessible
    case virtualDisplayCreationFailed
    case virtualDisplayNotVisibleToScreenCaptureKit
}

/// Owns one PiP capture session: creates a private virtual display, relocates the source
/// window onto it via Accessibility, and streams that display via ScreenCaptureKit.
///
/// Why a virtual display instead of capturing the window in place: SCContentFilter's two
/// window-scoped filter types were both verified (Spikes/CaptureSpike) to break for this
/// product's core requirement —
///   - desktopIndependentWindow (macOS 14+, nominally "survives Space changes"): delivers
///     exactly one status-only frame and then silently stalls forever on this OS build.
///   - display(_:including:): streams reliably, but only while the window's Space is the
///     currently active one — the moment another app goes full-screen elsewhere, frames keep
///     arriving but are blank.
/// A private virtual display (Spikes/VirtualDisplaySpike) doesn't have this problem: it's a
/// genuinely independent, always-composited display, so display(_:excludingWindows:) against it
/// streams continuously regardless of what's happening on the physical screen. The tradeoff is
/// the window physically leaves the user's real screens for as long as the session is active —
/// SourceWindowActivator (M2/M3) is responsible for moving it back for interaction and restoring
/// it on session stop.
///
/// One more sharp edge (Spikes/VirtualDisplaySpike): a virtual display created *small* (roughly
/// window-sized, e.g. ~500x460) reliably gets placed by macOS at the same (0,0) origin as the
/// main display instead of being extended beside it — the two overlap in global coordinate
/// space, which made a window moved onto the virtual display ambiguously render back on the
/// real screen, and in one case made macOS mirror the physical display down to the tiny
/// resolution instead. A virtual display created at a "normal monitor" size (1280x800) was
/// reliably placed beside the physical display with no overlap. So the virtual display is
/// always created at a generous floor size regardless of the source window's size, and
/// SCStreamConfiguration.sourceRect crops down to just the window's own rect within it.
final class CaptureSession: NSObject {
    /// .pip: window sits on the virtual display, panel shows a live mirror.
    /// .sourceActive: the source app is frontmost, so the window has been pulled back onto the
    /// physical screen where the user can actually see/use it (M3) — there's nothing useful to
    /// mirror while that's true, so the panel hides itself.
    enum PresentationState {
        case pip
        case sourceActive
    }

    let windowInfo: WindowInfo
    weak var delegate: CaptureSessionDelegate?

    private(set) var virtualDisplayHost: VirtualDisplayHost?
    private(set) var originalFrame: CGRect?
    private(set) var axWindow: AXUIElement?
    private(set) var framedRect: CGRect = .zero
    private(set) var presentationState: PresentationState = .pip

    /// Set by InteractionForwarder right before it activates the source app just to deliver a
    /// forwarded click/keystroke — PiPSessionManager consumes (and clears) this to tell that
    /// apart from the user genuinely switching to the app (Cmd+Tab, Dock, "jump to source"), so
    /// operating the PiP thumbnail doesn't itself yank the window onto the physical screen and
    /// hide the panel (M3's transition is for real switches only).
    var suppressNextActivationTransition = false

    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "com.anypip.mac.capture.sampleQueue")
    private var lastFrameDate = Date()
    private var stallTimer: DispatchSourceTimer?

    var targetFPS: Int = 15 {
        didSet { Task { try? await applyConfiguration() } }
    }

    init(windowInfo: WindowInfo) {
        self.windowInfo = windowInfo
    }

    func start() async throws {
        // Serialized: see VirtualDisplayCoordinator for why concurrent session startups aren't safe.
        await VirtualDisplayCoordinator.shared.lock()
        defer { Task { await VirtualDisplayCoordinator.shared.unlock() } }

        guard let axWindow = AXWindowLocator.locate(windowInfo) else {
            throw CaptureSessionError.windowNotAccessible
        }
        self.axWindow = axWindow
        let originalFrame = AXWindowLocator.frame(of: axWindow) ?? windowInfo.frame
        self.originalFrame = originalFrame

        let margin = VirtualDisplayHost.menuBarInset
        // Floor at 1280x800 ("normal monitor" size) regardless of the window's own size — see
        // the size/placement note above.
        let pixelWidth = max(Int(originalFrame.width), 1280)
        let pixelHeight = max(Int(originalFrame.height) + Int(margin) + 20, 800)
        // CGVirtualDisplay must be created on the main thread — off-main creation was
        // observed to silently produce a display that never shows up in
        // SCShareableContent's display list.
        let host = try await MainActor.run { () -> VirtualDisplayHost in
            guard let host = VirtualDisplayHost(
                pixelWidth: min(pixelWidth, 2560),
                pixelHeight: min(pixelHeight, 1600),
                name: "AnyPiP – \(windowInfo.ownerAppName)"
            ) else {
                throw CaptureSessionError.virtualDisplayCreationFailed
            }
            return host
        }
        virtualDisplayHost = host

        try await moveWindowOntoVirtualDisplay(host: host, axWindow: axWindow, size: originalFrame.size)
        presentationState = .pip

        let scDisplay = try await Self.waitForShareableDisplay(matching: host.displayID)

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let config = Self.makeConfiguration(for: framedRect, displaySize: host.bounds.size, fps: targetFPS)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
        startStallWatchdog()
        AnyPiPLogger.capture.info("Capture started for window \(self.windowInfo.id) (\(self.windowInfo.ownerAppName)) via virtual display \(host.displayID)")
    }

    /// Moves the window onto the virtual display at the standard offset (below the menu-bar
    /// strip every display renders) and updates framedRect to match its real resulting
    /// position — shared by start() and enterPiPState() (M3's resume-after-switch-away).
    private func moveWindowOntoVirtualDisplay(host: VirtualDisplayHost, axWindow: AXUIElement, size: CGSize) async throws {
        let margin = VirtualDisplayHost.menuBarInset
        let bounds = try await Self.waitForValidBounds(of: host)

        let targetOrigin = CGPoint(x: bounds.origin.x, y: bounds.origin.y + margin)
        let targetFrame = CGRect(origin: targetOrigin, size: size)
        AXWindowLocator.setFrame(targetFrame, on: axWindow)

        // Give the window server a moment to actually move/redraw the window before we read
        // back its real resulting frame (some apps clamp size/position asynchronously).
        try? await Task.sleep(nanoseconds: 150_000_000)
        let resultingFrame = AXWindowLocator.frame(of: axWindow) ?? targetFrame
        framedRect = CGRect(
            x: resultingFrame.origin.x - bounds.origin.x,
            y: resultingFrame.origin.y - bounds.origin.y,
            width: resultingFrame.width,
            height: resultingFrame.height
        )
    }

    /// The source app just became frontmost (M3) — pull its window back onto the physical
    /// screen so the user can actually see/use it directly; there's nothing useful left for the
    /// PiP panel to mirror while that's true, so PiPSessionManager hides it in response.
    func enterSourceActiveState() {
        guard presentationState == .pip else { return }
        restoreWindowIfNeeded()
        presentationState = .sourceActive
    }

    /// The user switched away from the source app again (M3) — move its window back onto the
    /// (still-alive) virtual display to resume the live PiP mirror, and retarget the running
    /// stream's crop at its new position.
    func enterPiPState() async {
        guard presentationState == .sourceActive,
              let host = virtualDisplayHost, let axWindow, let originalFrame else { return }
        do {
            try await moveWindowOntoVirtualDisplay(host: host, axWindow: axWindow, size: originalFrame.size)
            if let stream {
                let config = Self.makeConfiguration(for: framedRect, displaySize: host.bounds.size, fps: targetFPS)
                try await stream.updateConfiguration(config)
            }
            presentationState = .pip
        } catch {
            AnyPiPLogger.capture.error("Failed to resume PiP for window \(self.windowInfo.id): \(error)")
        }
    }

    /// CGVirtualDisplay's apply(settings:) returning true only means the settings were
    /// accepted — CGDisplayBounds can still read all-zero for a brief moment until the window
    /// server finishes registering the display's geometry.
    private static func waitForValidBounds(of host: VirtualDisplayHost) async throws -> CGRect {
        for attempt in 0..<10 {
            let bounds = host.bounds
            if bounds.width > 0, bounds.height > 0 {
                return bounds
            }
            if attempt < 9 {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        throw CaptureSessionError.virtualDisplayCreationFailed
    }

    /// A newly-created virtual display was observed (Spikes/VirtualDisplaySpike) to take
    /// anywhere from under a second up to ~5s to propagate to this process's
    /// ScreenCaptureKit/AppKit view of the display list — retry with a generous budget rather
    /// than failing outright.
    private static func waitForShareableDisplay(matching displayID: CGDirectDisplayID) async throws -> SCDisplay {
        for attempt in 0..<20 {
            let content = try await SCShareableContent.current
            if let match = content.displays.first(where: { $0.displayID == displayID }) {
                return match
            }
            if attempt < 19 {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        throw CaptureSessionError.virtualDisplayNotVisibleToScreenCaptureKit
    }

    func stop() async {
        stallTimer?.cancel()
        stallTimer = nil
        if let stream {
            self.stream = nil
            try? await stream.stopCapture()
        }
        restoreWindowIfNeeded()
        virtualDisplayHost = nil // deallocating tears the virtual display down
        AnyPiPLogger.capture.info("Capture stopped for window \(self.windowInfo.id)")
    }

    /// Moves the source window back to its pre-session position — used both on session stop and
    /// by enterSourceActiveState() (M3), so it reappears on the user's real screen.
    func restoreWindowIfNeeded() {
        guard let axWindow, let originalFrame else { return }
        AXWindowLocator.setFrame(originalFrame, on: axWindow)
    }

    /// The source window's live on-screen frame (Quartz space), used by InteractionForwarder to
    /// map a PiP-panel click onto the window's actual current position on the virtual display.
    /// Re-queried live via AX rather than cached, in case the window resizes/moves on its own.
    func currentSourceWindowFrame() -> CGRect? {
        guard let axWindow else { return nil }
        return AXWindowLocator.frame(of: axWindow)
    }

    private func applyConfiguration() async throws {
        guard let stream, let host = virtualDisplayHost else { return }
        let config = Self.makeConfiguration(for: framedRect, displaySize: host.bounds.size, fps: targetFPS)
        try await stream.updateConfiguration(config)
    }

    private static func makeConfiguration(for localRect: CGRect, displaySize: CGSize, fps: Int) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(fps, 1)))
        config.queueDepth = 5

        // Crop to just the window's rect within the virtual display, so the surrounding
        // wallpaper/menu bar that every display (real or virtual) renders doesn't show up.
        let clamped = localRect.intersection(CGRect(origin: .zero, size: displaySize))
        let sourceRect = clamped.isEmpty ? CGRect(origin: .zero, size: displaySize) : clamped
        config.sourceRect = sourceRect

        let maxLongEdge: CGFloat = 1280
        let longEdge = max(sourceRect.width, sourceRect.height)
        let scale = longEdge > maxLongEdge ? maxLongEdge / longEdge : 1
        config.width = max(Int(sourceRect.width * scale), 2)
        config.height = max(Int(sourceRect.height * scale), 2)
        return config
    }

    private func startStallWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: sampleQueue)
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastFrameDate) > 3 {
                AnyPiPLogger.capture.warning("No frames received for 3s+ for window \(self.windowInfo.id)")
            }
        }
        timer.resume()
        stallTimer = timer
    }
}

extension CaptureSession: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }

        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachmentsArray.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete else {
            return
        }

        lastFrameDate = Date()
        delegate?.captureSession(self, didOutput: sampleBuffer)
    }
}

extension CaptureSession: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        AnyPiPLogger.capture.error("Stream stopped with error: \(error.localizedDescription)")
        delegate?.captureSessionDidStop(self, error: error)
    }
}
