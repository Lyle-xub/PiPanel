import Foundation
import Combine

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private enum Keys {
        static let targetFPS = "settings.targetFPS"
        static let autoReturnEnabled = "settings.autoReturnEnabled"
        static let autoReturnIdleInterval = "settings.autoReturnIdleInterval"
        static let autoHideWhenSourceActive = "settings.autoHideWhenSourceActive"
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

    private init() {
        let defaults = UserDefaults.standard
        targetFPS = defaults.object(forKey: Keys.targetFPS) as? Int ?? 15
        // Off by default: returning focus to whatever was frontmost before after a mere few
        // seconds of idle directly undermines treating the PiP as a continuously operable
        // window — any pause to read/think/move the mouse felt like the window "losing focus".
        autoReturnEnabled = defaults.object(forKey: Keys.autoReturnEnabled) as? Bool ?? false
        autoReturnIdleInterval = defaults.object(forKey: Keys.autoReturnIdleInterval) as? Double ?? 1.5
        autoHideWhenSourceActive = defaults.object(forKey: Keys.autoHideWhenSourceActive) as? Bool ?? true
    }
}
