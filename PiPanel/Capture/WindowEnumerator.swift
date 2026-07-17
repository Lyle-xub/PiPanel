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
            PiPanelLogger.capture.error("Failed to enumerate windows: \(error.localizedDescription)")
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
            // want to pick from a list. Microsoft Word is a verified exception: its visible
            // "Open New or Recent" start window is a normal AXStandardWindow, but
            // ScreenCaptureKit publishes it without a title. That made the corner switch appear
            // over the window and then silently do nothing because this second-stage lookup had
            // discarded it. For Word only, match the SC frame back to a real, non-minimized AX
            // window and use that AX title. Requiring that match still rejects Word's hidden
            // internal/template windows as well as titleless windows from every other app.
            let accessibilityFallbackTitle = titlelessAccessibilityFallback(
                windowTitle: window.title,
                windowFrame: window.frame,
                ownerPID: app.processID,
                ownerAppName: app.applicationName,
                ownerBundleIdentifier: app.bundleIdentifier
            )
            guard let title = candidateTitle(
                windowTitle: window.title,
                ownerBundleIdentifier: app.bundleIdentifier,
                titlelessAccessibilityFallback: accessibilityFallbackTitle
            ) else { return nil }
            return WindowInfo(
                id: window.windowID,
                title: title,
                ownerPID: app.processID,
                ownerAppName: app.applicationName,
                ownerBundleIdentifier: app.bundleIdentifier,
                scWindow: window,
                frame: window.frame
            )
        }
        .sorted { $0.ownerAppName.localizedCaseInsensitiveCompare($1.ownerAppName) == .orderedAscending }
    }

    private static let titlelessAXWindowBundleIdentifiers: Set<String> = [
        "com.microsoft.Word",
    ]

    static func candidateTitle(
        windowTitle: String?,
        ownerBundleIdentifier: String?,
        titlelessAccessibilityFallback: String?
    ) -> String? {
        if let windowTitle,
           !windowTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return windowTitle
        }
        guard let ownerBundleIdentifier,
              titlelessAXWindowBundleIdentifiers.contains(ownerBundleIdentifier),
              let titlelessAccessibilityFallback,
              !titlelessAccessibilityFallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return titlelessAccessibilityFallback
    }

    private static func titlelessAccessibilityFallback(
        windowTitle: String?,
        windowFrame: CGRect,
        ownerPID: pid_t,
        ownerAppName: String,
        ownerBundleIdentifier: String?
    ) -> String? {
        if let windowTitle,
           !windowTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }
        guard let ownerBundleIdentifier,
              titlelessAXWindowBundleIdentifiers.contains(ownerBundleIdentifier),
              let axWindow = AXWindowLocator.locate(
                ownerPID: ownerPID,
                approximateFrame: windowFrame,
                title: nil
              ),
              !AXWindowLocator.isMinimized(axWindow) else {
            return nil
        }
        if let axTitle = AXWindowLocator.title(of: axWindow),
           !axTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return axTitle
        }
        return ownerAppName
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

    /// Known music-app bundle identifiers — gates whether PiPVideoLayerView shows its PiP-lyrics
    /// toggle button for a given session (PiPSession.isMusicApp, computed once at
    /// PiPSessionManager.startSession time from WindowInfo.ownerBundleIdentifier). Bundle IDs for
    /// the Chinese music apps here were verified against real installs; if one drifts in a future
    /// app update, the lyrics toggle simply won't appear for that app until this list is updated
    /// — it doesn't block anything else about the PiP session itself.
    private static let knownMusicAppBundleIdentifiers: Set<String> = [
        "com.apple.Music",
        "com.spotify.client",
        "com.tencent.QQMusicMac",
        "com.netease.163music",
        "com.kugou.mac.KugouMusic",
        "com.kuwo.mac",
    ]

    static func isKnownMusicApp(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return knownMusicAppBundleIdentifiers.contains(bundleIdentifier)
    }

    /// Browsers can host either video or ordinary pages, so inclusion in this set only makes a
    /// window *eligible* for video controls. PiPPanelController additionally requires the active
    /// MediaRemote title to match this exact window's title before revealing the button, which
    /// avoids showing a control on every window when another tab/window owns Now Playing.
    private static let knownBrowserBundleIdentifiers: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "org.chromium.Chromium",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
        "com.microsoft.edgemac.Dev",
        "com.microsoft.edgemac.Canary",
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "com.brave.Browser.nightly",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
        "company.thebrowser.Browser",
        "app.zen-browser.zen",
    ]

    /// Native video clients/players whose whole main window is a playback surface. The first id
    /// is the currently installed official 哔哩哔哩 Electron client; the second covers its App Store
    /// variant. IINA and QuickTime are included because they expose the same macOS Now Playing
    /// contract and therefore need no app-specific automation.
    private static let knownNativeVideoBundleIdentifiers: Set<String> = [
        "com.bilibili.bilibiliPC",
        "tv.danmaku.bili",
        "com.colliderli.iina",
        "com.apple.QuickTimePlayerX",
    ]

    static func isKnownVideoApp(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return knownBrowserBundleIdentifiers.contains(bundleIdentifier)
            || knownNativeVideoBundleIdentifiers.contains(bundleIdentifier)
    }

    /// Returns true only when macOS's current media session belongs to this PiP's source app and,
    /// for a browser, its media title also resembles this particular window/tab title. MediaRemote
    /// can target an app but cannot name a browser tab, so the title check is the safest available
    /// guard against controlling a different browser window.
    static func videoPlaybackMatches(
        _ info: NowPlayingInfo?,
        sourceBundleIdentifier: String?,
        windowTitle: String
    ) -> Bool {
        guard let sourceBundleIdentifier,
              isKnownVideoApp(bundleIdentifier: sourceBundleIdentifier),
              info?.bundleIdentifier == sourceBundleIdentifier else { return false }

        if knownNativeVideoBundleIdentifiers.contains(sourceBundleIdentifier) {
            return true
        }

        guard let mediaTitle = info?.title else { return false }
        let normalizedWindowTitle = normalizedMediaTitle(windowTitle)
        let normalizedMediaTitle = normalizedMediaTitle(mediaTitle)
        guard normalizedMediaTitle.count >= 3, normalizedWindowTitle.count >= 3 else { return false }
        return normalizedWindowTitle.contains(normalizedMediaTitle)
            || normalizedMediaTitle.contains(normalizedWindowTitle)
    }

    private static func normalizedMediaTitle(_ value: String) -> String {
        value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }
}
