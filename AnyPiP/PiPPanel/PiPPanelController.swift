import AppKit
import CoreMedia

protocol PiPPanelControllerDelegate: AnyObject {
    func pipPanelControllerDidRequestClose(_ controller: PiPPanelController)
    func pipPanelControllerDidRequestJumpToSource(_ controller: PiPPanelController)
}

/// NSPanel defaults canBecomeKey to false for borderless windows — we need it true so the panel
/// can receive keyDown events to forward (InteractionForwarder), even though it never activates
/// the app (still .nonactivatingPanel).
private final class InteractivePiPPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// A floating, non-activating panel that stays visible above other apps' full-screen Spaces.
/// Level/collectionBehavior combination verified in Spikes/FullScreenOverlaySpike.
@MainActor
final class PiPPanelController: NSObject {
    weak var delegate: PiPPanelControllerDelegate?
    var interactionForwarder: InteractionForwarder?

    let panel: NSPanel
    let videoView: PiPVideoLayerView

    init(initialFrame: NSRect, nativeSize: CGSize) {
        panel = InteractivePiPPanel(
            contentRect: initialFrame,
            styleMask: [.nonactivatingPanel, .borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        videoView = PiPVideoLayerView(frame: NSRect(origin: .zero, size: initialFrame.size))

        super.init()

        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // A plain drag on the content forwards to the source window (InteractionForwarder), so
        // it can't also move the panel — PiPVideoLayerView implements Option+drag to move
        // (dragging mostly off-screen or into the screen's lower half closes it) and edge-drag
        // to resize instead.
        panel.isMovableByWindowBackground = false
        panel.minSize = NSSize(width: 160, height: 100)
        panel.delegate = self

        videoView.autoresizingMask = [.width, .height]
        videoView.interactionDelegate = self
        panel.contentView = videoView

        animateEntrance(to: initialFrame)
    }

    /// Pops the panel in by sliding it from off past the right edge of its screen to
    /// `finalFrame` — chosen over animating anything about the real source window (tried:
    /// shrinking/translating/fading it via a burst of manual Accessibility frame/alpha updates —
    /// reverted, since each step is a real IPC round-trip to a different process rather than a
    /// GPU-composited animation, and was visibly janky). Sliding the panel is our own NSView/
    /// CALayer being animated by AppKit directly, so it's smooth regardless of what the source
    /// app is doing. Finishes with a one-shot ripple flourish on the video view itself (see
    /// PiPVideoLayerView.playAppearRipple).
    private func animateEntrance(to finalFrame: NSRect) {
        let screen = NSScreen.screens.first { $0.frame.intersects(finalFrame) } ?? NSScreen.main
        let offscreenX = (screen?.frame.maxX ?? finalFrame.maxX) + finalFrame.width
        let startFrame = NSRect(x: offscreenX, y: finalFrame.origin.y, width: finalFrame.width, height: finalFrame.height)

        panel.setFrame(startFrame, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(finalFrame, display: true)
            panel.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            self?.videoView.playAppearRipple()
        })
    }

    /// Shrinks and fades the panel out before actually closing it — instant removal (the old
    /// behavior) felt abrupt for something the user just deliberately dragged into a close zone
    /// or dismissed from the menu; this mirrors the shrink-in entrance from a flung-window open.
    func close() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            let frame = panel.frame
            panel.animator().setFrame(frame.insetBy(dx: frame.width * 0.08, dy: frame.height * 0.08), display: true)
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
        })
    }

    /// Fades the panel in/out — used when the source app becomes frontmost (M3): showing a
    /// thumbnail of the window the user is already looking at directly is pointless, so it
    /// hides itself until they switch away again. ignoresMouseEvents keeps a hidden (alpha 0)
    /// panel from swallowing clicks meant for whatever's actually behind it.
    func setLive(_ live: Bool, animated: Bool = true) {
        panel.ignoresMouseEvents = !live
        if live { panel.orderFrontRegardless() }
        let applyAlpha = { self.panel.animator().alphaValue = live ? 1 : 0 }
        guard animated else {
            panel.alphaValue = live ? 1 : 0
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            applyAlpha()
        }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer, nativeSize: CGSize) {
        videoView.enqueue(sampleBuffer, nativeSize: nativeSize)
    }
}

extension PiPPanelController: NSWindowDelegate {
    func windowDidEndLiveResize(_ notification: Notification) {
        AnyPiPLogger.panel.debug("Panel resized to \(self.panel.frame.width)x\(self.panel.frame.height)")
    }
}

extension PiPPanelController: PiPVideoLayerViewDelegate {
    func videoView(_ view: PiPVideoLayerView, didClickAt localPoint: CGPoint, button: CGMouseButton) {
        let displayedRect = view.displayedVideoRect(nativeSize: view.nativeSize)
        interactionForwarder?.forwardClick(
            atLocalPoint: localPoint,
            viewBounds: view.bounds,
            nativeSize: view.nativeSize,
            displayedVideoRect: displayedRect,
            button: button
        )
    }

    func videoView(_ view: PiPVideoLayerView, didDoubleClickAt localPoint: CGPoint) {
        delegate?.pipPanelControllerDidRequestJumpToSource(self)
    }

    func videoView(_ view: PiPVideoLayerView, didScrollAt localPoint: CGPoint, deltaX: Int32, deltaY: Int32) {
        let displayedRect = view.displayedVideoRect(nativeSize: view.nativeSize)
        interactionForwarder?.forwardScroll(
            atLocalPoint: localPoint,
            viewBounds: view.bounds,
            nativeSize: view.nativeSize,
            displayedVideoRect: displayedRect,
            deltaY: deltaY,
            deltaX: deltaX
        )
    }

    func videoView(_ view: PiPVideoLayerView, didReceiveKeyEvent event: NSEvent) {
        interactionForwarder?.forwardKeyEvent(event)
    }

    func videoViewDidRequestCloseByDragging(_ view: PiPVideoLayerView) {
        delegate?.pipPanelControllerDidRequestClose(self)
    }
}
