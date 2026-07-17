import Foundation
import AppKit
import Combine

/// Resolves capture-rate limits from real, user-visible displays. PiPanel's own pre-warmed
/// virtual displays are deliberately excluded so their configured refresh rate cannot feed back
/// into the next settings calculation and inflate the limit after launch.
enum DisplayRefreshRate {
    static let fallbackFPS = 60
    static let minimumSelectableFPS = 5

    static func maximumFPS(from candidates: [Int], fallback: Int = fallbackFPS) -> Int {
        candidates.filter { $0 > 0 }.max() ?? max(fallback, 1)
    }

    static func fps(for screen: NSScreen?) -> Int {
        guard let screen else { return fallbackFPS }
        return maximumFPS(from: [screen.maximumFramesPerSecond])
    }

    static func maximumPhysicalFPS() -> Int {
        maximumFPS(
            from: NSScreen.screens
                .filter { !VirtualDisplayHost.isManagedDisplay($0) }
                .map(\.maximumFramesPerSecond)
        )
    }
}

/// Which screen corner a newly-created PiP panel anchors to, and which direction additional
/// sessions stack from there (M4: multi-session) — isTop/isLeading drive both
/// PiPSessionManager.defaultPanelFrame's geometry and SettingsRootView's picker UI from one place
/// rather than switching on the case separately in each.
enum PanelCorner: String, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight

    var id: String { rawValue }
    var isTop: Bool { self == .topLeft || self == .topRight }
    var isLeading: Bool { self == .topLeft || self == .bottomLeft }

    var displayName: String {
        switch self {
        case .topLeft: return "左上角"
        case .topRight: return "右上角"
        case .bottomLeft: return "左下角"
        case .bottomRight: return "右下角"
        }
    }
}

/// Which gesture actually closes a PiP panel — see PiPVideoLayerView's own doc comments on
/// mouseDown/mouseDragged/mouseUp (.dragToZone) and PiPCloseCornerControl (.cornerButton) for how
/// each is implemented. Mutually exclusive rather than both always-on: showing CloseDropZoneOverlay
/// during every drag *and* a permanent corner button at once would be two competing affordances for
/// the same action, so only whichever this is set to is actually wired up live.
enum PiPCloseMethod: String, CaseIterable, Identifiable {
    case dragToZone
    case cornerButton

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dragToZone: return "拖动到红圈关闭"
        case .cornerButton: return "左上角关闭按钮"
        }
    }
}

/// The user-facing gesture that turns a normal source window into PiP. The corner switch is the
/// free/default path; shake is available to either a trial or a permanent member.
enum PiPActivationMethod: String, CaseIterable, Identifiable {
    case cornerSwitch
    case shake

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cornerSwitch: return "右上角悬停开关"
        case .shake: return "摇一摇窗口"
        }
    }

    /// Resolves the saved preference into the gesture that may actually run. `hasProAccess` maps
    /// to MembershipManager.isMember, so both a live trial and a permanent license unlock shake.
    func resolved(hasProAccess: Bool) -> PiPActivationMethod {
        self == .shake && !hasProAccess ? .cornerSwitch : self
    }
}

/// How PiPVideoLayerView.updateBorderAppearance draws a panel's edge — see that method's own doc
/// comment for the rendering technique behind each case.
enum PanelBorderStyle: String, CaseIterable, Identifiable {
    case none, stroke, frostedGlass, gradient, glow

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "无"
        case .stroke: return "简单描边"
        case .frostedGlass: return "毛玻璃"
        case .gradient: return "渐变"
        case .glow: return "光效"
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore(userDefaults: .standard)

