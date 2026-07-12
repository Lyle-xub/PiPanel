import AppKit
import ApplicationServices
import CoreGraphics
import Combine

@MainActor
final class PermissionsManager: ObservableObject {
    static let shared = PermissionsManager()

    @Published private(set) var hasScreenRecordingAccess: Bool = false
    @Published private(set) var hasAccessibilityAccess: Bool = false

    var hasAllPermissions: Bool { hasScreenRecordingAccess && hasAccessibilityAccess }

    init() {
        refresh()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refresh),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc func refresh() {
        hasScreenRecordingAccess = CGPreflightScreenCaptureAccess()
        hasAccessibilityAccess = AXIsProcessTrusted()
    }

    func requestScreenRecordingAccess() {
        // Triggers the system TCC prompt if not yet decided; no-ops if already granted/denied.
        _ = CGRequestScreenCaptureAccess()
        refresh()
    }

    func requestAccessibilityAccess() {
        let options: [String: Bool] = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        refresh()
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
