import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var isRestoringWindowsForTermination = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        debugTrace("applicationDidFinishLaunching START")
        #endif
        NSApp.setActivationPolicy(.accessory)
        PiPanelLogger.app.info("PiPanel launched")
        #if DEBUG
        debugTrace("applicationDidFinishLaunching: policy set, calling debugAutostartIfRequested")
        debugAutostartIfRequested()
        #endif

        Task { @MainActor in
            // Build the private-display pool once at launch. Unit tests embed/launch the app too;
            // never mutate the developer machine's real display topology for a test host.
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
                await VirtualDisplayPool.shared.warmUp(
                    longEdge: CGFloat(SettingsStore.shared.virtualDisplayLongEdge)
                )
            }

            // Creating the drop-zone's glass surface and resolving its symbol during the first
            // mouseDown causes a visible hitch. Prepare it after launch, before any drag begins.
            CloseDropZoneOverlay.shared.prepare()
            if !SettingsStore.shared.hasCompletedWelcome {
                WelcomeWindowController.shared.show()
            }
        }
    }

    #if DEBUG
    /// Dev-only hook: set PIPANEL_DEBUG_AUTOSTART=<comma-separated app name substrings> to
    /// auto-start a PiP session per match without going through the picker UI — used for
    /// milestone verification. No-ops unless the env var is set.
    private func debugAutostartIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["PIPANEL_DEBUG_AUTOSTART"], !raw.isEmpty else {
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
    #endif

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Source windows live on private virtual displays while PiP is active. App termination must
    /// therefore wait for the same verified restoration path used by closing a panel; merely
    /// letting the process disappear can remove the display before an asynchronous AX move lands,
    /// leaving the source app's window stranded or apparently missing after PiPanel exits.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isRestoringWindowsForTermination else { return .terminateLater }
        isRestoringWindowsForTermination = true
        Task { @MainActor in
            PiPanelLogger.app.info("Restoring all PiP source windows before termination")
            await PiPSessionManager.shared.stopAllAndWaitForWindowRestoration()
            PiPanelLogger.app.info("All PiP source windows restored; allowing termination")
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

}
