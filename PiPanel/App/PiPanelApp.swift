import SwiftUI

@main
struct PiPanelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var permissionsManager = PermissionsManager.shared
    @StateObject private var sessionManager = PiPSessionManager.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarRootView()
                .environmentObject(permissionsManager)
                .environmentObject(sessionManager)
        } label: {
            Image(nsImage: MenuBarPiPanelIcon.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 20, height: 18)
                .accessibilityLabel("PiPanel")
        }
        .menuBarExtraStyle(.window)
    }
}

/// MenuBarExtra is most reliable with a template NSImage rather than a composited SwiftUI shape
/// hierarchy. NSCustomImageRep keeps this programmatic mark sharp at every menu-bar scale, while
/// `isTemplate` lets macOS supply the correct active/inactive and light/dark tint.
private enum MenuBarPiPanelIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let backWindow = NSBezierPath(
                roundedRect: NSRect(x: 1.5, y: 5.5, width: 14.5, height: 10.5),
                xRadius: 3.2,
                yRadius: 3.2
            )
            backWindow.lineWidth = 1.65
            backWindow.stroke()

            NSBezierPath(ovalIn: NSRect(x: 3.0, y: 13.0, width: 2.8, height: 2.8)).fill()

            let frontWindow = NSBezierPath(
                roundedRect: NSRect(x: 8.7, y: 1.2, width: 9.5, height: 7.2),
                xRadius: 2.7,
                yRadius: 2.7
            )
            frontWindow.lineWidth = 1.8
            frontWindow.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
