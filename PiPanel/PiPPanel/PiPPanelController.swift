import AppKit
import CoreMedia

protocol PiPPanelControllerDelegate: AnyObject {
    func pipPanelControllerDidRequestClose(_ controller: PiPPanelController)
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
    /// Setting this wires it up with the geometry (panel/videoView) it needs for cursor-capture
    /// coordinate math — see InteractionForwarder.attach(videoView:panel:) — and subscribes to
    /// CaptureSession discovering the source app's real minimum/maximum size (see
    /// CaptureSession.onSourceMinSizeDiscovered/onSourceMaxSizeDiscovered's doc comments).
    var interactionForwarder: InteractionForwarder? {
        didSet {
            interactionForwarder?.attach(videoView: videoView, panel: panel)
            interactionForwarder?.captureSession?.onSourceMinSizeDiscovered = { [weak self] discoveredSize in
                guard let self else { return }
                self.discoveredSourceMinSize = discoveredSize
                self.updateContentScalingMode()
            }
            interactionForwarder?.captureSession?.onSourceMaxSizeDiscovered = { [weak self] discoveredSize in
                guard let self else { return }
                self.discoveredSourceMaxSize = discoveredSize
                self.updateContentScalingMode()
            }
        }
    }

    let panel: NSPanel
    let videoView: PiPVideoLayerView
    /// The source app's own minimum size, once CaptureSession has discovered it by having a
    /// shrink request rejected — nil until then, meaning "unknown, so keep trying to resize the
    /// source for now." See updateContentScalingMode's doc comment for how this is used.
    private var discoveredSourceMinSize: CGSize?
    /// The mirror image, for a growth request rejected — nil until then, same "unknown" meaning.
    private var discoveredSourceMaxSize: CGSize?

