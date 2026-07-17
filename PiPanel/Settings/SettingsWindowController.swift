import AppKit
import SwiftUI

/// Owns the standalone Settings window. PiPanel is LSUIElement (no Dock icon, no app menu) driven
/// entirely from the menu bar — like WelcomeWindowController, this is a moment the app needs to
/// temporarily become a regular, focusable app so a real window can come to the front.
///
/// Unlike Welcome's borderless window (dismissed via its own in-SwiftUI button, never through
/// AppKit's real close path), this window is titled/closable — the user closes it with the native
/// red traffic-light button, `windowShouldClose`/`close()`/Cmd-W. `isReleasedWhenClosed` must be
/// `false`: AppKit's default is to deallocate the window on close, which would leave this `.shared`
/// singleton controller holding a dangling window on the next `show()`. Nothing breaks on the
/// *first* open/close — only a second `show()` after a real close would misbehave — so this is
/// easy to miss without deliberately testing repeated open/close cycles.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 580),
            // .fullSizeContentView lets SettingsRootView's NavigationSplitView draw all the way up
            // under the traffic lights instead of stopping below a reserved titlebar strip —
            // combined with titlebarAppearsTransparent/titleVisibility below, this is the same
            // recipe System Settings.app itself uses for its own sidebar-to-the-top look. .titled
            // is kept (not dropped) specifically *because* it's what supplies the native traffic
            // lights and window-drag area at all — only the title *text* is hidden, not the bar.
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Title text is still set (just not shown) — VoiceOver and Mission Control/Cmd-` still
        // read a window's .title even when titleVisibility hides it from sighted users.
        window.title = "PiPanel 设置"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 680, height: 580)
        window.backgroundColor = .windowBackgroundColor
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        window.delegate = self
    }

    /// Rebuilds the hosting view fresh on every call rather than reusing one across close/reopen
    /// cycles — this matters concretely for LaunchAtLoginManager: GeneralSettingsView's owning
    /// hierarchy re-appearing is what triggers LaunchAtLoginManager.refresh() to re-check
    /// SMAppService's real status, so a stale, kept-alive view would only ever check once and
    /// never notice the user changing the login item externally between visits.
    func show() {
        guard let window else { return }
        let contentView = SettingsRootView()
            .environmentObject(PermissionsManager.shared)
        let hostingView = NSHostingView(rootView: contentView)
        window.contentView = hostingView
        // Same first-frame-not-painted race WelcomeWindowController's doc comment describes —
        // forcing a synchronous layout pass before the window is shown avoids a blank first frame.
        hostingView.layoutSubtreeIfNeeded()
        NSApp.setActivationPolicy(.regular) // LSUIElement apps otherwise can't reliably become key/front
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.contentView?.needsDisplay = true
        window.displayIfNeeded()
    }

    /// Covers every dismissal path uniformly — native traffic-light close, Cmd-W, programmatic
    /// close() — unlike Welcome, which needed a custom SwiftUI dismiss callback specifically
    /// because a borderless window has no native close affordance at all.
    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        // Back to an accessory app once the one moment that needed a frontmost, focusable window
        // is over — otherwise PiPanel would keep an unwanted Dock icon/app menu forever.
        NSApp.setActivationPolicy(.accessory)
    }
}
