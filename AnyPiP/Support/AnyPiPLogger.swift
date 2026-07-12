import os
import Foundation

/// Temporary M1-bring-up aid: os_log has proven unreliable to tail live from the shell in this
/// environment, so mirror key milestones to a plain file for fast iteration. Remove once M1 is stable.
func debugTrace(_ message: String) {
    let line = "\(Date()) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    let path = "/tmp/anypip_trace.log"
    if FileManager.default.fileExists(atPath: path), let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

enum AnyPiPLogger {
    static let capture = Logger(subsystem: "com.anypip.mac", category: "capture")
    static let panel = Logger(subsystem: "com.anypip.mac", category: "panel")
    static let interaction = Logger(subsystem: "com.anypip.mac", category: "interaction")
    static let permissions = Logger(subsystem: "com.anypip.mac", category: "permissions")
    static let app = Logger(subsystem: "com.anypip.mac", category: "app")
}
