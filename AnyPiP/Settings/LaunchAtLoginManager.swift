import AppKit
import ServiceManagement

/// Deliberately not a SettingsStore property, even though it reads like a toggle. Every other
/// setting there is a pure app-local preference whose only source of truth is UserDefaults —
/// launch-at-login's real source of truth is SMAppService.mainApp.status, an OS-level fact the
/// user can change out from under the app (System Settings → General → Login Items) and whose
/// write path genuinely throws. Caching a local bool for it would drift from reality exactly the
/// way the rest of this app's settings never do.
@MainActor
final class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()

    @Published private(set) var isEnabled = false
    @Published private(set) var lastError: String?

    private init() {
        refresh()
        // Catches the user adding/removing the login item externally while AnyPiP wasn't
        // frontmost — same rationale as PermissionsManager's use of this notification for
        // TCC permissions granted while the app was in the background.
        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh),
            name: NSApplication.didBecomeActiveNotification, object: nil
        )
    }

    @objc func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        lastError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = error.localizedDescription
        }
        // Reconcile from the real status afterward rather than trusting the requested value —
        // register() can succeed into .requiresApproval rather than .enabled (macOS sometimes
        // needs the user to flip it on once in System Settings), and a failed call must not leave
        // the toggle showing a state that didn't actually take effect.
        refresh()
    }
}