    /// One source of truth shared by first launch and “恢复所有设置”. Keeping these values together
    /// prevents a newly-added preference from silently getting one default after launch and a
    /// different value after the user presses reset.
    enum DefaultValues {
        static let targetFPS = 15
        static let virtualDisplayLongEdge = 1664.0
        static let captureOutputLongEdge = 960.0
        static let autoReturnEnabled = false
        static let autoReturnIdleInterval = 1.5
        static let autoStackOnIdleEnabled = false
        static let autoStackIdleInterval = 60.0
        static let autoHideWhenSourceActive = true
        static let defaultPanelWidth = 340.0
        static let defaultStackingCorner = PanelCorner.topRight
        static let panelCornerRadius = 12.0
        static let panelShadowEnabled = true
        static let edgeHandleColorHex = "FFFFFF"
        static let edgeHandleWidth = 10.0
        static let edgeHandleHeight = 64.0
        static let stackCascadeStep = 14.0
        static let stackCascadeMargin = 24.0
        static let stackMaxVisibleDepth = 5.0
        static let panelAppearRippleEnabled = true
        static let panelBackgroundColorHex = "000000"
        static let panelBorderStyle = PanelBorderStyle.none
        static let panelBorderColorHex = "FFFFFF"
        static let panelBorderGradientEndColorHex = "0A84FF"
        static let panelBorderWidth = 2.0
        static let panelTitleEnabled = false
        static let panelOpacity = 1.0
        static let panelLyricsEnabled = true
        static let panelCloseMethod = PiPCloseMethod.cornerButton
        static let pipActivationMethod = PiPActivationMethod.cornerSwitch
        static let stackShortcut = GlobalShortcut(
            keyCode: 1,
            modifierFlags: [.option, .command]
        )
        static let closeAllShortcut = GlobalShortcut(
            keyCode: 13,
            modifierFlags: [.option, .command]
        )
        static let pipAllShortcut = GlobalShortcut(
            keyCode: 35,
            modifierFlags: [.option, .command]
        )
    }

    /// Preserve the original user-selectable 1280×800 minimum. CaptureSession independently
    /// expands a live virtual display when a source app refuses to shrink enough to fit it, so
    /// users can still choose the lower-resource mode without reintroducing permanent cropping.
    static let minimumVirtualDisplayLongEdge = 1280.0
    static let maximumVirtualDisplayLongEdge = Double(VirtualDisplayHost.maxPixelsWide)

    private let userDefaults: UserDefaults

    private enum Keys {
        static let targetFPS = "settings.targetFPS"
        static let virtualDisplayLongEdge = "settings.virtualDisplayLongEdge"
        static let captureOutputLongEdge = "settings.captureOutputLongEdge"
        static let autoReturnEnabled = "settings.autoReturnEnabled"
        static let autoReturnIdleInterval = "settings.autoReturnIdleInterval"
        static let autoStackOnIdleEnabled = "settings.autoStackOnIdleEnabled"
        static let autoStackIdleInterval = "settings.autoStackIdleInterval"
        static let autoHideWhenSourceActive = "settings.autoHideWhenSourceActive"
        static let hasCompletedWelcome = "settings.hasCompletedWelcome"
        static let defaultPanelWidth = "settings.defaultPanelWidth"
        static let defaultStackingCorner = "settings.defaultStackingCorner"
        static let panelCornerRadius = "settings.panelCornerRadius"
        static let panelShadowEnabled = "settings.panelShadowEnabled"
        static let edgeHandleColorHex = "settings.edgeHandleColorHex"
        static let edgeHandleWidth = "settings.edgeHandleWidth"
        static let edgeHandleHeight = "settings.edgeHandleHeight"
        static let stackCascadeStep = "settings.stackCascadeStep"
        static let stackCascadeMargin = "settings.stackCascadeMargin"
        static let stackMaxVisibleDepth = "settings.stackMaxVisibleDepth"
        static let panelAppearRippleEnabled = "settings.panelAppearRippleEnabled"
        static let panelBackgroundColorHex = "settings.panelBackgroundColorHex"
        static let panelBorderStyle = "settings.panelBorderStyle"
        static let panelBorderColorHex = "settings.panelBorderColorHex"
        static let panelBorderGradientEndColorHex = "settings.panelBorderGradientEndColorHex"
        static let panelBorderWidth = "settings.panelBorderWidth"
        static let panelTitleEnabled = "settings.panelTitleEnabled"
        static let panelOpacity = "settings.panelOpacity"
        static let panelLyricsEnabled = "settings.panelLyricsEnabled"
        static let panelCloseMethod = "settings.panelCloseMethod"
        static let pipActivationMethod = "settings.pipActivationMethod"
        static let stackShortcutKeyCode = "settings.stackShortcutKeyCode"
        static let stackShortcutModifiers = "settings.stackShortcutModifiers"
        static let closeAllShortcutKeyCode = "settings.closeAllShortcutKeyCode"
        static let closeAllShortcutModifiers = "settings.closeAllShortcutModifiers"
        static let pipAllShortcutKeyCode = "settings.pipAllShortcutKeyCode"
        static let pipAllShortcutModifiers = "settings.pipAllShortcutModifiers"
    }

