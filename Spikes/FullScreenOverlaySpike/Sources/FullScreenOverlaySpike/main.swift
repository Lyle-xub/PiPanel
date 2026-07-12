import AppKit

// Usage: FullScreenOverlaySpike [levelName]
// levelName one of: screenSaver (default), statusBar, popUpMenu, mainMenu
let levelArg = CommandLine.arguments.dropFirst().first ?? "screenSaver"
let level: NSWindow.Level = {
    switch levelArg {
    case "statusBar": return .statusBar
    case "popUpMenu": return .popUpMenu
    case "mainMenu": return .mainMenu
    default: return .screenSaver
    }
}()

final class SpikeAppDelegate: NSObject, NSApplicationDelegate {
    var panel: NSPanel!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        guard let screen = NSScreen.main else { return }
        let panelSize = NSSize(width: 320, height: 140)
        let origin = NSPoint(
            x: screen.visibleFrame.maxX - panelSize.width - 24,
            y: screen.visibleFrame.maxY - panelSize.height - 24
        )
        let frame = NSRect(origin: origin, size: panelSize)

        panel = NSPanel(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = level
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let container = NSView(frame: NSRect(origin: .zero, size: panelSize))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.systemRed.cgColor
        container.layer?.cornerRadius = 12

        let label = NSTextField(labelWithString: "PiP SPIKE\nlevel=\(levelArg)\nPID=\(ProcessInfo.processInfo.processIdentifier)")
        label.font = .boldSystemFont(ofSize: 16)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 0, width: panelSize.width, height: panelSize.height)
        label.autoresizingMask = [.width, .height]
        container.addSubview(label)

        panel.contentView = container
        panel.orderFrontRegardless()

        print("Spike panel shown at \(frame), level=\(levelArg) (rawValue=\(level.rawValue)), PID=\(ProcessInfo.processInfo.processIdentifier)")
    }
}

let delegate = SpikeAppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()
