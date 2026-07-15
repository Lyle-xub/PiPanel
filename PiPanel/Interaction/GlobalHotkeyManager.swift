import AppKit

/// Watches system-wide for however many shortcuts PiPSessionManager registers (stack/unstack,
/// close all, PiP-all-and-stack) and fires the matching action when one's pressed. Follows the
/// same NSEvent.addGlobalMonitorForEvents pattern WindowFlingDetector already uses for its own
/// system-wide gesture; both quietly depend on Accessibility permission already being granted for
/// the app's core functionality (a *global* monitor for keyDown/keyUp specifically only ever
/// receives events once that's trusted — this doesn't check for it separately since there's
/// nothing more useful to do here if it's missing than just not firing, same as every other
/// AX-dependent path in the app).
///
/// A single persistent monitor serves every registered binding rather than one monitor per
/// shortcut — each binding's `shortcut` closure is re-read fresh on every keyDown (not cached at
/// registration time), so a binding whose underlying SettingsStore value changes, or is currently
/// nil (not configured), just keeps failing to match without needing to be re-registered.
@MainActor
final class GlobalHotkeyManager {
    struct Binding {
        let shortcut: () -> GlobalShortcut?
        let action: () -> Void
    }

    private var bindings: [Binding] = []
    private var keyDownMonitor: Any?

    /// `shortcut` is a closure rather than a fixed value specifically so it can point at a live
    /// SettingsStore property (e.g. `{ SettingsStore.shared.stackShortcut }`) — the binding then
    /// automatically tracks whatever the user has it set to right now, including nil (unconfigured,
    /// never matches).
    func register(shortcut: @escaping () -> GlobalShortcut?, action: @escaping () -> Void) {
        bindings.append(Binding(shortcut: shortcut, action: action))
    }

    func start() {
        guard keyDownMonitor == nil else { return }
        keyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
        }
    }

    func stop() {
        if let keyDownMonitor { NSEvent.removeMonitor(keyDownMonitor) }
        keyDownMonitor = nil
    }

    private func handleKeyDown(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(GlobalShortcut.relevantModifierMask)
        for binding in bindings {
            guard let shortcut = binding.shortcut(),
                  event.keyCode == shortcut.keyCode, flags == shortcut.modifierFlags else { continue }
            binding.action()
        }
    }
}
