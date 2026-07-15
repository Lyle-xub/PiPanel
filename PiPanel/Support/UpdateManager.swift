import AppKit
import Sparkle

/// Owns Sparkle for the entire application lifetime. Sparkle schedules background checks itself;
/// callers only need to keep this object alive and invoke checkForUpdates() for an explicit check.
@MainActor
final class UpdateManager {
    static let shared = UpdateManager()

    private let updaterController: SPUStandardUpdaterController

    private init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        // PiPanel normally runs as an accessory/menu-bar app. Bring Sparkle's standard update
        // window to the front so an explicit check never appears behind Settings or another app.
        NSApp.activate(ignoringOtherApps: true)
        updaterController.checkForUpdates(nil)
    }
}
