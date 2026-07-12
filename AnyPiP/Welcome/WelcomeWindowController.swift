import AppKit
import SwiftUI

/// A borderless window has no titlebar and therefore no traffic-light close/miniaturize/zoom
/// buttons — but borderless windows default canBecomeKey to false, same reason
/// PiPPanelController's InteractivePiPPanel overrides it, so this needs to too or the "开始使用"
/// button/paging drag gesture/Tab-based focus would never actually receive events.
private final class WelcomeWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// Owns the first-launch welcome window. AnyPiP is LSUIElement (no Dock icon, no app menu), so
/// this is the one moment the app needs to actively grab focus and put a real, focusable window
/// in front of the user rather than waiting for them to click the status item — everything after
/// this is menu-bar-driven.
@MainActor
final class WelcomeWindowController: NSWindowController {
    static let shared = WelcomeWindowController()

    private convenience init() {
        let window = WelcomeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 470),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // No titlebar at all (WelcomeView draws its own rounded, glass panel and close glyph),
        // so the window itself just needs to get out of the way — transparent, shadow-only chrome.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
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
        let contentView = WelcomeView { [weak self] in
            self?.dismiss()
        }
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
            // window is over — otherwise AnyPiP would keep an unwanted Dock icon/app menu forever.
            NSApp.setActivationPolicy(.accessory)
        })
    }
}
