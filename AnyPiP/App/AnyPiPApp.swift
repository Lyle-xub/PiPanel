import SwiftUI

@main
struct AnyPiPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var permissionsManager = PermissionsManager.shared
    @StateObject private var sessionManager = PiPSessionManager.shared

    var body: some Scene {
        MenuBarExtra("AnyPiP", systemImage: "pip") {
            MenuBarRootView()
                .environmentObject(permissionsManager)
                .environmentObject(sessionManager)
        }
        .menuBarExtraStyle(.window)
    }
}
