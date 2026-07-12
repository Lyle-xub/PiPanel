import ScreenCaptureKit
import CoreGraphics

struct WindowInfo: Identifiable, Hashable {
    let id: CGWindowID
    let title: String
    let ownerPID: pid_t
    let ownerAppName: String
    let scWindow: SCWindow
    var frame: CGRect

    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
