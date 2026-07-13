import Foundation

final class PiPSession: Identifiable {
    let id = UUID()
    let windowInfo: WindowInfo
    let captureSession: CaptureSession
    let panelController: PiPPanelController

    init(windowInfo: WindowInfo, captureSession: CaptureSession, panelController: PiPPanelController) {
        self.windowInfo = windowInfo
        self.captureSession = captureSession
        self.panelController = panelController
    }
}
