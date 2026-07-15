import AppKit

/// A floating circular target shown while a PiP panel is being dragged. The overlay window keeps
/// a fixed backing-store size for its entire lifetime; highlighting animates only GPU-composited
/// layers inside that window, avoiding WindowServer resize/reblur work mid-drag.
@MainActor
final class CloseDropZoneOverlay {
    static let shared = CloseDropZoneOverlay()

    private static let diameter: CGFloat = 120
    private static let highlightedScale: CGFloat = 1.15
    private static let iconSize: CGFloat = 44
    /// Transparent padding keeps the highlighted glass scale from clipping.
    private static let canvasDiameter: CGFloat = 184

    private var panel: NSPanel?
    private var canvasView: NSView?
    private var containerView: NSVisualEffectView?
    private var tintView: NSView?
    private var sheenLayer: CAGradientLayer?
    private var iconView: NSImageView?
    private var isVisible = false
    private var isHighlighted = false

    private init() {}

    /// Builds the visual-effect surface before the first drag. Creating an NSVisualEffectView and
    /// resolving its SF Symbol on mouseDown was a visible one-frame hitch on the first use.
    func prepare() {
        _ = makePanelIfNeeded()
    }

    /// The logical 120pt drop target. The actual transparent overlay window is larger so its
    /// compositor-only highlight and pulse animations have room to expand without clipping.
    static func frame(on screen: NSScreen) -> NSRect {
        let lowerHalfMidY = screen.frame.minY + screen.frame.height / 4
        return NSRect(
            x: screen.frame.midX - diameter / 2,
            y: lowerHalfMidY - diameter / 2,
            width: diameter,
            height: diameter
        )
    }

    private static func windowFrame(on screen: NSScreen) -> NSRect {
        let target = frame(on: screen)
        return NSRect(
            x: target.midX - canvasDiameter / 2,
            y: target.midY - canvasDiameter / 2,
            width: canvasDiameter,
            height: canvasDiameter
        )
    }

    /// Standard circle/rectangle intersection. Keeping the comparison squared avoids a square
    /// root on every mouseDragged event.
    static func intersects(_ panelFrame: CGRect, on screen: NSScreen) -> Bool {
        let target = frame(on: screen)
        let center = CGPoint(x: target.midX, y: target.midY)
        let closestX = max(panelFrame.minX, min(center.x, panelFrame.maxX))
        let closestY = max(panelFrame.minY, min(center.y, panelFrame.maxY))
        let dx = center.x - closestX
        let dy = center.y - closestY
        let radius = diameter / 2
        return dx * dx + dy * dy <= radius * radius
    }

    func show(on screen: NSScreen) {
        let panel = makePanelIfNeeded()
        resetVisualState()

        // One non-animated position update per drag. Highlighting never changes this frame.
        panel.setFrame(Self.windowFrame(on: screen), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        isVisible = true

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel, isVisible else { return }
        isVisible = false
        // No disappearance animation: when a drop closes its PiP, the panel is removed first and
        // this overlay leaves the screen in the same event turn. Directly ordering out also avoids
        // a stale fade completion racing with the next drag's show().
        panel.alphaValue = 0
        panel.orderOut(nil)
        resetVisualState()
    }

    /// Animates just two compositor properties: the glass circle's transform and the tint's
    /// opacity. No NSWindow frame change, visual-effect resize, mask rebuild, or view layout occurs
    /// while the mouse is moving.
    func setHighlighted(_ highlighted: Bool) {
        guard highlighted != isHighlighted, isVisible,
              let containerLayer = containerView?.layer,
              let tintLayer = tintView?.layer else { return }
        isHighlighted = highlighted

        let scale = highlighted ? Self.highlightedScale : 1
        let currentScale = containerLayer.presentation()?.value(forKeyPath: "transform.scale")
            ?? containerLayer.value(forKeyPath: "transform.scale")
        let currentTintOpacity = tintLayer.presentation()?.opacity ?? tintLayer.opacity

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        containerLayer.setValue(scale, forKeyPath: "transform.scale")
        tintLayer.opacity = highlighted ? 1 : 0
        CATransaction.commit()

        let scaleAnimation = CABasicAnimation(keyPath: "transform.scale")
        scaleAnimation.fromValue = currentScale
        scaleAnimation.toValue = scale
        scaleAnimation.duration = highlighted ? 0.17 : 0.14
        scaleAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        containerLayer.add(scaleAnimation, forKey: "dropZoneHighlightScale")

        let tintAnimation = CABasicAnimation(keyPath: "opacity")
        tintAnimation.fromValue = currentTintOpacity
        tintAnimation.toValue = highlighted ? 1 : 0
        tintAnimation.duration = 0.13
        tintAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        tintLayer.add(tintAnimation, forKey: "dropZoneHighlightTint")
    }

    private func resetVisualState() {
        isHighlighted = false
        guard let containerLayer = containerView?.layer, let tintLayer = tintView?.layer else { return }
        containerLayer.removeAllAnimations()
        tintLayer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        containerLayer.setValue(CGFloat(1), forKeyPath: "transform.scale")
        tintLayer.opacity = 0
        CATransaction.commit()
    }

    private func layoutStaticViews() {
        guard let canvasView, let containerView, let iconView else { return }
        let origin = (canvasView.bounds.width - Self.diameter) / 2
        containerView.frame = CGRect(x: origin, y: origin, width: Self.diameter, height: Self.diameter)
        containerView.layer?.cornerRadius = Self.diameter / 2
        tintView?.frame = containerView.bounds
        sheenLayer?.frame = containerView.bounds
        iconView.frame = CGRect(
            x: (Self.diameter - Self.iconSize) / 2,
            y: (Self.diameter - Self.iconSize) / 2,
            width: Self.iconSize,
            height: Self.iconSize
        )
    }

    private func makePanelIfNeeded() -> NSPanel {
        if let panel { return panel }

        let size = NSSize(width: Self.canvasDiameter, height: Self.canvasDiameter)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let canvas = NSView(frame: NSRect(origin: .zero, size: size))
        canvas.wantsLayer = true

        let container = NSVisualEffectView()
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.5).cgColor
        canvas.addSubview(container)

        let sheen = CAGradientLayer()
        sheen.colors = [
            NSColor.white.withAlphaComponent(0.4).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor,
        ]
        sheen.startPoint = CGPoint(x: 0.15, y: 0.95)
        sheen.endPoint = CGPoint(x: 0.7, y: 0.35)
        container.layer?.addSublayer(sheen)

        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.72).cgColor
        tint.layer?.opacity = 0
        container.addSubview(tint)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: Self.iconSize, weight: .regular)
        icon.contentTintColor = .white
        container.addSubview(icon)

        panel.contentView = canvas
        self.panel = panel
        canvasView = canvas
        containerView = container
        tintView = tint
        sheenLayer = sheen
        iconView = icon
        layoutStaticViews()
        return panel
    }
}
