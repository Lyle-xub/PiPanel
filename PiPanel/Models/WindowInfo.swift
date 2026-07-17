import ScreenCaptureKit
import CoreGraphics

struct WindowInfo: Identifiable, Hashable {
    let id: CGWindowID
    let title: String
    let ownerPID: pid_t
    let ownerAppName: String
    /// nil only if SCRunningApplication itself failed to report one (rare) — used by
    /// WindowEnumerator.isKnownMusicApp to decide whether this session is eligible for the PiP
    /// lyrics toggle (PiPVideoLayerView.isMusicApp).
    let ownerBundleIdentifier: String?
    let scWindow: SCWindow
    var frame: CGRect

    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
