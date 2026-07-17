import AppKit
import ApplicationServices
import CoreGraphics
import Combine

@MainActor
final class PermissionsManager: ObservableObject {
    static let shared = PermissionsManager()

    @Published private(set) var hasScreenRecordingAccess: Bool = false
    @Published private(set) var hasAccessibilityAccess: Bool = false
    @Published private(set) var didRequestScreenRecordingAccess: Bool = false

    var hasAllPermissions: Bool { hasScreenRecordingAccess && hasAccessibilityAccess }

    // macOS only refreshes a process's own Screen Recording authorization at launch — granting it
    // in System Settings after the app is already running doesn't update `CGPreflightScreenCaptureAccess`
    // for this process, even though the grant is real and a relaunch will pick it up. Surface that
    // as a "needs relaunch" hint instead of leaving the permission looking stuck.
    var needsRelaunchForScreenRecording: Bool { didRequestScreenRecordingAccess && !hasScreenRecordingAccess }

    /// Polls refresh() while any permission is still outstanding, stopping itself the moment
    /// hasAllPermissions goes true — belt-and-suspenders against every event-driven trigger above
    /// (didBecomeActiveNotification, didActivateApplicationNotification, MenuBarRootView's
    /// .onAppear) turning out not to fire for some specific window/activation-policy combination.
    /// PiPanel's actual permission UI is a MenuBarExtra(.window) popover (MenuBarRootView) —
    /// clicking the status item to reopen it deliberately does *not* make PiPanel "the active
    /// application" (that's the whole point of a menu-bar utility: it shouldn't steal focus from
    /// whatever you were just doing), so it was never guaranteed that reopening it after granting
    /// Accessibility in System Settings would fire any app-activation notification at all, and
    /// SwiftUI's own .onAppear for a MenuBarExtra's content isn't documented to reliably re-fire on
    /// every reopen either (it may only fire once, on the view's first ever insertion into the
    /// hierarchy). A bounded poll sidesteps needing any of those to be reliable: it only runs while
    /// there's actually something outstanding to catch, and both underlying checks
    /// (CGPreflightScreenCaptureAccess/AXIsProcessTrusted) are cheap local calls, not IPC, so
    /// checking every second costs nothing worth avoiding for the bounded time a user is actually
    /// mid-onboarding.
    private var pollTimer: Timer?

    init() {
        refresh() // also starts pollTimer if anything's still outstanding — see its own doc comment
        // A fresh process launched right after a Screen Recording grant (relaunch() above, or
        // macOS's own "Quit & Reopen") can have this very first check race ahead of TCC actually
        // finishing its own bookkeeping for the new process — observed as hasScreenRecordingAccess
        // still reading false immediately at launch even though the grant is real and a *later*
        // check in the same process would've read true. An app that launches already-frontmost
        // (as this one does right after relaunch()) never fires didBecomeActiveNotification again
        // on its own to prompt a retry, so without this, that stale read would just stick for the
        // rest of the session. One extra check shortly after launch is cheap insurance against
        // that race without needing to poll indefinitely.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            self?.refresh()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refresh),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        // NSApplication.didBecomeActiveNotification above was found to not reliably fire for this
        // specific "switch to System Settings, flip Accessibility on, switch back" round-trip —
        // this app runs with .accessory activation policy (menu-bar-only, no Dock icon), and that
        // notification's own activation bookkeeping doesn't consistently treat refocusing an
        // accessory app's window as a real app-activation transition the way it does for a normal
        // Dock-based app. Symptom: Accessibility genuinely updates live for an already-running
        // process the moment it's toggled in System Settings — unlike Screen Recording, no
        // relaunch is needed at all — but hasAccessibilityAccess just never got re-read, so the
        // app kept showing "not granted" until *something else* (like pressing 授权 again, which
        // calls refresh() directly) happened to trigger a check.
        //
        // NSWorkspace.didActivateApplicationNotification is what PiPSessionManager's M3 logic
        // already relies on for the same underlying need (reliably detecting frontmost-app
        // changes despite this app's own accessory policy) — it's system-wide rather than
        // per-NSApplication, so it isn't subject to the same accessory-app quirk. Refreshing
        // whenever *this* app specifically is the one that just became frontmost catches exactly
        // the "came back from System Settings" moment.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeApplicationDidChange(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @objc private func activeApplicationDidChange(_ notification: Notification) {
        guard let activatedApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              activatedApp.processIdentifier == ProcessInfo.processInfo.processIdentifier else { return }
        refresh()
    }

    @objc func refresh() {
        hasScreenRecordingAccess = CGPreflightScreenCaptureAccess()
        hasAccessibilityAccess = AXIsProcessTrusted()
        if hasAllPermissions {
            pollTimer?.invalidate()
            pollTimer = nil
        } else {
            startPollingIfNeeded()
        }
    }

    private func startPollingIfNeeded() {
        guard pollTimer == nil, !hasAllPermissions else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func requestScreenRecordingAccess() {
        // Triggers the system TCC prompt if not yet decided; no-ops if already granted/denied.
        _ = CGRequestScreenCaptureAccess()
        didRequestScreenRecordingAccess = true
        refresh()
    }

    func requestAccessibilityAccess() {
        let options: [String: Bool] = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        refresh()
    }

    /// Relaunches the app in a fresh process so a Screen Recording grant made after launch (which
    /// this process can't see live) actually takes effect.
    ///
    /// NSWorkspace.openApplication(configuration: createsNewApplicationInstance: true) followed
    /// immediately by NSApp.terminate() was tried first and reverted: openApplication only
    /// *requests* a new launch and returns before that launch has actually completed, so
    /// terminating this process right away races it — this process could still be mid-teardown
    /// when the new instance starts up and runs its own TCC check. Observed effect: the relaunch
    /// visibly happened (a window blinked), but the new process still read the *old*, pre-grant
    /// Screen Recording state, exactly as if nothing had been relaunched at all. TCC appears to
    /// need this process to have genuinely, fully exited — not just be in the process of exiting
    /// — before a new instance gets its own clean authorization check. That's very likely also why
    /// even macOS's own "Quit & Reopen" prompt (shown by System Settings after toggling the
    /// permission) didn't help: it terminates and relaunches PiPanel too, and if that races the
    /// exact same way, there's nothing here to make it any more sequential than our own attempt
    /// was.
    ///
    /// The fix is to make the two steps genuinely sequential instead of overlapping: hand off to a
    /// tiny detached shell command that *polls until this process's PID has actually disappeared*
    /// before it runs `open -n` (force a brand new instance, never just re-activate an existing
    /// one) on the app bundle — only then does this process call terminate. The shell command
    /// survives our termination (it's a `Process`-launched, independent child reparented to
    /// launchd on exit, not tied to our lifetime the way a Task would be), so it's still around to
    /// perform the launch once we're actually, fully gone.
    func relaunch() {
        let bundlePath = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.05; done; /usr/bin/open -n \"\(bundlePath)\""

        let waitThenRelaunch = Process()
        waitThenRelaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        waitThenRelaunch.arguments = ["-c", script]
        try? waitThenRelaunch.run()

        NSApp.terminate(nil)
    }

    func openScreenRecordingSettings() {
        openSystemSettings(pane: "Privacy_ScreenCapture")
    }

    func openAccessibilitySettings() {
        openSystemSettings(pane: "Privacy_Accessibility")
    }

    private func openSystemSettings(pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
