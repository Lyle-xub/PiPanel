import Foundation
import Combine

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

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private enum Keys {
        static let targetFPS = "settings.targetFPS"
        static let autoReturnEnabled = "settings.autoReturnEnabled"
        static let autoReturnIdleInterval = "settings.autoReturnIdleInterval"
        static let autoHideWhenSourceActive = "settings.autoHideWhenSourceActive"
        static let hasCompletedWelcome = "settings.hasCompletedWelcome"
        static let defaultPanelWidth = "settings.defaultPanelWidth"
        static let defaultStackingCorner = "settings.defaultStackingCorner"
        static let panelCornerRadius = "settings.panelCornerRadius"
        static let panelShadowEnabled = "settings.panelShadowEnabled"
    }

    @Published var targetFPS: Int {
        didSet { UserDefaults.standard.set(targetFPS, forKey: Keys.targetFPS) }
    }
    @Published var autoReturnEnabled: Bool {
        didSet { UserDefaults.standard.set(autoReturnEnabled, forKey: Keys.autoReturnEnabled) }
    }
    @Published var autoReturnIdleInterval: Double {
        didSet { UserDefaults.standard.set(autoReturnIdleInterval, forKey: Keys.autoReturnIdleInterval) }
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

    private init() {
        let defaults = UserDefaults.standard
        targetFPS = defaults.object(forKey: Keys.targetFPS) as? Int ?? 15
        // Off by default: returning focus to whatever was frontmost before after a mere few
        // seconds of idle directly undermines treating the PiP as a continuously operable
        // window — any pause to read/think/move the mouse felt like the window "losing focus".
        autoReturnEnabled = defaults.object(forKey: Keys.autoReturnEnabled) as? Bool ?? false
        autoReturnIdleInterval = defaults.object(forKey: Keys.autoReturnIdleInterval) as? Double ?? 1.5
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
    }
}
