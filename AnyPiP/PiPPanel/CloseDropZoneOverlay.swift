import AppKit

/// A floating circular target shown in the screen's lower half while Option-dragging a PiP
/// panel — dropping the panel's center inside it closes that panel. This mirrors the classic
/// "drag an icon onto the Dock's trash to delete it" gesture: a specific, discoverable, visually
/// obvious target, rather than a silent "anywhere in the lower half of the screen" rule with no
/// indicator on the screen itself.
@MainActor
final class CloseDropZoneOverlay {
    static let shared = CloseDropZoneOverlay()

    private static let diameter: CGFloat = 120
    private static let highlightedDiameter: CGFloat = diameter * 1.15
    private static let iconSize: CGFloat = 44

    private var panel: NSPanel?
    private var containerView: NSView?
    private var iconView: NSImageView?
    private var isHighlighted = false

    private init() {}

    /// Anchors the target in the vertical center of `screen`'s lower half, horizontally centered
    /// — a fixed, predictable spot rather than following the dragged panel around.
    static func frame(on screen: NSScreen) -> NSRect {
        let lowerHalfMidY = screen.frame.minY + screen.frame.height / 4
        return NSRect(
            x: screen.frame.midX - diameter / 2,
            y: lowerHalfMidY - diameter / 2,
            width: diameter,
            height: diameter
        )
    }

    /// Whether `panelFrame`'s center has been dragged inside the circular target on `screen` —
    /// a radius check rather than a rectangular intersection, since the target reads as a circle.
    static func containsCenter(of panelFrame: CGRect, on screen: NSScreen) -> Bool {
        let target = frame(on: screen)
        let dx = panelFrame.midX - target.midX
        let dy = panelFrame.midY - target.midY
        return (dx * dx + dy * dy).squareRoot() <= diameter / 2
    }

    func show(on screen: NSScreen) {
        let panel = makePanelIfNeeded()
        // A previous drag may have left the target enlarged/red (setHighlighted) — reset to the
        // idle circle explicitly rather than relying on state left over from last time.
        panel.setFrame(Self.frame(on: screen), display: true)
        applyLayout(diameter: Self.diameter)
        containerView?.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        isHighlighted = false

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        })
    }

    /// Bounces the target slightly larger and tints it red once the dragged panel's center is
    /// inside it — the same "you're about to drop it here" feedback as the Dock's trash icon.
    ///
    /// This resizes the actual window/container/cornerRadius (via applyLayout) rather than
    /// applying a CALayer transform scale to a fixed-size circle: a transform scale was tried
    /// first and made the circle render as a square once scaled — resizing the real frame at a
    /// consistently recomputed cornerRadius = diameter/2 sidesteps that entirely, since every
    /// state (idle and highlighted) is its own genuinely round layer at its own size, never a
    /// transformed copy of a different-sized one.
    func setHighlighted(_ highlighted: Bool) {
        guard highlighted != isHighlighted, let panel else { return }
        isHighlighted = highlighted
        let diameter = highlighted ? Self.highlightedDiameter : Self.diameter
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().setFrame(
                NSRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter),
                display: true
            )
        }
        applyLayout(diameter: diameter)
        containerView?.layer?.backgroundColor = (highlighted ? NSColor.systemRed : NSColor.black.withAlphaComponent(0.55)).cgColor
    }

    /// Resizes containerView/iconView to match a `diameter`x`diameter` panel, recentering the
    /// icon and recomputing cornerRadius so the container always renders as a perfect circle at
    /// its current size (see setHighlighted's note on why this replaced a transform-based scale).
    private func applyLayout(diameter: CGFloat) {
        guard let containerView, let iconView else { return }
        containerView.frame = NSRect(origin: .zero, size: NSSize(width: diameter, height: diameter))
        containerView.layer?.cornerRadius = diameter / 2
        iconView.frame = NSRect(
            x: (diameter - Self.iconSize) / 2,
            y: (diameter - Self.iconSize) / 2,
            width: Self.iconSize,
            height: Self.iconSize
        )
    }

    private func makePanelIfNeeded() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: Self.diameter, height: Self.diameter)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true // purely a visual target — never intercepts the drag itself
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let container = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        container.layer?.masksToBounds = true

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: Self.iconSize, weight: .regular)
        icon.contentTintColor = .white
        container.addSubview(icon)

        panel.contentView = container
        self.panel = panel
        self.containerView = container
        self.iconView = icon
        applyLayout(diameter: Self.diameter)
        return panel
    }
}
