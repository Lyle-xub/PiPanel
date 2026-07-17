import AppKit

/// Lets the close action land on the first click even when the non-activating PiP panel is not
/// currently key.
private final class FirstMouseButton: NSButton {
    var onHoverChanged: ((Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }
}

@MainActor
protocol PiPCloseCornerControlDelegate: AnyObject {
    func closeCornerControlWasClicked(_ control: PiPCloseCornerControl)
}

/// A single circular close button in the panel's top-left corner. The helper view is slightly
/// larger than the visible button to provide an 8-point margin, but its transparent area passes
/// mouse events through to the picture underneath.
final class PiPCloseCornerControl: NSView {
    weak var delegate: PiPCloseCornerControlDelegate?
    private var isCloseButtonHovered = false

    private let closeButton: FirstMouseButton = {
        let button = FirstMouseButton(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭") ?? NSImage(),
            target: nil,
            action: nil
        )
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .white
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.58).cgColor
        button.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        button.layer?.borderWidth = 0.5
        button.layer?.shadowColor = NSColor.black.cgColor
        button.layer?.shadowOpacity = 0.28
        button.layer?.shadowRadius = 3
        button.layer?.shadowOffset = CGSize(width: 0, height: -1)
        return button
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        closeButton.target = self
        closeButton.action = #selector(closeButtonPressed)
        closeButton.onHoverChanged = { [weak self] hovered in
            self?.setCloseButtonHovered(hovered)
        }
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()

        let buttonSize: CGFloat = 24
        let margin: CGFloat = 8
        closeButton.frame = CGRect(
            x: margin,
            y: bounds.height - margin - buttonSize,
            width: buttonSize,
            height: buttonSize
        )
        closeButton.layer?.cornerRadius = buttonSize / 2
        closeButton.layer?.shadowPath = CGPath(ellipseIn: closeButton.bounds, transform: nil)
    }

    /// `point` arrives in the superview's coordinate system. Convert it before testing the circle
    /// and return the button directly so the wrapper's transparent margin never swallows clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0, let superview else { return nil }
        let localPoint = convert(point, from: superview)
        let buttonPoint = closeButton.convert(localPoint, from: self)
        let center = CGPoint(x: closeButton.bounds.midX, y: closeButton.bounds.midY)
        let distance = hypot(buttonPoint.x - center.x, buttonPoint.y - center.y)
        guard distance <= closeButton.bounds.width / 2 else { return nil }
        return closeButton
    }

    @objc private func closeButtonPressed() {
        delegate?.closeCornerControlWasClicked(self)
    }

    private func setCloseButtonHovered(_ hovered: Bool) {
        guard hovered != isCloseButtonHovered, let buttonLayer = closeButton.layer else { return }
        isCloseButtonHovered = hovered

        let targetBackground = hovered
            ? NSColor.systemRed.withAlphaComponent(0.88).cgColor
            : NSColor.black.withAlphaComponent(0.58).cgColor
        let targetBorder = hovered
            ? NSColor.white.withAlphaComponent(0.48).cgColor
            : NSColor.white.withAlphaComponent(0.22).cgColor
        let targetShadowOpacity: Float = hovered ? 0.45 : 0.28
        let targetShadowRadius: CGFloat = hovered ? 5 : 3
        let targetScale: CGFloat = hovered ? 1.07 : 1

        let presentation = buttonLayer.presentation()
        let currentBackground = presentation?.backgroundColor ?? buttonLayer.backgroundColor
        let currentBorder = presentation?.borderColor ?? buttonLayer.borderColor
        let currentShadowOpacity = presentation?.shadowOpacity ?? buttonLayer.shadowOpacity
        let currentShadowRadius = presentation?.shadowRadius ?? buttonLayer.shadowRadius
        let currentScale = presentation?.transform.m11 ?? buttonLayer.transform.m11

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        buttonLayer.backgroundColor = targetBackground
        buttonLayer.borderColor = targetBorder
        buttonLayer.shadowOpacity = targetShadowOpacity
        buttonLayer.shadowRadius = targetShadowRadius
        buttonLayer.transform = CATransform3DMakeScale(targetScale, targetScale, 1)
        CATransaction.commit()

        addHoverAnimation(
            to: buttonLayer,
            keyPath: "backgroundColor",
            from: currentBackground,
            to: targetBackground
        )
        addHoverAnimation(
            to: buttonLayer,
            keyPath: "borderColor",
            from: currentBorder,
            to: targetBorder
        )
        addHoverAnimation(
            to: buttonLayer,
            keyPath: "shadowOpacity",
            from: currentShadowOpacity,
            to: targetShadowOpacity
        )
        addHoverAnimation(
            to: buttonLayer,
            keyPath: "shadowRadius",
            from: currentShadowRadius,
            to: targetShadowRadius
        )
        addHoverAnimation(
            to: buttonLayer,
            keyPath: "transform.scale",
            from: currentScale,
            to: targetScale
        )
    }

    private func addHoverAnimation(
        to targetLayer: CALayer,
        keyPath: String,
        from startValue: Any?,
        to endValue: Any
    ) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = startValue
        animation.toValue = endValue
        animation.duration = 0.16
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        targetLayer.add(animation, forKey: "closeButtonHover.\(keyPath)")
    }
}
