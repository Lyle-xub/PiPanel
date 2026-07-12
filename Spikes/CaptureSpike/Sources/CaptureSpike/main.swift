import ScreenCaptureKit
import AppKit

// Establish a WindowServer/CGS connection — plain CLI tools crash inside ScreenCaptureKit
// (CGS_REQUIRE_INIT assertion) without this, since that connection is normally set up by
// NSApplication startup in a real .app bundle.
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)

// Usage: CaptureSpike <window-title-substring> [window|display]
let needle = CommandLine.arguments.dropFirst().first ?? "文本编辑"
let mode = CommandLine.arguments.dropFirst(2).first ?? "window"

final class Runner: NSObject, SCStreamOutput, SCStreamDelegate {
    var count = 0
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        count += 1
        let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
        let statusRaw = attachmentsArray?.first?[.status] as? Int
        let imgBuf = CMSampleBufferGetImageBuffer(sampleBuffer)
        let size = imgBuf.map { "\(CVPixelBufferGetWidth($0))x\(CVPixelBufferGetHeight($0))" } ?? "nil"
        print("[\(Date())] callback #\(count) statusRaw=\(String(describing: statusRaw)) imageBuffer=\(size)")
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[\(Date())] STREAM STOPPED WITH ERROR: \(error)")
    }
}

Task {
    do {
        print("Enumerating windows...")
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        print("DISPLAYS: \(content.displays.map { $0.displayID })")
        guard let window = content.windows.first(where: { ($0.title ?? "").contains(needle) || ($0.owningApplication?.applicationName ?? "").contains(needle) }) else {
            print("No window found matching '\(needle)'. Available:")
            for w in content.windows.prefix(20) {
                print("  - \(w.owningApplication?.applicationName ?? "?") / \(w.title ?? "?") frame=\(w.frame)")
            }
            exit(1)
        }
        print("Found window: \(window.owningApplication?.applicationName ?? "?") / \(window.title ?? "?") frame=\(window.frame) windowID=\(window.windowID)")

        let filter: SCContentFilter
        if mode == "display" {
            guard let display = content.displays.first else { print("no display"); exit(1) }
            filter = SCContentFilter(display: display, excludingWindows: [])
            print("Using DISPLAY filter: \(display.width)x\(display.height)")
        } else if mode == "including" {
            guard let display = content.displays.first else { print("no display"); exit(1) }
            filter = SCContentFilter(display: display, including: [window])
            print("Using DISPLAY+including[window] filter")
        } else {
            filter = SCContentFilter(desktopIndependentWindow: window)
            print("Using WINDOW filter (desktopIndependentWindow)")
        }

        let config = SCStreamConfiguration()
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        config.queueDepth = 5
        if mode == "display" {
            config.width = 1280
            config.height = 800
        } else if mode == "including" {
            config.width = max(Int(window.frame.width), 2)
            config.height = max(Int(window.frame.height), 2)
        } else {
            config.width = max(Int(window.frame.width), 2)
            config.height = max(Int(window.frame.height), 2)
        }
        print("Config: \(config.width)x\(config.height)")

        let runner = Runner()
        let stream = SCStream(filter: filter, configuration: config, delegate: runner)
        try stream.addStreamOutput(runner, type: .screen, sampleHandlerQueue: DispatchQueue(label: "spike.sample"))
        try await stream.startCapture()
        print("Capture started, observing for 20 seconds...")

        try await Task.sleep(nanoseconds: 20_000_000_000)
        print("Total callbacks received: \(runner.count)")
        try? await stream.stopCapture()
        exit(0)
    } catch {
        print("ERROR: \(error)")
        exit(1)
    }
}

RunLoop.main.run()
