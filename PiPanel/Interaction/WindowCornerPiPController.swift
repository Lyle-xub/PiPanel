import AppKit
import ApplicationServices
import CoreGraphics
import QuartzCore

/// Reveals a small PiP switch when the pointer reaches the top-right corner of the frontmost normal
/// window. Nothing is injected into another process: two non-activating transparent panels sit
/// above the source only while hovered. The large fan panel is click-through; the second panel is
/// exactly the compact corner button's size, so the visual effect never turns a 132pt square of the
/// source window into a dead input region.
@MainActor
final class WindowCornerPiPController {
    var onRequestPiP: ((WindowInfo) -> Void)?

    private struct Candidate: Equatable {
        let windowID: CGWindowID
        let ownerPID: pid_t
        let frame: CGRect // Quartz global coordinates, top-left origin
    }

    private enum Constants {
        static let hotEdge: CGFloat = 58
        static let fanExtent: CGFloat = 132
        static let buttonOutsideReach: CGFloat = 24
        static let probeInterval: TimeInterval = 0.06
    }

    private let overlay = WindowCornerPiPOverlay()
    private var globalMoveMonitor: Any?
    private var localMoveMonitor: Any?
    private var currentCandidate: Candidate?
    private var lastProbeTime: TimeInterval = 0
    private var activationTask: Task<Void, Never>?

    init() {
        overlay.onActivate = { [weak self] in
            self?.activateCurrentCandidate()
        }
    }

