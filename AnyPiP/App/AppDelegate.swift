import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        debugTrace("applicationDidFinishLaunching START")
        NSApp.setActivationPolicy(.accessory)
        AnyPiPLogger.app.info("AnyPiP launched")
        debugTrace("applicationDidFinishLaunching: policy set, calling debugAutostartIfRequested")
        debugAutostartIfRequested()
    }

    /// Dev-only hook: set ANYPIP_DEBUG_AUTOSTART=<comma-separated app name substrings> to
    /// auto-start a PiP session per match without going through the picker UI — used for
    /// milestone verification, including starting multiple sessions at once (M4). No-ops unless
    /// the env var is set.
    private func debugAutostartIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["ANYPIP_DEBUG_AUTOSTART"], !raw.isEmpty else {
            return
        }
        let needles = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            do {
                let windows = try await WindowEnumerator.listPiPCandidateWindows()
                for needle in needles {
                    guard let match = windows.first(where: { $0.ownerAppName.localizedCaseInsensitiveContains(needle) }) else {
                        debugTrace("DEBUG_AUTOSTART: no window matching '\(needle)' found")
                        continue
                    }
                    await MainActor.run {
                        PiPSessionManager.shared.startSession(for: match)
                    }
                }
            } catch {
                debugTrace("DEBUG_AUTOSTART failed: \(error)")
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
