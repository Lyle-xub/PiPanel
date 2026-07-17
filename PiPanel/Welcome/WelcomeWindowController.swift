import AppKit
import QuartzCore
import SwiftUI

/// A borderless window has no titlebar and therefore no traffic-light close/miniaturize/zoom
/// buttons — but borderless windows default canBecomeKey to false, same reason
/// PiPPanelController's InteractivePiPPanel overrides it, so this needs to too or the "开始使用"
/// button/paging drag gesture/Tab-based focus would never actually receive events.
private final class WelcomeWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// Owns the first-launch welcome window. PiPanel is LSUIElement (no Dock icon, no app menu), so
/// this is the one moment the app needs to actively grab focus and put a real, focusable window
/// in front of the user rather than waiting for them to click the status item — everything after
/// this is menu-bar-driven.
@MainActor
final class WelcomeWindowController: NSWindowController {
    static let shared = WelcomeWindowController()
    private var hasCompacted = false

    private let preferredCompactSize = NSSize(width: 1120, height: 700)

    private convenience init() {
        let window = WelcomeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 700),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // No titlebar at all (WelcomeView draws its own rounded, glass panel and close glyph),
        // so the window itself just needs to get out of the way — transparent, shadow-only chrome.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovableByWindowBackground = false
        window.center()
        self.init(window: window)
    }

    /// Removing the window-level alpha fade (there used to be one) wasn't enough on its own to
    /// fix "no content visible until you page away and back": the deeper issue is that
    /// `makeKeyAndOrderFront` can hand the *first* frame to WindowServer before NSHostingView has
    /// actually finished laying out/painting its SwiftUI content — AppKit then has no reason to
    /// believe anything changed since, so later SwiftUI-driven state updates never get flushed to
    /// the screen until something else (paging, which touches CALayers directly) forces a real
    /// recomposite. Forcing a synchronous layout pass *before* the window is ever shown, and a
    /// forced display pass right after, makes sure both the pre-animation baseline and every
    /// state change after it actually reach the screen.
    func show() {
        guard let window else { return }
        hasCompacted = false
        let screen = NSScreen.main ?? NSScreen.screens[0]
        window.setFrame(screen.frame, display: true)
        window.hasShadow = false
        window.isMovableByWindowBackground = false

        let contentView = WelcomeView(
            onRequestCompact: { [weak self] animated in
                self?.compactWindow(animated: animated)
            },
            onContinue: { [weak self] in
                self?.dismiss()
            }
        )
        let hostingView = NSHostingView(rootView: contentView)
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        window.alphaValue = 1
        NSApp.setActivationPolicy(.regular) // LSUIElement apps otherwise can't reliably become key/front
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.contentView?.needsDisplay = true
        window.displayIfNeeded()
    }

    private func compactWindow(animated: Bool) {
        guard let window, !hasCompacted else { return }
        hasCompacted = true

        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let visibleFrame = screen.visibleFrame
        let width = min(preferredCompactSize.width, visibleFrame.width - 48)
        let height = min(preferredCompactSize.height, visibleFrame.height - 48)
        let targetFrame = NSRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.midY - height / 2,
            width: width,
            height: height
        )

        guard animated else {
            window.setFrame(targetFrame, display: true)
            finishCompacting(window)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 1.45
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(targetFrame, display: true)
        } completionHandler: { [weak self, weak window] in
            Task { @MainActor in
                guard let self, let window else { return }
                self.finishCompacting(window)
            }
        }
    }

    private func finishCompacting(_ window: NSWindow) {
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.invalidateShadow()
    }

    private func dismiss() {
        guard let window else { return }
        SettingsStore.shared.hasCompletedWelcome = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            window.animator().alphaValue = 0
        }, completionHandler: {
            window.orderOut(nil)
            window.contentView = nil
            // Back to an accessory app once the one moment that needed a frontmost, focusable
            // window is over — otherwise PiPanel would keep an unwanted Dock icon/app menu forever.
            NSApp.setActivationPolicy(.accessory)
        })
    }
}