    func start() {
        guard globalMoveMonitor == nil else { return }
        globalMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            Task { @MainActor in self?.pointerDidMove() }
        }
        // Global monitors do not receive events delivered to this app's tiny button panel. A local
        // monitor keeps the fan visible while crossing onto the button and hides it on exit.
        localMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            Task { @MainActor in self?.pointerDidMove() }
            return event
        }
        PiPanelLogger.interaction.debug("WindowCornerPiPController started")
    }

    func stop() {
        if let globalMoveMonitor { NSEvent.removeMonitor(globalMoveMonitor) }
        if let localMoveMonitor { NSEvent.removeMonitor(localMoveMonitor) }
        globalMoveMonitor = nil
        localMoveMonitor = nil
        activationTask?.cancel()
        activationTask = nil
        currentCandidate = nil
        overlay.hideImmediately()
    }

    private func pointerDidMove() {
        guard PermissionsManager.shared.hasAllPermissions else {
            clearCandidate()
            return
        }

        let point = Self.quartzPoint(from: NSEvent.mouseLocation)
        if let currentCandidate,
           Self.retentionRect(for: currentCandidate.frame).contains(point) {
            overlay.show(atTopRightOf: currentCandidate.frame)
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastProbeTime >= Constants.probeInterval else { return }
        lastProbeTime = now

        guard let candidate = Self.frontmostCandidate(at: point) else {
            clearCandidate()
            return
        }
        currentCandidate = candidate
        overlay.show(atTopRightOf: candidate.frame)
    }

    private func clearCandidate() {
        guard currentCandidate != nil || overlay.isVisible else { return }
        currentCandidate = nil
        overlay.hide()
    }

    private func activateCurrentCandidate() {
        guard let candidate = currentCandidate else { return }
        currentCandidate = nil
        overlay.hideImmediately()
        activationTask?.cancel()
        activationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let windows = try await WindowEnumerator.listPiPCandidateWindows()
                guard !Task.isCancelled,
                      var window = windows.first(where: {
                          $0.id == candidate.windowID && $0.ownerPID == candidate.ownerPID
                      }) else {
                    PiPanelLogger.interaction.debug("Corner switch: window \(candidate.windowID) is no longer eligible")
                    return
                }
                // CGWindowList's hover-time frame is newer than an asynchronously-enumerated SC
                // snapshot and uses the same Quartz space. Preserve it so panel placement follows
                // the source monitor even immediately after the window crossed displays.
                window.frame = candidate.frame
                PiPanelLogger.interaction.debug("Corner switch: starting PiP session for \(window.title)")
                onRequestPiP?(window)
            } catch {
                PiPanelLogger.interaction.error("Corner switch failed to enumerate windows: \(error.localizedDescription)")
            }
        }
    }

    /// CGWindowListCopyWindowInfo is ordered front-to-back. Stop at the first layer-zero window
    /// containing the pointer: if its corner is not being hovered, an obscured window underneath
    /// must not reveal a switch through it.
    private static func frontmostCandidate(at point: CGPoint) -> Candidate? {
        guard let rawWindows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        for window in rawWindows {
            guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let ownerPID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  ownerPID != ownPID,
                  let windowID = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  frame.width > 60, frame.height > 60,
                  ((window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0.01,
                  frame.contains(point) else { continue }

            let hotRect = CGRect(
                x: frame.maxX - min(Constants.hotEdge, frame.width),
                y: frame.minY,
                width: min(Constants.hotEdge, frame.width),
                height: min(Constants.hotEdge, frame.height)
            )
            guard hotRect.contains(point) else { return nil }
            return Candidate(windowID: CGWindowID(windowID), ownerPID: ownerPID, frame: frame)
        }
        return nil
    }

    private static func retentionRect(for frame: CGRect) -> CGRect {
        CGRect(
            x: frame.maxX - min(Constants.fanExtent, frame.width),
            y: frame.minY - Constants.buttonOutsideReach,
            width: min(Constants.fanExtent, frame.width) + Constants.buttonOutsideReach,
            height: min(Constants.fanExtent, frame.height) + Constants.buttonOutsideReach
        )
    }

    private static func quartzPoint(from appKitPoint: CGPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CoordinateTranslator.quartzPoint(
            fromAppKitPoint: appKitPoint,
            primaryScreenHeight: primaryHeight
        )
    }
}

/// Owns the click-through light fan and the small interactive switch as separate windows.
@MainActor
private final class WindowCornerPiPOverlay {
    var onActivate: (() -> Void)?
    private(set) var isVisible = false

    private enum Metrics {
        static let fanExtent: CGFloat = 132
        static let buttonSize: CGFloat = 42
        /// The compact button straddles the real window corner, matching the supplied sketch.
        static let buttonCornerOverlap: CGFloat = 20
    }

    private let fanView = CornerFanView(frame: NSRect(x: 0, y: 0, width: Metrics.fanExtent, height: Metrics.fanExtent))
    private let buttonView = CornerPiPButtonView(frame: NSRect(x: 0, y: 0, width: Metrics.buttonSize, height: Metrics.buttonSize))
    private let fanPanel: NSPanel
    private let buttonPanel: NSPanel
    private var animationGeneration = 0
    private var lastWindowFrame: CGRect?

    init() {
        fanPanel = Self.makePanel(frame: fanView.frame, ignoresMouseEvents: true)
        buttonPanel = Self.makePanel(frame: buttonView.frame, ignoresMouseEvents: false)
        fanPanel.contentView = fanView
        buttonPanel.contentView = buttonView
        buttonView.onActivate = { [weak self] in self?.onActivate?() }
    }

    func show(atTopRightOf quartzWindowFrame: CGRect) {
        animationGeneration += 1
        if lastWindowFrame != quartzWindowFrame {
            lastWindowFrame = quartzWindowFrame
            let fanQuartzFrame = CGRect(
                x: quartzWindowFrame.maxX - Metrics.fanExtent,
                y: quartzWindowFrame.minY,
                width: Metrics.fanExtent,
                height: Metrics.fanExtent
            )
            let buttonQuartzFrame = CGRect(
                x: quartzWindowFrame.maxX - Metrics.buttonCornerOverlap,
                y: quartzWindowFrame.minY - Metrics.buttonCornerOverlap,
                width: Metrics.buttonSize,
                height: Metrics.buttonSize
            )
            fanPanel.setFrame(Self.appKitFrame(fromQuartzFrame: fanQuartzFrame), display: true)
            buttonPanel.setFrame(Self.appKitFrame(fromQuartzFrame: buttonQuartzFrame), display: true)
        }

        guard !isVisible else { return }
        isVisible = true
        fanPanel.alphaValue = 0
        buttonPanel.alphaValue = 0
        fanPanel.orderFrontRegardless()
        buttonPanel.orderFrontRegardless()
        fanView.restartLightAnimation()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            fanPanel.animator().alphaValue = 1
            buttonPanel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        animationGeneration += 1
        let generation = animationGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.13
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            fanPanel.animator().alphaValue = 0
            buttonPanel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.animationGeneration == generation, !self.isVisible else { return }
                self.fanPanel.orderOut(nil)
                self.buttonPanel.orderOut(nil)
            }
        }
    }

    func hideImmediately() {
        animationGeneration += 1
        isVisible = false
        lastWindowFrame = nil
        fanPanel.alphaValue = 0
        buttonPanel.alphaValue = 0
        fanPanel.orderOut(nil)
        buttonPanel.orderOut(nil)
    }

    private static func makePanel(frame: NSRect, ignoresMouseEvents: Bool) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = ignoresMouseEvents
        return panel
    }

    /// Converts a Quartz top-left-origin rectangle into AppKit's bottom-left-origin global space.
    private static func appKitFrame(fromQuartzFrame frame: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CoordinateTranslator.appKitFrame(
            fromQuartzFrame: frame,
            primaryScreenHeight: primaryHeight
        )
    }
}

