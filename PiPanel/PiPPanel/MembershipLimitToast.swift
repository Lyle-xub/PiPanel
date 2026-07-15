import AppKit

/// A floating HUD-style toast for PiPSessionManager.membershipLimitMessage — shown at the top of
/// whichever screen currently has focus, fading in/out on its own. WindowPickerView already shows
/// this same message inline, but that's only visible if the menu bar dropdown happens to already
/// be open at the exact moment a session gets blocked — the free-tier limit can just as easily be
/// hit via WindowFlingDetector's shake gesture or GlobalHotkeyManager's "PiP all" shortcut, both
/// triggered while the user is looking at their desktop with the menu nowhere in sight, where the
/// inline banner would silently set a value nobody ever sees. This is the desktop-wide fallback
/// that's visible regardless of which of those triggered it.
@MainActor
final class MembershipLimitToast {
    static let shared = MembershipLimitToast()

    private var panel: NSPanel?
    private var containerView: NSVisualEffectView?
    private var textField: NSTextField?
    private var dismissWorkItem: DispatchWorkItem?

    private init() {}

    /// Duration deliberately shorter than PiPSessionManager's own ~4s membershipLimitMessage
    /// lifetime — this is a transient toast meant to be glanced at and dismissed, not read at
    /// leisure like the inline banner it supplements.
    private static let visibleDuration: TimeInterval = 2.6

    func show(_ message: String) {
        let panel = makePanelIfNeeded()
        textField?.stringValue = message
        panel.pipanel_resizeToFitContent()
        sizeAndPosition(panel)

        dismissWorkItem?.cancel()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        let workItem = DispatchWorkItem { [weak self] in self?.hide() }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleDuration, execute: workItem)
    }

    private func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        })
    }

    private func sizeAndPosition(_ panel: NSPanel) {
        // NSScreen.main tracks whichever screen currently has keyboard focus — appropriate here
        // specifically because this toast supplements gestures (shake-to-PiP, a global hotkey)
        // the user is actively performing on their currently-focused screen, unlike
        // PiPSessionManager.stackAllSessions' own screen choice, which anchors to wherever the
        // *panels* already are instead.
        guard let screen = NSScreen.main else { return }
        let size = panel.frame.size
        let x = screen.visibleFrame.midX - size.width / 2
        let y = screen.visibleFrame.maxY - size.height - 32
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    private func makePanelIfNeeded() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true // purely informational — never intercepts clicks
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let container = NSVisualEffectView()
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        container.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView(image: NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        icon.contentTintColor = .systemOrange
        icon.translatesAutoresizingMaskIntoConstraints = false

        let text = NSTextField(labelWithString: "")
        text.font = .systemFont(ofSize: 12, weight: .medium)
        text.textColor = .labelColor
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [icon, text])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        panel.contentView = container
        self.panel = panel
        self.containerView = container
        self.textField = text
        return panel
    }
}

private extension NSPanel {
    func pipanel_resizeToFitContent() {
        contentView?.layoutSubtreeIfNeeded()
        // Autolayout inside the stack determines the natural size — resize the panel/container to
        // match before sizeAndPosition(_:) reads panel.frame.size, since the panel itself was only
        // ever given a placeholder starting size at creation time.
        guard let fittingSize = contentView?.fittingSize, fittingSize.width > 0, fittingSize.height > 0 else { return }
        setContentSize(fittingSize)
    }
}
