import AppKit
import CoreImage

/// Renders line-timed lyrics over a blurred album-artwork background, in the style of Apple
/// Music's own PiP lyrics panel — a plain sibling subview inside PiPVideoLayerView (see that
/// type's own doc comment for the established "another thing shown instead of displayLayer"
/// pattern this follows, same as loadingIndicator/titleLabel), shown/hidden by
/// PiPPanelController.setLyricsMode.
final class PiPLyricsView: NSView {
    private let backgroundImageView: NSImageView = {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleAxesIndependently
        imageView.wantsLayer = true
        let blur = CIFilter(name: "CIGaussianBlur")
        blur?.setValue(28, forKey: kCIInputRadiusKey)
        imageView.layer?.filters = blur.map { [$0] } ?? []
        return imageView
    }()

    /// Darkens the blurred artwork so white lyric text stays readable regardless of how bright
    /// the underlying album art is — matches the dark scrim Apple's own lyrics panel uses.
    private let scrim: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        return view
    }()

    /// Fixed to this view's own bounds (never moves) — purely there to host edgeFadeMask, so lines
    /// scrolling past the top/bottom fade out smoothly instead of being hard-clipped mid-line. Also
    /// does the actual clipping of lyricsContainer's overflow (masksToBounds), same job this view's
    /// own layer used to do before this wrapper existed — it has to be a separate fixed view rather
    /// than reusing this view's own layer for the mask, since a mask on lyricsContainer itself would
    /// move (and stretch) right along with it as recenter() translates it, instead of staying
    /// anchored to the panel's actual top/bottom edges.
    private let lyricsViewport: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        return view
    }()

    /// Fades lyricsViewport's content to transparent near the very top/bottom of the panel — clear
    /// at the edges, fully opaque through the middle — so a line scrolling in/out reads as
    /// dissolving rather than being sliced off by a hard clip, the same soft-edge treatment Apple
    /// Music's own lyrics panel uses. As a *mask*, only the alpha channel of these colors matters;
    /// they're plain black/clear rather than white/clear purely by CAGradientLayer-as-mask
    /// convention (opaque color = fully visible, clear = fully hidden either way).
    private let edgeFadeMask: CAGradientLayer = {
        let gradient = CAGradientLayer()
        gradient.colors = [
            NSColor.clear.cgColor,
            NSColor.black.cgColor,
            NSColor.black.cgColor,
            NSColor.clear.cgColor,
        ]
        gradient.locations = [0, 0.16, 0.84, 1]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        return gradient
    }()

    /// Holds the whole lyric stack — deliberately *not* an NSScrollView. "Keep the current line
    /// centered" was first built on NSScrollView (animating the clip view's bounds origin), but
    /// that makes correctness depend on NSClipView's bounds-origin convention interacting with
    /// this app's own non-flipped view coordinate system — reasoning about *that* correctly,
    /// without being able to see it rendered, is exactly the kind of thing that's easy to get
    /// subtly backwards. Directly translating this plain container's own frame origin instead
    /// reduces the whole mechanism to one directly-checkable equation (see recenter's own doc
    /// comment) with no scroll-view semantics involved at all — lyricsViewport's own
    /// masksToBounds clips whatever ends up outside its bounds, the same way a scroll view's clip
    /// view would have.
    private let lyricsContainer = NSView()

    private let stackView: NSStackView = {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        return stack
    }()

    private var lineLabels: [NSTextField] = []
    private var highlightedIndex: Int?

    /// Font size stays constant across every distance-from-current state on purpose — animating
    /// between font sizes was tried first and reverted: NSTextField's intrinsic size changes the
    /// instant `.font` is set (font isn't an animatable property), which snapped every other
    /// line's position immediately instead of flowing smoothly, fighting the recenter animation
    /// happening at the same time. The current-vs-distant distinction Apple Music's own lyrics
    /// panel conveys with size instead comes from a layer-level scale transform here (a genuine
    /// animatable property) plus alpha and a slight Gaussian blur on lines further from the
    /// active one — see LineStyle/style(forDistance:) below for the actual values.
    private static let lineFont = NSFont.systemFont(ofSize: 18, weight: .semibold)

    private struct LineStyle {
        let alpha: CGFloat
        let scale: CGFloat
        let blurRadius: CGFloat
    }

    /// How many lines on either side of previous/new highlighted index get restyled on every
    /// highlight change (see setHighlightedIndex) — bounds the per-update work to a small constant
    /// window instead of walking every line in the song, since anything further away than this is
    /// already at restingStyle and won't visibly change regardless.
    private static let neighborWindow = 3
    private static let restingStyle = LineStyle(alpha: 0.24, scale: 1.0, blurRadius: 1.4)

    /// Apple-Music-style falloff: the active line is enlarged and fully opaque; each step further
    /// away drops in opacity and gains a touch of blur, until settling at restingStyle from
    /// distance 3 onward. blurRadius intentionally isn't animated (see applyStyle's own doc
    /// comment for why) — only alpha and scale, both proven animatable elsewhere in this view,
    /// actually transition smoothly; the blur simply snaps to its new value each time, which reads
    /// fine in practice since it's a subtle effect happening alongside a much more noticeable
    /// alpha/scale animation.
    private static func style(forDistance distance: Int) -> LineStyle {
        switch abs(distance) {
        case 0: return LineStyle(alpha: 1.0, scale: 1.12, blurRadius: 0)
        case 1: return LineStyle(alpha: 0.62, scale: 1.0, blurRadius: 0)
        case 2: return LineStyle(alpha: 0.4, scale: 1.0, blurRadius: 0.6)
        default: return restingStyle
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true

        addSubview(backgroundImageView)
        addSubview(scrim)
        addSubview(lyricsViewport)
        lyricsViewport.layer?.mask = edgeFadeMask
        lyricsViewport.addSubview(lyricsContainer)
        lyricsContainer.addSubview(stackView)

        stackView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: lyricsContainer.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: lyricsContainer.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: lyricsContainer.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: lyricsContainer.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        backgroundImageView.frame = bounds
        scrim.frame = bounds

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lyricsViewport.frame = bounds
        edgeFadeMask.frame = lyricsViewport.bounds
        CATransaction.commit()

        // lyricsContainer is exactly as tall as its content needs and as wide as the viewport —
        // its own frame.origin.y is the one value recenter() moves to keep the active line
        // centered, so width/height just need to stay in sync with layout changes here, not the
        // vertical position (that's recenter's job, re-run below any time it changed).
        //
        // Width has to be committed *before* reading fittingSize, not after: the lyric labels
        // wrap, so their height depends on how wide they actually are, and fittingSize reflects
        // whatever width is currently active on stackView's constraints. Reading it first would
        // use a stale width left over from the previous layout pass (or 0 on the very first pass,
        // before this view has ever been sized), silently under-measuring wrapped multi-line text.
        let currentOriginY = lyricsContainer.frame.origin.y
        lyricsContainer.frame = NSRect(x: 0, y: currentOriginY, width: bounds.width, height: lyricsContainer.frame.height)
        lyricsContainer.layoutSubtreeIfNeeded()
        let fittingHeight = stackView.fittingSize.height
        lyricsContainer.frame = NSRect(x: 0, y: currentOriginY, width: bounds.width, height: fittingHeight)

        if let index = highlightedIndex, index < lineLabels.count {
            recenter(on: lineLabels[index], animated: false)
        }
    }

    func setArtwork(_ image: NSImage?) {
        backgroundImageView.image = image
    }

    func setLines(_ lines: [LyricLine]) {
        stackView.arrangedSubviews.forEach {
            stackView.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        lineLabels = lines.map { line in
            let label = NSTextField(wrappingLabelWithString: line.text)
            label.alignment = .center
            label.font = Self.lineFont
            label.textColor = .white
            label.alphaValue = Self.restingStyle.alpha
            label.isSelectable = false
            label.isBezeled = false
            label.drawsBackground = false
            label.wantsLayer = true
            return label
        }
        lineLabels.forEach { stackView.addArrangedSubview($0) }
        highlightedIndex = nil
        needsLayout = true
    }

    func setHighlightedIndex(_ index: Int?) {
        guard index != highlightedIndex else { return }
        let previous = highlightedIndex
        highlightedIndex = index

        var indicesToRestyle = Set<Int>()
        for anchor in [previous, index].compactMap({ $0 }) {
            for offset in -Self.neighborWindow...Self.neighborWindow where lineLabels.indices.contains(anchor + offset) {
                indicesToRestyle.insert(anchor + offset)
            }
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.5
            // A gentle overshoot rather than a plain ease — reads as a soft "settle into place"
            // rather than a mechanical stop, the same curve CloseDropZoneOverlay's own bounce
            // animation already uses elsewhere in this app.
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1)
            context.allowsImplicitAnimation = true

            for lineIndex in indicesToRestyle {
                let distance = index.map { $0 - lineIndex } ?? Int(Self.neighborWindow) + 1
                applyStyle(Self.style(forDistance: distance), to: lineLabels[lineIndex])
            }
            if let index, lineLabels.indices.contains(index) {
                recenter(on: lineLabels[index], animated: true)
            }
        }
    }

    /// alphaValue and the layer transform's scale are both genuinely animatable properties, so
    /// they pick up NSAnimationContext.allowsImplicitAnimation and transition smoothly. A CIFilter
    /// set through layer.filters is not one of those — CALayer's implicit-animation machinery
    /// doesn't reach into a filter's own KVC-compliant input keys the way it does for the layer's
    /// own properties like transform, so this would just silently fail to animate even inside the
    /// same context, the exact kind of "looks like it should animate but doesn't" trap this file's
    /// font-size attempt already ran into once before. Left as a plain snap rather than chasing a
    /// second, more fragile animation mechanism (CABasicAnimation keyed to
    /// "filters.gaussianBlur.inputRadius") for a subtle effect nobody would notice not easing in.
    private func applyStyle(_ style: LineStyle, to label: NSTextField) {
        label.animator().alphaValue = style.alpha
        label.layer?.transform = centeredScaleTransform(style.scale, boundsSize: label.bounds.size)
        if style.blurRadius > 0 {
            let blur = CIFilter(name: "CIGaussianBlur")
            blur?.setValue(style.blurRadius, forKey: kCIInputRadiusKey)
            label.layer?.filters = blur.map { [$0] } ?? []
        } else {
            label.layer?.filters = []
        }
    }

    /// A plain `CATransform3DMakeScale` scales around the layer's *anchorPoint* — which sounds
    /// like it should just be set to (0.5, 0.5) once to scale from the center, except AppKit
    /// silently resets a layer-backed NSView's anchorPoint back to its default, (0, 0) — the
    /// bottom-left corner — on every layout pass (a real, previously-confirmed-live bug: setting
    /// it once in setLines had no visible effect, the enlarged current line still drifted right).
    /// Rather than fight that reset, this computes a scale-plus-compensating-translation transform
    /// that scales correctly around the label's *center* regardless of whatever anchorPoint AppKit
    /// currently has it pinned to: expanding a size-(w, h) box by `scale` around its bottom-left
    /// corner grows it to (scale*w, scale*h) with the same bottom-left origin, so translating that
    /// result back by half the size increase on each axis — (1-scale)*w/2, (1-scale)*h/2 — lands
    /// it centered on the original box again. At scale == 1 this reduces to the identity, as
    /// expected for every non-active line.
    private func centeredScaleTransform(_ scale: CGFloat, boundsSize: CGSize) -> CATransform3D {
        guard scale != 1 else { return CATransform3DIdentity }
        let tx = (1 - scale) * boundsSize.width / 2
        let ty = (1 - scale) * boundsSize.height / 2
        let affine = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: tx, ty: ty)
        return CATransform3DMakeAffineTransform(affine)
    }

    /// Keeps `label` sitting exactly at this view's own vertical center by moving
    /// `lyricsContainer`'s frame origin — not by scrolling. The whole thing reduces to one
    /// equation: `label`'s final on-screen midY is `lyricsContainer.frame.origin.y +
    /// label's midY within lyricsContainer` (a plain view-hierarchy offset, true for *any* view
    /// positioned inside another). Setting that equal to `bounds.midY` and solving for the one
    /// unknown (the container's origin) is exactly what this does — no clipping/scroll-offset
    /// convention to get backwards, and it holds for the very first or very last line exactly the
    /// same as any line in the middle, since the container is simply allowed to extend past this
    /// view's own bounds on whichever side has less content (clipped by lyricsViewport's own
    /// masksToBounds).
    private func recenter(on label: NSTextField, animated: Bool) {
        let labelFrameInContainer = label.convert(label.bounds, to: lyricsContainer)
        let desiredOriginY = bounds.midY - labelFrameInContainer.midY
        let origin = NSPoint(x: 0, y: desiredOriginY)
        if animated {
            lyricsContainer.animator().setFrameOrigin(origin)
        } else {
            lyricsContainer.setFrameOrigin(origin)
        }
    }
}
