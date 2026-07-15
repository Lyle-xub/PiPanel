import os
import Foundation

/// Debug-only trace file used during local iteration. The release overload is an inlined no-op so
/// neither the file writes nor construction of interpolated diagnostic strings reaches production.
#if DEBUG
func debugTrace(_ message: @autoclosure () -> String) {
    let message = message()
    let line = "\(Date()) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    let path = "/tmp/pipanel_trace.log"
    if FileManager.default.fileExists(atPath: path), let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
#else
@inline(__always)
func debugTrace(_ message: @autoclosure () -> String) {}
#endif

enum PiPanelLogger {
    static let capture = Logger(subsystem: "com.pipanel.mac", category: "capture")
    static let panel = Logger(subsystem: "com.pipanel.mac", category: "panel")
    static let interaction = Logger(subsystem: "com.pipanel.mac", category: "interaction")
    static let permissions = Logger(subsystem: "com.pipanel.mac", category: "permissions")
    static let app = Logger(subsystem: "com.pipanel.mac", category: "app")
    static let lyrics = Logger(subsystem: "com.pipanel.mac", category: "lyrics")
}
