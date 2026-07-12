import ScreenCaptureKit
import AppKit

enum WindowEnumeratorError: Error {
    case noScreenRecordingAccess
}

/// Lists windows across all apps, including windows on other/full-screen Spaces
/// (onScreenWindowsOnly: false is what makes that possible — CGWindowListCopyWindowInfo cannot do this).
enum WindowEnumerator {
    static func listPiPCandidateWindows() async throws -> [WindowInfo] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
        } catch {
            AnyPiPLogger.capture.error("Failed to enumerate windows: \(error.localizedDescription)")
            throw WindowEnumeratorError.noScreenRecordingAccess
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier

        return content.windows.compactMap { window -> WindowInfo? in
            guard let app = window.owningApplication else { return nil }
            guard app.processID != ownPID else { return nil }
            guard window.frame.width > 60, window.frame.height > 60 else { return nil }
            guard window.windowLayer == 0 else { return nil } // skip system chrome layers
            guard !isSystemHelperWindow(appName: app.applicationName) else { return nil }
            // Windows with no real title (SCWindow.title empty/nil) are usually hidden/template
            // windows an app keeps around internally, not something a user would recognize or
            // want to pick from a list — require a real title rather than falling back to the
            // app's name, which would otherwise make these indistinguishable from the app's
            // actual document window in the picker.
            guard let title = window.title, !title.isEmpty else { return nil }
            return WindowInfo(
                id: window.windowID,
                title: title,
                ownerPID: app.processID,
                ownerAppName: app.applicationName,
                scWindow: window,
                frame: window.frame
            )
        }
        .sorted { $0.ownerAppName.localizedCaseInsensitiveCompare($1.ownerAppName) == .orderedAscending }
    }

    private static let helperAppNamePatterns = [
        "Open and Save Panel Service",
        "AuthenticationServicesHelper",
        "CursorUIViewService",
        "自动填充", "AutoFill",
        "loginwindow",
        "聚焦", "Spotlight",
        "控制中心", "Control Center",
    ]

    private static func isSystemHelperWindow(appName: String) -> Bool {
        helperAppNamePatterns.contains { appName.localizedCaseInsensitiveContains($0) }
    }
}
