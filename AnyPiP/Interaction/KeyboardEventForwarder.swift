import AppKit
import CoreGraphics

/// Forwards a keyDown/keyUp NSEvent to another process via CGEvent.
///
/// Unlike mouse clicks, keyboard events are routed by the window server to whichever
/// application is currently key/frontmost — there is no coordinate-based targeting for
/// keystrokes. So forwarding a keystroke requires actually activating the target app first
/// (InteractionForwarder does this and handles returning focus afterward); this type only
/// knows how to replay the NSEvent's key code/modifiers/characters once that app is frontmost.
enum KeyboardEventForwarder {
    static func post(_ event: NSEvent) {
        guard let cgEvent = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(event.keyCode),
            keyDown: event.type == .keyDown
        ) else { return }
        cgEvent.flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
        cgEvent.post(tap: .cghidEventTap)
    }
}
