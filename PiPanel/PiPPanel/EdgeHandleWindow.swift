import AppKit

@MainActor
protocol EdgeHandleWindowDelegate: AnyObject {
    /// The handle was clicked — PiPSessionManager treats this as "restore everything," fully
    /// un-stacking the hidden group back to each panel's own pre-stack position, the same as
    /// tapping a collapsed PiP pill on iOS expands it back to the floating player.
    func edgeHandleWindowDidClick(_ window: EdgeHandleWindow)
}

/// A small, dedicated, always-*fully*-on-screen window shown at the screen edge in place of an
/// entire edge-docked PiP group — modeled directly on iOS's own collapsed-PiP handle (a small pill
/// flush against the screen edge; a tap restores the full player), and deliberately a completely
/// separate NSWindow from the PiP panels themselves rather than a thin on-screen sliver left over
/// from one of them.
///
/// The previous design (sliding a PiP panel to a position mostly, but not entirely, off-screen,
/// leaving just a hoverable/visible sliver of that same window) went through several fix attempts
/// before being abandoned: masking the video layer, shrinking it, swapping in a plain indicator
/// subview — every one of those got the internal state provably correct (confirmed repeatedly via
/// /tmp/pipanel_trace.log) but the sliver still never actually rendered, and a live diagnostic (a
/// bright solid color, briefly visible while the dock animation was in flight) proved why: the
/// compositor keeps a window's on-screen sliver correctly refreshed *while* it's actively animating
/// into a mostly-off-screen position, but stops repainting it the instant the window goes static
/// there — even though the layer tree underneath it was already fully correct before the animation
/// ever started. A dedicated small window that's always *entirely* on-screen has no such state to
/// fall into: it's never partially off-screen, so there's nothing for the compositor to
/// under-refresh.
@MainActor
final class EdgeHandleWindow: NSObject {
    /// How far in from the screen's top/bottom edge the handle sits — purely cosmetic, keeps it
    /// from looking glued to the very corner.
    private static let verticalInset: CGFloat = 40

    weak var delegate: EdgeHandleWindowDelegate?
    private let panel: NSPanel
    private let handleView: EdgeHandleView

    override init() {
        let contentRect = NSRect(x: 0, y: 0, width: 10, height: 64)
        panel = NSPanel(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        handleView = EdgeHandleView(frame: contentRect)
        super.init()

        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = false
        panel.contentView = handleView
        handleView.delegate = self
    }

    /// Positions the handle flush against whichever edge `corner` faces, vertically biased toward
    /// that corner's own half of the screen. There's no panel geometry to line up with anymore (the
    /// PiP panels are simply hidden, not parked at some matching position), so this only needs to
    /// land in roughly the same corner the docked group was heading for, not exactly match anything.
    ///
    /// Size/color are read fresh from SettingsStore every time the handle is shown, rather than
    /// observed live — the handle is only ever briefly visible/hidden, so there's nothing to keep
    /// in sync while it's off-screen anyway.
    func show(on screen: NSScreen, corner: PanelCorner) {
        let width = CGFloat(SettingsStore.shared.edgeHandleWidth)
        let height = CGFloat(SettingsStore.shared.edgeHandleHeight)
        handleView.updateAppearance(width: width, height: height, colorHex: SettingsStore.shared.edgeHandleColorHex)

        let visible = screen.visibleFrame
        let x = corner.isLeading ? visible.minX : visible.maxX - width
        let y = corner.isTop ? visible.maxY - height - Self.verticalInset : visible.minY + Self.verticalInset
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
        }
    }
}

extension EdgeHandleWindow: EdgeHandleViewDelegate {
    func edgeHandleViewDidClick(_ view: EdgeHandleView) {
        delegate?.edgeHandleWindowDidClick(self)
    }
}

@MainActor
protocol EdgeHandleViewDelegate: AnyObject {
    func edgeHandleViewDidClick(_ view: EdgeHandleView)
}

/// The small pill-shaped content view for EdgeHandleWindow — a plain, static NSView with no video
/// content and nothing dynamically resized/masked/hidden, deliberately as simple as possible after
/// how many ways the previous video-layer-based sliver failed to actually render.
final class EdgeHandleView: NSView {
    weak var delegate: EdgeHandleViewDelegate?
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.55).cgColor
        layer?.cornerRadius = frameRect.width / 2
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Resizes this view to (width, height), re-derives cornerRadius from the new width so it
    /// stays a full pill/capsule shape regardless of the configured size, and applies the
    /// configured color — called by EdgeHandleWindow.show every time the handle is about to
    /// appear. Alpha stays fixed at 0.55; only hue/brightness is user-adjustable.
    func updateAppearance(width: CGFloat, height: CGFloat, colorHex: String) {
        frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
        layer?.cornerRadius = width / 2
        layer?.backgroundColor = (NSColor(hex: colorHex) ?? .white).withAlphaComponent(0.55).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        delegate?.edgeHandleViewDidClick(self)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