/// Quarter-circle blur whose focus sits just beyond the source window's top-right corner. The
/// material mask grows denser with distance from that focus, giving the requested progression from
/// a relatively crisp center into stronger blur farther out; the final few points feather to clear
/// so the fan still ends without a hard circular seam.
private final class CornerFanView: NSView {
    private let effectView = NSVisualEffectView()
    private let featherMask = CAGradientLayer()
    private let lightLayer = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true

        // Mask the *entire* view rather than NSVisualEffectView alone. Backdrop material is
        // composited by WindowServer and could otherwise leave a faint rectangular footprint even
        // when its child layer looked masked. This single radial mask clips material and tint
        // together, removing that square while preserving the feathered circular edge.
        featherMask.type = .radial
        featherMask.colors = [
            NSColor.black.withAlphaComponent(0.12).cgColor,
            NSColor.black.withAlphaComponent(0.42).cgColor,
            NSColor.black.withAlphaComponent(0.78).cgColor,
            NSColor.black.withAlphaComponent(0.96).cgColor,
            NSColor.black.withAlphaComponent(0.52).cgColor,
            NSColor.clear.cgColor,
        ]
        featherMask.locations = [0, 0.24, 0.54, 0.79, 0.91, 1]
        featherMask.startPoint = CGPoint(x: 1.06, y: 1.06)
        featherMask.endPoint = CGPoint(x: -0.04, y: 1.06)
        layer?.mask = featherMask

        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        addSubview(effectView)

        lightLayer.type = .radial
        lightLayer.colors = [
            NSColor(calibratedRed: 0.005, green: 0.035, blue: 0.12, alpha: 0.78).cgColor,
            NSColor(calibratedRed: 0.01, green: 0.08, blue: 0.28, alpha: 0.64).cgColor,
            NSColor(calibratedRed: 0.03, green: 0.16, blue: 0.46, alpha: 0.36).cgColor,
            NSColor.clear.cgColor,
        ]
        lightLayer.locations = [0, 0.34, 0.76, 1]
        lightLayer.startPoint = CGPoint(x: 1.06, y: 1.06)
        lightLayer.endPoint = CGPoint(x: -0.04, y: 1.06)
        lightLayer.zPosition = 10
        layer?.addSublayer(lightLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        effectView.frame = bounds
        featherMask.frame = bounds
        lightLayer.frame = bounds
    }

    func restartLightAnimation() {
        lightLayer.removeAnimation(forKey: "cornerLight")
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0.35
        animation.toValue = 1
        animation.duration = 0.28
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        lightLayer.add(animation, forKey: "cornerLight")
    }
}

private final class CornerPiPButtonView: NSView {
    var onActivate: (() -> Void)?

    private let effectView = NSVisualEffectView()
    private let effectMask = CAShapeLayer()
    private let buttonShapeLayer = CAShapeLayer()
    private let symbolView = NSImageView()
    private var isPressed = false
    private var buttonPath = CGPath(rect: .zero, transform: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.mask = effectMask
        addSubview(effectView)

        buttonShapeLayer.fillColor = NSColor(
            calibratedRed: 0.004,
            green: 0.035,
            blue: 0.13,
            alpha: 0.94
        ).cgColor
        buttonShapeLayer.strokeColor = NSColor.white.withAlphaComponent(0.40).cgColor
        buttonShapeLayer.lineWidth = 0.9
        // No CALayer/NSWindow shadow here: even a transparent panel can expose its rectangular
        // backing extent through a backdrop shadow. The crisp translucent stroke supplies enough
        // separation without recreating the reported square artifact.
        buttonShapeLayer.shadowOpacity = 0
        layer?.addSublayer(buttonShapeLayer)

        symbolView.image = NSImage(
            systemSymbolName: "pip.enter",
            accessibilityDescription: "进入画中画"
        ) ?? NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "进入画中画")
        symbolView.contentTintColor = .white
        symbolView.imageScaling = .scaleProportionallyDown
        addSubview(symbolView)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        effectView.frame = bounds
        buttonPath = CGPath(ellipseIn: bounds.insetBy(dx: 2, dy: 2), transform: nil)
        effectMask.frame = bounds
        effectMask.path = buttonPath
        buttonShapeLayer.frame = bounds
        buttonShapeLayer.path = buttonPath
        symbolView.frame = bounds.insetBy(dx: 11, dy: 11)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard buttonPath.contains(convert(event.locationInWindow, from: nil)) else { return }
        isPressed = true
        setPressedAppearance(true)
    }

    override func mouseUp(with event: NSEvent) {
        let shouldActivate = isPressed && buttonPath.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        setPressedAppearance(false)
        if shouldActivate { onActivate?() }
    }

    private func setPressedAppearance(_ pressed: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            animator().alphaValue = pressed ? 0.72 : 1
        }
    }

}
