import SwiftUI

@main
struct PiPanelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var permissionsManager = PermissionsManager.shared
    @StateObject private var sessionManager = PiPSessionManager.shared

    var body: some Scene {
        MenuBarExtra("PiPanel", systemImage: "pip") {
            MenuBarRootView()
                .environmentObject(permissionsManager)
                .environmentObject(sessionManager)
        }
        .menuBarExtraStyle(.window)
    }
}
