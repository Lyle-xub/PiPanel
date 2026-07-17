import AppKit

/// A plain NSButton subclass so playback-control clicks land on the very first mouseDown even if
/// this panel isn't currently key — matching PiPVideoLayerView's own acceptsFirstMouse override
/// and its stated goal ("click-to-forward should work without ever visually disturbing the panel
/// or stealing focus"); NSButton's own default (false) would otherwise swallow the first click
/// just to bring the panel forward, same as any background-window control.
private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
protocol PiPMusicControlsBarDelegate: AnyObject {
    func musicControlsBar(_ bar: PiPMusicControlsBar, didSend command: PiPMusicControlsBar.Command)
}

/// A small floating capsule of playback-transport buttons, shown by PiPVideoLayerView only while
/// the real cursor is hovering the bottom strip of a supported playback panel (see that type's
/// controlsBarHoverZone) — the same "reveal controls near an edge on hover" pattern iOS/macOS's
/// own PiP window uses for its playback controls. Sending a command doesn't target this specific
/// session's source app in particular — MediaRemote's "send" always controls whichever app is
/// currently the system's one active "Now Playing" client (see NowPlayingMonitor.Command's own
/// doc comment). Music panels are matched by source app; video panels are stricter and are shown
/// only when the source app and, for browsers, the window title match that active media session.
final class PiPMusicControlsBar: NSView {
    enum Mode {
        case music
        case video
    }

    enum Command {
        case previous
        case togglePlayPause
        case next
    }

    weak var delegate: PiPMusicControlsBarDelegate?

    /// Video windows reuse the exact same capsule and play-state rendering, but collapse the
    /// transport down to its one meaningful action. Keeping this as a mode avoids maintaining two
    /// subtly different hover animations and first-mouse implementations.
    var mode: Mode = .music {
        didSet { applyMode() }
    }

    /// Matches the black-capsule-badge look already used elsewhere on this panel
    /// (titleLabel and similar badges) rather than introducing a new blurred-glass style just for
    /// this control.
    private let background: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        return view
    }()

    private let stackView: NSStackView = {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .equalSpacing
        stack.spacing = 18
        return stack
    }()

    private let previousButton = FirstMouseButton()
    private let playPauseButton = FirstMouseButton()
    private let nextButton = FirstMouseButton()

    /// Reflects whichever app is actually reporting as playing right now (PiPPanelController feeds
    /// this from NowPlayingMonitor, filtered to this session's own source app) — kept separate from
    /// visibility (isVisible/setVisible) so the icon stays correct even while the bar itself is
    /// faded out, ready the instant it's revealed again.
    private(set) var isPlaying = false {
        didSet {
            guard isPlaying != oldValue else { return }
            playPauseButton.image = NSImage(
                systemSymbolName: isPlaying ? "pause.fill" : "play.fill",
                accessibilityDescription: isPlaying ? "暂停" : "播放"
            )
        }
    }

    private var isVisible = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        alphaValue = 0
        isHidden = true

        addSubview(background)

        // tag doubles as the Command's own case index below — simpler than a separate lookup
        // table or three near-identical @objc action selectors for otherwise identical buttons.
        for (button, symbolName, description, tag) in [
            (previousButton, "backward.fill", "上一首", 0),
            (playPauseButton, "play.fill", "播放", 1),
            (nextButton, "forward.fill", "下一首", 2),
        ] {
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.contentTintColor = .white
            button.tag = tag
            button.target = self
            button.action = #selector(buttonPressed(_:))
            stackView.addArrangedSubview(button)
        }

        addSubview(stackView)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyMode()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        background.frame = bounds
        background.layer?.cornerRadius = bounds.height / 2
    }

    @objc private func buttonPressed(_ sender: FirstMouseButton) {
        let command: Command
        switch sender.tag {
        case 0: command = .previous
        case 1: command = .togglePlayPause
        default: command = .next
        }
        delegate?.musicControlsBar(self, didSend: command)
    }

    private func applyMode() {
        let videoOnly = mode == .video
        previousButton.isHidden = videoOnly
        nextButton.isHidden = videoOnly
        stackView.spacing = videoOnly ? 0 : 18
        playPauseButton.toolTip = videoOnly ? "播放或暂停视频" : "播放或暂停"
    }

    func setPlaying(_ playing: Bool) {
        isPlaying = playing
    }

    /// Fades the whole bar in/out — the same "isHidden flips only at the edge of the animation, not
    /// the start" pattern PiPVideoLayerView.hideLoadingIndicator already uses, so a fade-in from a
    /// hidden state is actually visible (a hidden view never draws, animated or not) and a fade-out
    /// doesn't leave an invisible-but-still-hit-testable view sitting on top of the panel's other
    /// gestures once it's done.
    func setVisible(_ visible: Bool, animated: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible { isHidden = false }
        guard animated else {
            alphaValue = visible ? 1 : 0
            if !visible { isHidden = true }
            return
        }
        NSAnimationContext.runAnimationGroup({ [weak self] _ in
            self?.animator().alphaValue = visible ? 1 : 0
        }, completionHandler: { [weak self] in
            if !visible { self?.isHidden = true }
        })
    }
}