    @Published var targetFPS: Int {
        didSet { userDefaults.set(targetFPS, forKey: Keys.targetFPS) }
    }
    /// The private virtual display's pixel long edge (CaptureSession.virtualDisplayLongEdge) —
    /// how much room a PiP session's source window has to be resized into. Applied at session
    /// creation (PiPSessionManager.startSession) and also pushed live into every already-open
    /// session (PiPSessionManager.observeLiveSettings) — CaptureSession's own didSet on
    /// virtualDisplayLongEdge live-resizes the running VirtualDisplayHost, which works even against
    /// a display an SCStream is already capturing (see VirtualDisplayHost.resize's doc comment;
    /// verified in Spikes/VirtualDisplayResizeSpike). The settings UI retains its original 1280px
    /// minimum; known oversized Electron windows are handled by CaptureSession's automatic
    /// per-session expansion instead of globally removing lower-resolution choices.
    @Published var virtualDisplayLongEdge: Double {
        didSet {
            let normalized = Self.normalizedVirtualDisplayLongEdge(virtualDisplayLongEdge)
            if normalized != virtualDisplayLongEdge {
                virtualDisplayLongEdge = normalized
            }
            userDefaults.set(normalized, forKey: Keys.virtualDisplayLongEdge)
        }
    }
    /// SCStreamConfiguration's output pixel long edge (CaptureSession.maxOutputLongEdge /
    /// makeConfiguration's maxLongEdge) — the actual sharpness of the mirrored picture, since the
    /// pipeline streams raw uncompressed frames with no separate bitrate/quality knob. Unlike
    /// virtualDisplayLongEdge this applies live to already-open sessions (same pattern as
    /// targetFPS) since it's just an SCStreamConfiguration field, not the display's own mode.
    @Published var captureOutputLongEdge: Double {
        didSet { userDefaults.set(captureOutputLongEdge, forKey: Keys.captureOutputLongEdge) }
    }
    @Published var autoReturnEnabled: Bool {
        didSet { userDefaults.set(autoReturnEnabled, forKey: Keys.autoReturnEnabled) }
    }
    @Published var autoReturnIdleInterval: Double {
        didSet { userDefaults.set(autoReturnIdleInterval, forKey: Keys.autoReturnIdleInterval) }
    }
    /// After autoStackIdleInterval seconds with no input anywhere on the system (not just within a
    /// PiP panel — see GlobalIdleMonitor's own doc comment for why it watches system-wide idle
    /// time rather than per-panel activity), every open PiP session automatically gathers into
    /// defaultStackingCorner, the same place stackShortcut/PiPSessionManager.stackAllSessions
    /// already put them. Off by default, matching autoReturnEnabled's own reasoning: silently
    /// rearranging windows the user hasn't touched in a while should be an opt-in convenience, not
    /// a surprise the first time it fires.
    @Published var autoStackOnIdleEnabled: Bool {
        didSet { userDefaults.set(autoStackOnIdleEnabled, forKey: Keys.autoStackOnIdleEnabled) }
    }
    @Published var autoStackIdleInterval: Double {
        didSet { userDefaults.set(autoStackIdleInterval, forKey: Keys.autoStackIdleInterval) }
    }
    /// M3: hide the panel and pull the window back to the physical screen while its source app
    /// is frontmost. Off by default it would just keep mirroring a window the user is already
    /// looking at directly, so this defaults on.
    @Published var autoHideWhenSourceActive: Bool {
        didSet { userDefaults.set(autoHideWhenSourceActive, forKey: Keys.autoHideWhenSourceActive) }
    }
    /// Gates the first-launch WelcomeWindowController presentation (AppDelegate) — false only
    /// until the user dismisses the welcome window once, ever.
    @Published var hasCompletedWelcome: Bool {
        didSet { userDefaults.set(hasCompletedWelcome, forKey: Keys.hasCompletedWelcome) }
    }
    /// PiPSessionManager.defaultPanelFrame's starting width for a newly-created panel — read
    /// once per session at creation time, not live-applied to already-open panels (same contract
    /// as every other setting here).
    @Published var defaultPanelWidth: Double {
        didSet { userDefaults.set(defaultPanelWidth, forKey: Keys.defaultPanelWidth) }
    }
    @Published var defaultStackingCorner: PanelCorner {
        didSet { userDefaults.set(defaultStackingCorner.rawValue, forKey: Keys.defaultStackingCorner) }
    }
    @Published var panelCornerRadius: Double {
        didSet { userDefaults.set(panelCornerRadius, forKey: Keys.panelCornerRadius) }
    }
    @Published var panelShadowEnabled: Bool {
        didSet { userDefaults.set(panelShadowEnabled, forKey: Keys.panelShadowEnabled) }
    }
    /// EdgeHandleWindow's own fill color — read once each time the handle is shown
    /// (EdgeHandleWindow.show), not observed live, since the handle itself is only ever briefly
    /// visible/hidden rather than something a user would be staring at while adjusting this.
    @Published var edgeHandleColorHex: String {
        didSet { userDefaults.set(edgeHandleColorHex, forKey: Keys.edgeHandleColorHex) }
    }
    @Published var edgeHandleWidth: Double {
        didSet { userDefaults.set(edgeHandleWidth, forKey: Keys.edgeHandleWidth) }
    }
    @Published var edgeHandleHeight: Double {
        didSet { userDefaults.set(edgeHandleHeight, forKey: Keys.edgeHandleHeight) }
    }
    /// Per-layer cascade offset PiPSessionManager.snapSessionsToStackingCorner applies to each
    /// panel further back in the overlapping stack — unlike most settings here, this and the two
    /// properties below are read fresh every time that method runs (including for an
    /// already-open, already-stacked group), so changing them applies live with no extra
    /// plumbing needed.
    @Published var stackCascadeStep: Double {
        didSet { userDefaults.set(stackCascadeStep, forKey: Keys.stackCascadeStep) }
    }
    /// Shared between snapSessionsToStackingCorner's stacked-corner position and
    /// defaultPanelFrame's own edge margin for a freshly-created panel — previously two
    /// independent hardcoded copies of the same "24pt in from the screen edge" value.
    @Published var stackCascadeMargin: Double {
        didSet { userDefaults.set(stackCascadeMargin, forKey: Keys.stackCascadeMargin) }
    }
    @Published var stackMaxVisibleDepth: Double {
        didSet { userDefaults.set(stackMaxVisibleDepth, forKey: Keys.stackMaxVisibleDepth) }
    }
    @Published var panelAppearRippleEnabled: Bool {
        didSet { userDefaults.set(panelAppearRippleEnabled, forKey: Keys.panelAppearRippleEnabled) }
    }
    @Published var panelBackgroundColorHex: String {
        didSet { userDefaults.set(panelBackgroundColorHex, forKey: Keys.panelBackgroundColorHex) }
    }
    @Published var panelBorderStyle: PanelBorderStyle {
        didSet { userDefaults.set(panelBorderStyle.rawValue, forKey: Keys.panelBorderStyle) }
    }
    /// Stroke color for .stroke, glow color for .glow, gradient start color for .gradient —
    /// shared across styles rather than a separate hex setting per style.
    @Published var panelBorderColorHex: String {
        didSet { userDefaults.set(panelBorderColorHex, forKey: Keys.panelBorderColorHex) }
    }
    /// Only used when panelBorderStyle == .gradient.
    @Published var panelBorderGradientEndColorHex: String {
        didSet { userDefaults.set(panelBorderGradientEndColorHex, forKey: Keys.panelBorderGradientEndColorHex) }
    }
    /// Stroke width for .stroke, ring thickness for .frostedGlass/.gradient/.glow.
    @Published var panelBorderWidth: Double {
        didSet { userDefaults.set(panelBorderWidth, forKey: Keys.panelBorderWidth) }
    }
    @Published var panelTitleEnabled: Bool {
        didSet { userDefaults.set(panelTitleEnabled, forKey: Keys.panelTitleEnabled) }
    }
    /// The PiP panel window's own alpha while it's actually meant to be visible — unlike most
    /// appearance settings here, this applies live to already-open sessions
    /// (PiPSessionManager.observeLiveSettings -> PiPPanelController.updateOpacity), the same way
    /// captureOutputLongEdge does, since seeing the transparency change immediately is the whole
    /// point of a slider like this. Floored at 0.2 rather than 0 in the settings UI — fully
    /// invisible-but-still-there isn't a state this slider is meant to reach (that's what
    /// closing/hiding the panel is for).
    @Published var panelOpacity: Double {
        didSet { userDefaults.set(panelOpacity, forKey: Keys.panelOpacity) }
    }
    /// Shows/hides the PiP-lyrics toggle button (PiPVideoLayerView.updateLyricsToggleButton) for
    /// sessions whose source app is a known music app — read live, not just at panel-creation
    /// time, so turning this off immediately hides the button on already-open panels too, the
    /// same way a user would expect a plain visibility toggle to behave.
    @Published var panelLyricsEnabled: Bool {
        didSet { userDefaults.set(panelLyricsEnabled, forKey: Keys.panelLyricsEnabled) }
    }
    /// Read live by PiPVideoLayerView (from layout(), and at the top of every drag-gesture method
    /// that would otherwise engage CloseDropZoneOverlay) rather than cached at panel-creation time
    /// — same "a plain mode switch should take effect immediately" reasoning as panelLyricsEnabled.
    @Published var panelCloseMethod: PiPCloseMethod {
        didSet { userDefaults.set(panelCloseMethod.rawValue, forKey: Keys.panelCloseMethod) }
    }
    @Published var pipActivationMethod: PiPActivationMethod {
        didSet { userDefaults.set(pipActivationMethod.rawValue, forKey: Keys.pipActivationMethod) }
    }
    /// The global shortcut GlobalHotkeyManager watches for to trigger PiPSessionManager.
    /// stackAllSessions — nil means no shortcut is registered (the monitor still runs, matching
    /// every keyDown against nothing, cheap enough not to bother tearing it down over). Stored as
    /// two flat UserDefaults values rather than an archived GlobalShortcut, consistent with
    /// every other setting here being a plain value rather than a nested encoded object.
    @Published var stackShortcut: GlobalShortcut? {
        didSet {
            if let stackShortcut {
                userDefaults.set(Int(stackShortcut.keyCode), forKey: Keys.stackShortcutKeyCode)
                userDefaults.set(stackShortcut.modifierFlags.rawValue, forKey: Keys.stackShortcutModifiers)
            } else {
                userDefaults.removeObject(forKey: Keys.stackShortcutKeyCode)
                userDefaults.removeObject(forKey: Keys.stackShortcutModifiers)
            }
        }
    }
    /// Triggers PiPSessionManager.stopAll() — closes every open PiP session at once.
    @Published var closeAllShortcut: GlobalShortcut? {
        didSet {
            if let closeAllShortcut {
                userDefaults.set(Int(closeAllShortcut.keyCode), forKey: Keys.closeAllShortcutKeyCode)
                userDefaults.set(closeAllShortcut.modifierFlags.rawValue, forKey: Keys.closeAllShortcutModifiers)
            } else {
                userDefaults.removeObject(forKey: Keys.closeAllShortcutKeyCode)
                userDefaults.removeObject(forKey: Keys.closeAllShortcutModifiers)
            }
        }
    }
    /// Triggers PiPSessionManager.pipAllEligibleWindows() — turns every non-fullscreen, not
    /// already-PiP'd window into a PiP session and gathers the result into the overlapping stack.
    @Published var pipAllShortcut: GlobalShortcut? {
        didSet {
            if let pipAllShortcut {
                userDefaults.set(Int(pipAllShortcut.keyCode), forKey: Keys.pipAllShortcutKeyCode)
                userDefaults.set(pipAllShortcut.modifierFlags.rawValue, forKey: Keys.pipAllShortcutModifiers)
            } else {
                userDefaults.removeObject(forKey: Keys.pipAllShortcutKeyCode)
                userDefaults.removeObject(forKey: Keys.pipAllShortcutModifiers)
            }
        }
    }

    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
        targetFPS = userDefaults.object(forKey: Keys.targetFPS) as? Int ?? DefaultValues.targetFPS
        let storedVirtualDisplayLongEdge = userDefaults.object(
            forKey: Keys.virtualDisplayLongEdge
        ) as? Double
        let normalizedVirtualDisplayLongEdge = Self.normalizedVirtualDisplayLongEdge(
            storedVirtualDisplayLongEdge ?? DefaultValues.virtualDisplayLongEdge
        )
        virtualDisplayLongEdge = normalizedVirtualDisplayLongEdge
        // Property observers do not run during initialization. Persist only genuinely invalid
        // out-of-range values; valid historical choices such as 1280/1664 remain untouched.
        if let storedVirtualDisplayLongEdge,
           storedVirtualDisplayLongEdge != normalizedVirtualDisplayLongEdge {
            userDefaults.set(normalizedVirtualDisplayLongEdge, forKey: Keys.virtualDisplayLongEdge)
        }
        captureOutputLongEdge = userDefaults.object(
            forKey: Keys.captureOutputLongEdge
        ) as? Double ?? DefaultValues.captureOutputLongEdge
        // Off by default: returning focus to whatever was frontmost before after a mere few
        // seconds of idle directly undermines treating the PiP as a continuously operable
        // window — any pause to read/think/move the mouse felt like the window "losing focus".
        autoReturnEnabled = userDefaults.object(
            forKey: Keys.autoReturnEnabled
        ) as? Bool ?? DefaultValues.autoReturnEnabled
        autoReturnIdleInterval = userDefaults.object(
            forKey: Keys.autoReturnIdleInterval
        ) as? Double ?? DefaultValues.autoReturnIdleInterval
        autoStackOnIdleEnabled = userDefaults.object(
            forKey: Keys.autoStackOnIdleEnabled
        ) as? Bool ?? DefaultValues.autoStackOnIdleEnabled
        autoStackIdleInterval = userDefaults.object(
            forKey: Keys.autoStackIdleInterval
        ) as? Double ?? DefaultValues.autoStackIdleInterval
        autoHideWhenSourceActive = userDefaults.object(
            forKey: Keys.autoHideWhenSourceActive
        ) as? Bool ?? DefaultValues.autoHideWhenSourceActive
        hasCompletedWelcome = userDefaults.object(forKey: Keys.hasCompletedWelcome) as? Bool ?? false
        defaultPanelWidth = userDefaults.object(
            forKey: Keys.defaultPanelWidth
        ) as? Double ?? DefaultValues.defaultPanelWidth
        if let raw = userDefaults.string(forKey: Keys.defaultStackingCorner),
           let corner = PanelCorner(rawValue: raw) {
            defaultStackingCorner = corner
        } else {
            // Matches the behavior PiPSessionManager.defaultPanelFrame hardcoded before this
            // setting existed — always top-right, stacking downward.
            defaultStackingCorner = DefaultValues.defaultStackingCorner
        }
        panelCornerRadius = userDefaults.object(
            forKey: Keys.panelCornerRadius
        ) as? Double ?? DefaultValues.panelCornerRadius
        panelShadowEnabled = userDefaults.object(
            forKey: Keys.panelShadowEnabled
        ) as? Bool ?? DefaultValues.panelShadowEnabled
        edgeHandleColorHex = userDefaults.string(
            forKey: Keys.edgeHandleColorHex
        ) ?? DefaultValues.edgeHandleColorHex
        edgeHandleWidth = userDefaults.object(
            forKey: Keys.edgeHandleWidth
        ) as? Double ?? DefaultValues.edgeHandleWidth
        edgeHandleHeight = userDefaults.object(
            forKey: Keys.edgeHandleHeight
        ) as? Double ?? DefaultValues.edgeHandleHeight
        stackCascadeStep = userDefaults.object(
            forKey: Keys.stackCascadeStep
        ) as? Double ?? DefaultValues.stackCascadeStep
        stackCascadeMargin = userDefaults.object(
            forKey: Keys.stackCascadeMargin
        ) as? Double ?? DefaultValues.stackCascadeMargin
        stackMaxVisibleDepth = userDefaults.object(
            forKey: Keys.stackMaxVisibleDepth
        ) as? Double ?? DefaultValues.stackMaxVisibleDepth
        panelAppearRippleEnabled = userDefaults.object(
            forKey: Keys.panelAppearRippleEnabled
        ) as? Bool ?? DefaultValues.panelAppearRippleEnabled
        panelBackgroundColorHex = userDefaults.string(
            forKey: Keys.panelBackgroundColorHex
        ) ?? DefaultValues.panelBackgroundColorHex
        if let raw = userDefaults.string(forKey: Keys.panelBorderStyle),
           let style = PanelBorderStyle(rawValue: raw) {
            panelBorderStyle = style
        } else {
            panelBorderStyle = DefaultValues.panelBorderStyle
        }
        panelBorderColorHex = userDefaults.string(
            forKey: Keys.panelBorderColorHex
        ) ?? DefaultValues.panelBorderColorHex
        panelBorderGradientEndColorHex = userDefaults.string(
            forKey: Keys.panelBorderGradientEndColorHex
        ) ?? DefaultValues.panelBorderGradientEndColorHex
        panelBorderWidth = userDefaults.object(
            forKey: Keys.panelBorderWidth
        ) as? Double ?? DefaultValues.panelBorderWidth
        panelTitleEnabled = userDefaults.object(
            forKey: Keys.panelTitleEnabled
        ) as? Bool ?? DefaultValues.panelTitleEnabled
        panelOpacity = userDefaults.object(
            forKey: Keys.panelOpacity
        ) as? Double ?? DefaultValues.panelOpacity
        panelLyricsEnabled = userDefaults.object(
            forKey: Keys.panelLyricsEnabled
        ) as? Bool ?? DefaultValues.panelLyricsEnabled
        if let raw = userDefaults.string(forKey: Keys.panelCloseMethod),
           let method = PiPCloseMethod(rawValue: raw) {
            panelCloseMethod = method
        } else {
            panelCloseMethod = DefaultValues.panelCloseMethod
        }
        if let raw = userDefaults.string(forKey: Keys.pipActivationMethod),
           let method = PiPActivationMethod(rawValue: raw) {
            pipActivationMethod = method
        } else {
            pipActivationMethod = DefaultValues.pipActivationMethod
        }
        if let keyCode = userDefaults.object(forKey: Keys.stackShortcutKeyCode) as? Int {
            let modifiers = userDefaults.object(forKey: Keys.stackShortcutModifiers) as? UInt ?? 0
            stackShortcut = GlobalShortcut(keyCode: UInt16(keyCode), modifierFlags: NSEvent.ModifierFlags(rawValue: modifiers))
        } else {
            // ⌥⌘S ("stack") — chosen to avoid the handful of ⌘-only/⌘⇧ combinations macOS or
            // common apps already claim system-wide; unset entirely (nil) once the user records
            // something else, or clears it via the settings UI.
            stackShortcut = DefaultValues.stackShortcut
        }
        if let keyCode = userDefaults.object(forKey: Keys.closeAllShortcutKeyCode) as? Int {
            let modifiers = userDefaults.object(forKey: Keys.closeAllShortcutModifiers) as? UInt ?? 0
            closeAllShortcut = GlobalShortcut(keyCode: UInt16(keyCode), modifierFlags: NSEvent.ModifierFlags(rawValue: modifiers))
        } else {
            closeAllShortcut = DefaultValues.closeAllShortcut
        }
        if let keyCode = userDefaults.object(forKey: Keys.pipAllShortcutKeyCode) as? Int {
            let modifiers = userDefaults.object(forKey: Keys.pipAllShortcutModifiers) as? UInt ?? 0
            pipAllShortcut = GlobalShortcut(keyCode: UInt16(keyCode), modifierFlags: NSEvent.ModifierFlags(rawValue: modifiers))
        } else {
            pipAllShortcut = DefaultValues.pipAllShortcut
        }
    }

    static func normalizedVirtualDisplayLongEdge(_ value: Double) -> Double {
        guard value.isFinite else { return DefaultValues.virtualDisplayLongEdge }
        return min(max(value, minimumVirtualDisplayLongEdge), maximumVirtualDisplayLongEdge)
    }

    /// Resets every user-facing app-local setting to `DefaultValues`, the same source used by a
    /// clean first launch.
    ///
    /// Deliberately leaves these things untouched:
    ///  - launch-at-login: an OS-level preference managed independently by SMAppService
    ///  - hasCompletedWelcome: an internal onboarding flag, never exposed anywhere in the settings
    ///    UI — resetting it would just unexpectedly resurface the first-launch welcome window
    ///    rather than reset anything the user actually configured.
    func resetToDefaults() {
        targetFPS = DefaultValues.targetFPS
        virtualDisplayLongEdge = DefaultValues.virtualDisplayLongEdge
        captureOutputLongEdge = DefaultValues.captureOutputLongEdge
        autoReturnEnabled = DefaultValues.autoReturnEnabled
        autoReturnIdleInterval = DefaultValues.autoReturnIdleInterval
        autoStackOnIdleEnabled = DefaultValues.autoStackOnIdleEnabled
        autoStackIdleInterval = DefaultValues.autoStackIdleInterval
        autoHideWhenSourceActive = DefaultValues.autoHideWhenSourceActive
        defaultPanelWidth = DefaultValues.defaultPanelWidth
        defaultStackingCorner = DefaultValues.defaultStackingCorner
        panelCornerRadius = DefaultValues.panelCornerRadius
        panelShadowEnabled = DefaultValues.panelShadowEnabled
        edgeHandleColorHex = DefaultValues.edgeHandleColorHex
        edgeHandleWidth = DefaultValues.edgeHandleWidth
        edgeHandleHeight = DefaultValues.edgeHandleHeight
        stackCascadeStep = DefaultValues.stackCascadeStep
        stackCascadeMargin = DefaultValues.stackCascadeMargin
        stackMaxVisibleDepth = DefaultValues.stackMaxVisibleDepth
        panelAppearRippleEnabled = DefaultValues.panelAppearRippleEnabled
        panelBackgroundColorHex = DefaultValues.panelBackgroundColorHex
        panelBorderStyle = DefaultValues.panelBorderStyle
        panelBorderColorHex = DefaultValues.panelBorderColorHex
        panelBorderGradientEndColorHex = DefaultValues.panelBorderGradientEndColorHex
        panelBorderWidth = DefaultValues.panelBorderWidth
        panelTitleEnabled = DefaultValues.panelTitleEnabled
        panelOpacity = DefaultValues.panelOpacity
        panelLyricsEnabled = DefaultValues.panelLyricsEnabled
        panelCloseMethod = DefaultValues.panelCloseMethod
        pipActivationMethod = DefaultValues.pipActivationMethod
        stackShortcut = DefaultValues.stackShortcut
        closeAllShortcut = DefaultValues.closeAllShortcut
        pipAllShortcut = DefaultValues.pipAllShortcut
    }
}
