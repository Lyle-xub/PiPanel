import CGVirtualDisplayC
import ScreenCaptureKit
import AppKit
import CoreImage

setvbuf(stdout, nil, _IONBF, 0)
_ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)

func snapshotPNG(_ pixelBuffer: CVPixelBuffer, to path: String) {
    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    let context = CIContext()
    guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: path))
}

final class Runner: NSObject, SCStreamOutput, SCStreamDelegate {
    var count = 0
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachmentsArray.first?[.status] as? Int,
              statusRaw == 0, // .complete
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        count += 1
        if count % 15 == 0 {
            print("[\(Date())] frame #\(count) \(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer))")
            snapshotPNG(pixelBuffer, to: "/tmp/vdisplay_frame.png")
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("STREAM STOPPED: \(error)")
    }
}

// -1. Replicate AnyPiP's PiPPanelController: an elevated-level NSPanel already on screen
//     BEFORE the virtual display is created, to test whether that's what breaks discovery.
let testPanel = NSPanel(
    contentRect: NSRect(x: 100, y: 100, width: 200, height: 150),
    styleMask: [.nonactivatingPanel, .borderless, .resizable],
    backing: .buffered,
    defer: false
)
testPanel.isFloatingPanel = true
testPanel.hidesOnDeactivate = false
testPanel.isOpaque = false
testPanel.backgroundColor = .clear
testPanel.hasShadow = true
testPanel.level = .screenSaver
testPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
testPanel.isMovableByWindowBackground = true
testPanel.orderFrontRegardless()
print("Test panel ordered front")

// 0. Replicate AnyPiP's ordering: enumerate shareable content BEFORE the virtual display exists,
//    to test whether that "poisons" a per-process cache that later calls can't see past.
let earlySemaphore = DispatchSemaphore(value: 0)
Task {
    let earlyContent = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    print("EARLY (pre-vdisplay) SCShareableContent.displays: \(earlyContent?.displays.map { $0.displayID } ?? [])")
    earlySemaphore.signal()
}
earlySemaphore.wait()

// 1. Create the virtual display.
let descriptor = CGVirtualDisplayDescriptor()
descriptor.name = "AnyPiP Virtual Display"
descriptor.maxPixelsWide = 1280
descriptor.maxPixelsHigh = 800
descriptor.sizeInMillimeters = CGSize(width: 300, height: 190)
descriptor.serialNum = 1
descriptor.productID = 1
descriptor.vendorID = 0x1234

let virtualDisplay = CGVirtualDisplay(descriptor: descriptor)
let mode = CGVirtualDisplayMode(width: 1280, height: 800, refreshRate: 60)
let settings = CGVirtualDisplaySettings()
settings.modes = [mode]
settings.hiDPI = 0
let applied = virtualDisplay.apply(settings)
print("applySettings result: \(applied)")

let displayID = virtualDisplay.displayID
print("Virtual display created, displayID=\(displayID)")

// Give the window server a moment to register the new display.
Thread.sleep(forTimeInterval: 1.0)

let bounds = CGDisplayBounds(displayID)
print("Virtual display bounds: \(bounds)")

Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
            print("ERROR: SCShareableContent doesn't see the virtual display. Available displays: \(content.displays.map { $0.displayID })")
            exit(1)
        }
        print("Found matching SCDisplay: \(scDisplay.width)x\(scDisplay.height)")

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        config.width = 1280
        config.height = 800

        let runner = Runner()
        let stream = SCStream(filter: filter, configuration: config, delegate: runner)
        try stream.addStreamOutput(runner, type: .screen, sampleHandlerQueue: DispatchQueue(label: "vd.sample"))
        try await stream.startCapture()
        print("Capture of virtual display started. Move a window onto bounds \(bounds) now.")
        print("READY")

        try await Task.sleep(nanoseconds: 90_000_000_000)
        print("Total frames: \(runner.count)")
        exit(0)
    } catch {
        print("ERROR: \(error)")
        exit(1)
    }
}

RunLoop.main.run()