    init(initialFrame: NSRect, nativeSize: CGSize) {
        // No .resizable here — PiPVideoLayerView implements the entire drag-to-resize gesture
        // itself (edge detection, live tracking, min/maxSize clamping) via window.setFrame calls
        // that don't need it. Diagnostic logging (traced via a live session) found .resizable
        // was actively harmful: AppKit still installs its own native edge/corner resize hit-
        // testing for a *borderless* resizable window, and that native handling intercepted
        // mouseDown before it ever reached PiPVideoLayerView — so every PiP-panel resize was
        // silently going through macOS's own resize machinery instead of this app's, which never
        // calls PiPVideoLayerViewDelegate.didResizeTo and therefore never told CaptureSession to
        // resize the source window. The panel still visibly resized (native resize obviously
        // works), which is exactly what made this so hard to track down — it looked like our own
        // resize code was running and just not reaching the source window, when actually our
        // resize code was never running at all.
        panel = InteractivePiPPanel(
            contentRect: initialFrame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        videoView = PiPVideoLayerView(frame: NSRect(origin: .zero, size: initialFrame.size))

        super.init()

        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = SettingsStore.shared.panelShadowEnabled
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // A plain hover over the content hands control to InteractionForwarder's cursor capture,
        // so it can't also move the panel — PiPVideoLayerView implements Option+drag to move
        // (dragging mostly off-screen or into the screen's lower half closes it) and edge-drag
        // to resize instead.
        panel.isMovableByWindowBackground = false
        panel.minSize = NSSize(width: 160, height: 100)
        // Caps the panel at what CaptureSession.clampToDeliverableSize can actually deliver on the
        // virtual display (maxPixelsWide/High minus the same edgeMargin/menuBarInset placement
        // insets it itself subtracts) — without this, nothing stopped PiPVideoLayerView's custom
        // edge-drag from growing the panel past that ceiling: the real source window would
        // silently get clamped there while the panel kept growing, so the mirror stopped matching
        // the panel's shape the further past it you dragged.
        //
        // This is only an *aspirational* value — the virtual display doesn't exist yet at panel-
        // creation time, so there's nothing more specific to go on. It gets corrected downward
        // once the display's real (possibly smaller — see CaptureSession.deliverableMaxSize's doc
        // comment) live bounds are known; see didResizeTo below.
        panel.maxSize = NSSize(
            width: CGFloat(VirtualDisplayHost.maxPixelsWide) - CaptureSession.edgeMargin * 2,
            height: CGFloat(VirtualDisplayHost.maxPixelsHigh) - VirtualDisplayHost.menuBarInset - CaptureSession.edgeMargin
        )
        // Needed for PiPVideoLayerView.mouseMoved to fire at all — that's what detects a plain
        // hover and hands it to cursor capture.
        panel.acceptsMouseMovedEvents = true

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

    /// Deliberately a *different* condition than applyPanelResize's own both-dimensions check for
    /// whether to skip touching the source window at all (CaptureSession.applyPanelResize's doc
    /// comment) — those two decisions look similar but aren't the same question. Skipping AX calls
    /// entirely is only worth doing once *neither* axis has anywhere left to go (both pinned), so
    /// the other axis's still-live tracking isn't interrupted. But the *visual* mode only needs one
    /// axis to be pinned to matter: once any axis is stuck at a discovered bound — including an
    /// app whose window is genuinely locked to a single fixed width while its height stays fully
    /// adjustable (observed: a settings-pane window where discoveredMinWidth and discoveredMaxWidth
    /// converged on the exact same value) — .fill would crop that one axis to hide the mismatch
    /// instead of showing it, which reads as "doesn't fit" even though the crop is quietly doing
    /// its job. .fit shows the whole picture on every axis that isn't currently able to track,
    /// letterboxing/pillarboxing just that axis while any axis that's still actively resizing stays
    /// crop-free. Called both when a bound is first discovered and on every subsequent resize tick,
    /// so crossing back and forth over any threshold mid-drag switches modes live.
    private func updateContentScalingMode() {
        guard discoveredSourceMinSize != nil || discoveredSourceMaxSize != nil else { return }
        let size = panel.frame.size
        let floor = discoveredSourceMinSize ?? .zero
        let ceiling = discoveredSourceMaxSize ?? CGSize(width: CGFloat.infinity, height: CGFloat.infinity)
        let isBelowFloor = size.width < floor.width || size.height < floor.height
        let isAboveCeiling = size.width > ceiling.width || size.height > ceiling.height
        videoView.setContentScalingMode((isBelowFloor || isAboveCeiling) ? .fit : .fill)
    }
}

extension PiPPanelController: PiPVideoLayerViewDelegate {
    func videoView(_ view: PiPVideoLayerView, didHoverContentAt localPoint: CGPoint) {
        interactionForwarder?.beginCaptureIfNeeded(atLocalPoint: localPoint)
    }

    func videoView(_ view: PiPVideoLayerView, didReceiveKeyEvent event: NSEvent) {
        interactionForwarder?.forwardKeyEvent(event)
    }

    func videoView(_ view: PiPVideoLayerView, didResizeTo size: CGSize) {
        debugTrace("grow: didResizeTo panelSize=\(size)")
        // Corrects the aspirational maxSize set at panel-creation time down to whatever the
        // virtual display's real live bounds can actually deliver, once known — see
        // CaptureSession.deliverableMaxSize's doc comment for why this can be smaller than
        // expected. Only ever tightens (min), since a legitimately-behaving virtual display can't
        // exceed what was requested, and re-checking every tick means this takes effect live,
        // mid-drag, the moment the real bounds become known, same as the app-level floor/ceiling
        // corrections above.
        if let deliverableMax = interactionForwarder?.captureSession?.deliverableMaxSize {
            panel.maxSize = NSSize(
                width: min(panel.maxSize.width, deliverableMax.width),
                height: min(panel.maxSize.height, deliverableMax.height)
            )
        }
        updateContentScalingMode()
        interactionForwarder?.captureSession?.resizeSourceWindow(to: size)
    }

    func videoViewDidRequestCloseByDragging(_ view: PiPVideoLayerView) {
        delegate?.pipPanelControllerDidRequestClose(self)
    }
}
