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
    static let shared = SettingsStore()

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
        didSet { UserDefaults.standard.set(targetFPS, forKey: Keys.targetFPS) }
    }
    /// The pixel long edge available to each source window inside the shared canvas. It is a
    /// session-local workspace limit, not the CGVirtualDisplay's own mode; changing it therefore
    /// applies live without reconfiguring displays or flashing the user's screens.
    @Published var virtualDisplayLongEdge: Double {
        didSet { UserDefaults.standard.set(virtualDisplayLongEdge, forKey: Keys.virtualDisplayLongEdge) }
    }
    /// SCStreamConfiguration's output pixel long edge (CaptureSession.maxOutputLongEdge /
    /// makeConfiguration's maxLongEdge) — the actual sharpness of the mirrored picture, since the
    /// pipeline streams raw uncompressed frames with no separate bitrate/quality knob. Unlike
    /// virtualDisplayLongEdge this applies live to already-open sessions (same pattern as
    /// targetFPS) since it's just an SCStreamConfiguration field, not the display's own mode.
    @Published var captureOutputLongEdge: Double {
        didSet { UserDefaults.standard.set(captureOutputLongEdge, forKey: Keys.captureOutputLongEdge) }
    }
    @Published var autoReturnEnabled: Bool {
        didSet { UserDefaults.standard.set(autoReturnEnabled, forKey: Keys.autoReturnEnabled) }
    }
    @Published var autoReturnIdleInterval: Double {
        didSet { UserDefaults.standard.set(autoReturnIdleInterval, forKey: Keys.autoReturnIdleInterval) }
    }
    /// After autoStackIdleInterval seconds with no input anywhere on the system (not just within a
    /// PiP panel — see GlobalIdleMonitor's own doc comment for why it watches system-wide idle
    /// time rather than per-panel activity), every open PiP session automatically gathers into
    /// defaultStackingCorner, the same place stackShortcut/PiPSessionManager.stackAllSessions
    /// already put them. Off by default, matching autoReturnEnabled's own reasoning: silently
    /// rearranging windows the user hasn't touched in a while should be an opt-in convenience, not
    /// a surprise the first time it fires.
    @Published var autoStackOnIdleEnabled: Bool {
        didSet { UserDefaults.standard.set(autoStackOnIdleEnabled, forKey: Keys.autoStackOnIdleEnabled) }
    }
    @Published var autoStackIdleInterval: Double {
        didSet { UserDefaults.standard.set(autoStackIdleInterval, forKey: Keys.autoStackIdleInterval) }
    }
    /// M3: hide the panel and pull the window back to the physical screen while its source app
    /// is frontmost. Off by default it would just keep mirroring a window the user is already
    /// looking at directly, so this defaults on.
    @Published var autoHideWhenSourceActive: Bool {
        didSet { UserDefaults.standard.set(autoHideWhenSourceActive, forKey: Keys.autoHideWhenSourceActive) }
    }
    /// Gates the first-launch WelcomeWindowController presentation (AppDelegate) — false only
    /// until the user dismisses the welcome window once, ever.
    @Published var hasCompletedWelcome: Bool {
        didSet { UserDefaults.standard.set(hasCompletedWelcome, forKey: Keys.hasCompletedWelcome) }
    }
    /// PiPSessionManager.defaultPanelFrame's starting width for a newly-created panel — read
    /// once per session at creation time, not live-applied to already-open panels (same contract
    /// as every other setting here).
    @Published var defaultPanelWidth: Double {
        didSet { UserDefaults.standard.set(defaultPanelWidth, forKey: Keys.defaultPanelWidth) }
    }
    @Published var defaultStackingCorner: PanelCorner {
        didSet { UserDefaults.standard.set(defaultStackingCorner.rawValue, forKey: Keys.defaultStackingCorner) }
    }
    @Published var panelCornerRadius: Double {
        didSet { UserDefaults.standard.set(panelCornerRadius, forKey: Keys.panelCornerRadius) }
    }
    @Published var panelShadowEnabled: Bool {
        didSet { UserDefaults.standard.set(panelShadowEnabled, forKey: Keys.panelShadowEnabled) }
    }
    /// EdgeHandleWindow's own fill color — read once each time the handle is shown
    /// (EdgeHandleWindow.show), not observed live, since the handle itself is only ever briefly
    /// visible/hidden rather than something a user would be staring at while adjusting this.
    @Published var edgeHandleColorHex: String {
        didSet { UserDefaults.standard.set(edgeHandleColorHex, forKey: Keys.edgeHandleColorHex) }
    }
    @Published var edgeHandleWidth: Double {
        didSet { UserDefaults.standard.set(edgeHandleWidth, forKey: Keys.edgeHandleWidth) }
    }
    @Published var edgeHandleHeight: Double {
        didSet { UserDefaults.standard.set(edgeHandleHeight, forKey: Keys.edgeHandleHeight) }
    }
    /// Per-layer cascade offset PiPSessionManager.snapSessionsToStackingCorner applies to each
    /// panel further back in the overlapping stack — unlike most settings here, this and the two
    /// properties below are read fresh every time that method runs (including for an
    /// already-open, already-stacked group), so changing them applies live with no extra
    /// plumbing needed.
    @Published var stackCascadeStep: Double {
        didSet { UserDefaults.standard.set(stackCascadeStep, forKey: Keys.stackCascadeStep) }
    }
    /// Shared between snapSessionsToStackingCorner's stacked-corner position and
    /// defaultPanelFrame's own edge margin for a freshly-created panel — previously two
    /// independent hardcoded copies of the same "24pt in from the screen edge" value.
    @Published var stackCascadeMargin: Double {
        didSet { UserDefaults.standard.set(stackCascadeMargin, forKey: Keys.stackCascadeMargin) }
    }
    @Published var stackMaxVisibleDepth: Double {
        didSet { UserDefaults.standard.set(stackMaxVisibleDepth, forKey: Keys.stackMaxVisibleDepth) }
    }
    @Published var panelAppearRippleEnabled: Bool {
        didSet { UserDefaults.standard.set(panelAppearRippleEnabled, forKey: Keys.panelAppearRippleEnabled) }
    }
    @Published var panelBackgroundColorHex: String {
        didSet { UserDefaults.standard.set(panelBackgroundColorHex, forKey: Keys.panelBackgroundColorHex) }
    }
    @Published var panelBorderStyle: PanelBorderStyle {
        didSet { UserDefaults.standard.set(panelBorderStyle.rawValue, forKey: Keys.panelBorderStyle) }
    }
    /// Stroke color for .stroke, glow color for .glow, gradient start color for .gradient —
    /// shared across styles rather than a separate hex setting per style.
    @Published var panelBorderColorHex: String {
        didSet { UserDefaults.standard.set(panelBorderColorHex, forKey: Keys.panelBorderColorHex) }
    }
    /// Only used when panelBorderStyle == .gradient.
    @Published var panelBorderGradientEndColorHex: String {
        didSet { UserDefaults.standard.set(panelBorderGradientEndColorHex, forKey: Keys.panelBorderGradientEndColorHex) }
    }
    /// Stroke width for .stroke, ring thickness for .frostedGlass/.gradient/.glow.
    @Published var panelBorderWidth: Double {
        didSet { UserDefaults.standard.set(panelBorderWidth, forKey: Keys.panelBorderWidth) }
    }
    @Published var panelTitleEnabled: Bool {
        didSet { UserDefaults.standard.set(panelTitleEnabled, forKey: Keys.panelTitleEnabled) }
    }
    /// The PiP panel window's own alpha while it's actually meant to be visible — unlike most
    /// appearance settings here, this applies live to already-open sessions
    /// (PiPSessionManager.observeLiveSettings -> PiPPanelController.updateOpacity), the same way
    /// captureOutputLongEdge does, since seeing the transparency change immediately is the whole
    /// point of a slider like this. Floored at 0.2 rather than 0 in the settings UI — fully
    /// invisible-but-still-there isn't a state this slider is meant to reach (that's what
    /// closing/hiding the panel is for).
    @Published var panelOpacity: Double {
        didSet { UserDefaults.standard.set(panelOpacity, forKey: Keys.panelOpacity) }
    }
    /// Shows/hides the PiP-lyrics toggle button (PiPVideoLayerView.updateLyricsToggleButton) for
    /// sessions whose source app is a known music app — read live, not just at panel-creation
    /// time, so turning this off immediately hides the button on already-open panels too, the
    /// same way a user would expect a plain visibility toggle to behave.
    @Published var panelLyricsEnabled: Bool {
        didSet { UserDefaults.standard.set(panelLyricsEnabled, forKey: Keys.panelLyricsEnabled) }
    }
    /// Read live by PiPVideoLayerView (from layout(), and at the top of every drag-gesture method
    /// that would otherwise engage CloseDropZoneOverlay) rather than cached at panel-creation time
    /// — same "a plain mode switch should take effect immediately" reasoning as panelLyricsEnabled.
    @Published var panelCloseMethod: PiPCloseMethod {
        didSet { UserDefaults.standard.set(panelCloseMethod.rawValue, forKey: Keys.panelCloseMethod) }
    }
    @Published var pipActivationMethod: PiPActivationMethod {
        didSet { UserDefaults.standard.set(pipActivationMethod.rawValue, forKey: Keys.pipActivationMethod) }
    }
    /// The global shortcut GlobalHotkeyManager watches for to trigger PiPSessionManager.
    /// stackAllSessions — nil means no shortcut is registered (the monitor still runs, matching
    /// every keyDown against nothing, cheap enough not to bother tearing it down over). Stored as
    /// two flat UserDefaults values rather than an archived GlobalShortcut, consistent with
    /// every other setting here being a plain value rather than a nested encoded object.
    @Published var stackShortcut: GlobalShortcut? {
        didSet {
            if let stackShortcut {
                UserDefaults.standard.set(Int(stackShortcut.keyCode), forKey: Keys.stackShortcutKeyCode)
                UserDefaults.standard.set(stackShortcut.modifierFlags.rawValue, forKey: Keys.stackShortcutModifiers)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.stackShortcutKeyCode)
                UserDefaults.standard.removeObject(forKey: Keys.stackShortcutModifiers)
            }
        }
    }
    /// Triggers PiPSessionManager.stopAll() — closes every open PiP session at once.
    @Published var closeAllShortcut: GlobalShortcut? {
        didSet {
            if let closeAllShortcut {
                UserDefaults.standard.set(Int(closeAllShortcut.keyCode), forKey: Keys.closeAllShortcutKeyCode)
                UserDefaults.standard.set(closeAllShortcut.modifierFlags.rawValue, forKey: Keys.closeAllShortcutModifiers)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.closeAllShortcutKeyCode)
                UserDefaults.standard.removeObject(forKey: Keys.closeAllShortcutModifiers)
            }
        }
    }
    /// Triggers PiPSessionManager.pipAllEligibleWindows() — turns every non-fullscreen, not
    /// already-PiP'd window into a PiP session and gathers the result into the overlapping stack.
    @Published var pipAllShortcut: GlobalShortcut? {
        didSet {
            if let pipAllShortcut {
                UserDefaults.standard.set(Int(pipAllShortcut.keyCode), forKey: Keys.pipAllShortcutKeyCode)
                UserDefaults.standard.set(pipAllShortcut.modifierFlags.rawValue, forKey: Keys.pipAllShortcutModifiers)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.pipAllShortcutKeyCode)
                UserDefaults.standard.removeObject(forKey: Keys.pipAllShortcutModifiers)
            }
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        targetFPS = defaults.object(forKey: Keys.targetFPS) as? Int ?? 15
        virtualDisplayLongEdge = defaults.object(forKey: Keys.virtualDisplayLongEdge) as? Double ?? Double(VirtualDisplayHost.maxPixelsWide)
        captureOutputLongEdge = defaults.object(forKey: Keys.captureOutputLongEdge) as? Double ?? 1280
        // Off by default: returning focus to whatever was frontmost before after a mere few
        // seconds of idle directly undermines treating the PiP as a continuously operable
        // window — any pause to read/think/move the mouse felt like the window "losing focus".
        autoReturnEnabled = defaults.object(forKey: Keys.autoReturnEnabled) as? Bool ?? false
        autoReturnIdleInterval = defaults.object(forKey: Keys.autoReturnIdleInterval) as? Double ?? 1.5
        autoStackOnIdleEnabled = defaults.object(forKey: Keys.autoStackOnIdleEnabled) as? Bool ?? false
        autoStackIdleInterval = defaults.object(forKey: Keys.autoStackIdleInterval) as? Double ?? 60
        autoHideWhenSourceActive = defaults.object(forKey: Keys.autoHideWhenSourceActive) as? Bool ?? true
        hasCompletedWelcome = defaults.object(forKey: Keys.hasCompletedWelcome) as? Bool ?? false
        defaultPanelWidth = defaults.object(forKey: Keys.defaultPanelWidth) as? Double ?? 340
        if let raw = defaults.string(forKey: Keys.defaultStackingCorner), let corner = PanelCorner(rawValue: raw) {
            defaultStackingCorner = corner
        } else {
            // Matches the behavior PiPSessionManager.defaultPanelFrame hardcoded before this
            // setting existed — always top-right, stacking downward.
            defaultStackingCorner = .topRight
        }
        panelCornerRadius = defaults.object(forKey: Keys.panelCornerRadius) as? Double ?? 12
        panelShadowEnabled = defaults.object(forKey: Keys.panelShadowEnabled) as? Bool ?? true
        edgeHandleColorHex = defaults.string(forKey: Keys.edgeHandleColorHex) ?? "FFFFFF"
        edgeHandleWidth = defaults.object(forKey: Keys.edgeHandleWidth) as? Double ?? 10
        edgeHandleHeight = defaults.object(forKey: Keys.edgeHandleHeight) as? Double ?? 64
        stackCascadeStep = defaults.object(forKey: Keys.stackCascadeStep) as? Double ?? 14
        stackCascadeMargin = defaults.object(forKey: Keys.stackCascadeMargin) as? Double ?? 24
        stackMaxVisibleDepth = defaults.object(forKey: Keys.stackMaxVisibleDepth) as? Double ?? 5
        panelAppearRippleEnabled = defaults.object(forKey: Keys.panelAppearRippleEnabled) as? Bool ?? true
        panelBackgroundColorHex = defaults.string(forKey: Keys.panelBackgroundColorHex) ?? "000000"
        if let raw = defaults.string(forKey: Keys.panelBorderStyle), let style = PanelBorderStyle(rawValue: raw) {
            panelBorderStyle = style
        } else {
            panelBorderStyle = .none
        }
        panelBorderColorHex = defaults.string(forKey: Keys.panelBorderColorHex) ?? "FFFFFF"
        panelBorderGradientEndColorHex = defaults.string(forKey: Keys.panelBorderGradientEndColorHex) ?? "0A84FF"
        panelBorderWidth = defaults.object(forKey: Keys.panelBorderWidth) as? Double ?? 2
        panelTitleEnabled = defaults.object(forKey: Keys.panelTitleEnabled) as? Bool ?? false
        panelOpacity = defaults.object(forKey: Keys.panelOpacity) as? Double ?? 1.0
        panelLyricsEnabled = defaults.object(forKey: Keys.panelLyricsEnabled) as? Bool ?? true
        if let raw = defaults.string(forKey: Keys.panelCloseMethod), let method = PiPCloseMethod(rawValue: raw) {
            panelCloseMethod = method
        } else {
            panelCloseMethod = .dragToZone
        }
        if let raw = defaults.string(forKey: Keys.pipActivationMethod), let method = PiPActivationMethod(rawValue: raw) {
            pipActivationMethod = method
        } else {
            pipActivationMethod = .cornerSwitch
        }
        if let keyCode = defaults.object(forKey: Keys.stackShortcutKeyCode) as? Int {
            let modifiers = defaults.object(forKey: Keys.stackShortcutModifiers) as? UInt ?? 0
            stackShortcut = GlobalShortcut(keyCode: UInt16(keyCode), modifierFlags: NSEvent.ModifierFlags(rawValue: modifiers))
        } else {
            // ⌥⌘S ("stack") — chosen to avoid the handful of ⌘-only/⌘⇧ combinations macOS or
            // common apps already claim system-wide; unset entirely (nil) once the user records
            // something else, or clears it via the settings UI.
            stackShortcut = GlobalShortcut(keyCode: 1, modifierFlags: [.option, .command])
        }
        if let keyCode = defaults.object(forKey: Keys.closeAllShortcutKeyCode) as? Int {
            let modifiers = defaults.object(forKey: Keys.closeAllShortcutModifiers) as? UInt ?? 0
            closeAllShortcut = GlobalShortcut(keyCode: UInt16(keyCode), modifierFlags: NSEvent.ModifierFlags(rawValue: modifiers))
        } else {
            closeAllShortcut = GlobalShortcut(keyCode: 13, modifierFlags: [.option, .command]) // ⌥⌘W
        }
        if let keyCode = defaults.object(forKey: Keys.pipAllShortcutKeyCode) as? Int {
            let modifiers = defaults.object(forKey: Keys.pipAllShortcutModifiers) as? UInt ?? 0
            pipAllShortcut = GlobalShortcut(keyCode: UInt16(keyCode), modifierFlags: NSEvent.ModifierFlags(rawValue: modifiers))
        } else {
            pipAllShortcut = GlobalShortcut(keyCode: 35, modifierFlags: [.option, .command]) // ⌥⌘P
        }
    }

    /// Resets every user-facing setting back to the same literal defaults `private init()` falls
    /// back to when UserDefaults has never held a value for that key — must be kept in sync with
    /// those by hand, since there's no single shared source of truth for "the default" beyond the
    /// two places that already spell it out (this and init()).
    ///
    /// Deliberately leaves two things untouched:
    ///  - hasCompletedWelcome: an internal onboarding flag, never exposed anywhere in the settings
    ///    UI — resetting it would just unexpectedly resurface the first-launch welcome window
    ///    rather than reset anything the user actually configured.
    ///  - Launch-at-login (LaunchAtLoginManager, not a SettingsStore property at all): its own doc
    ///    comment already explains why it's deliberately kept separate from the rest of these pure
    ///    app-local preferences — it's a real OS-level login-item registration, not a cached
    ///    preference, so silently unregistering it as a side effect of "reset settings" would undo
    ///    a system integration the user may have deliberately set up, not just an in-app default.
    func resetToDefaults() {
        targetFPS = 15
        virtualDisplayLongEdge = Double(VirtualDisplayHost.maxPixelsWide)
        captureOutputLongEdge = 1280
        autoReturnEnabled = false
        autoReturnIdleInterval = 1.5
        autoStackOnIdleEnabled = false
        autoStackIdleInterval = 60
        autoHideWhenSourceActive = true
        defaultPanelWidth = 340
        defaultStackingCorner = .topRight
        panelCornerRadius = 12
        panelShadowEnabled = true
        edgeHandleColorHex = "FFFFFF"
        edgeHandleWidth = 10
        edgeHandleHeight = 64
        stackCascadeStep = 14
        stackCascadeMargin = 24
        stackMaxVisibleDepth = 5
        panelAppearRippleEnabled = true
        panelBackgroundColorHex = "000000"
        panelBorderStyle = .none
        panelBorderColorHex = "FFFFFF"
        panelBorderGradientEndColorHex = "0A84FF"
        panelBorderWidth = 2
        panelTitleEnabled = false
        panelOpacity = 1.0
        panelLyricsEnabled = true
        panelCloseMethod = .dragToZone
        pipActivationMethod = .cornerSwitch
        stackShortcut = GlobalShortcut(keyCode: 1, modifierFlags: [.option, .command])
        closeAllShortcut = GlobalShortcut(keyCode: 13, modifierFlags: [.option, .command])
        pipAllShortcut = GlobalShortcut(keyCode: 35, modifierFlags: [.option, .command])
    }
}
