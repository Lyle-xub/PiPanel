import SwiftUI
import AppKit

/// A native AppKit-backed control, not a pure-SwiftUI one — SwiftUI's own key-event APIs
/// (.onKeyPress, .keyboardShortcut) can't reliably capture an arbitrary, possibly modifier-heavy
/// combination the way a "click to record, then press the combination" recorder needs to (the
/// same reason every third-party shortcut-recorder control, and System Settings' own, is built on
/// a first-responder NSView rather than SwiftUI gesture APIs). Click it, press a combination —
/// there's no separate "save" step; capturing a valid combination commits it immediately, same as
/// the recorders in System Settings > Keyboard > Shortcuts.
struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var shortcut: GlobalShortcut?

    func makeNSView(context: Context) -> ShortcutRecorderNSView {
        let view = ShortcutRecorderNSView()
        view.onCapture = { shortcut = $0 }
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderNSView, context: Context) {
        nsView.currentShortcut = shortcut
    }
}

final class ShortcutRecorderNSView: NSView {
    var onCapture: ((GlobalShortcut?) -> Void)?
    var currentShortcut: GlobalShortcut? {
        didSet { needsDisplay = true }
    }
    private var isRecording = false {
        didSet { needsDisplay = true }
    }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 108, height: 34) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
    }

    /// Esc alone cancels an in-progress recording without changing the stored shortcut — handled
    /// before the "must have a modifier" check below so it never gets misread as an attempt to
    /// record "Esc" itself as the shortcut.
    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 {
            isRecording = false
            window?.makeFirstResponder(nil)
            return
        }
        let flags = event.modifierFlags.intersection(GlobalShortcut.relevantModifierMask)
        // A global shortcut with no modifier at all would swallow that key everywhere, all the
        // time, for every app — not something this recorder should ever be able to produce, so a
        // bare keypress is simply ignored rather than committed; the user just presses a real
        // combination next.
        guard !flags.isEmpty else { return }
        let captured = GlobalShortcut(keyCode: event.keyCode, modifierFlags: flags)
        currentShortcut = captured
        onCapture?(captured)
        isRecording = false
        window?.makeFirstResponder(nil)
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9)
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let fillColor: NSColor
        if isRecording {
            fillColor = .controlAccentColor
        } else {
            // Using an alpha-adjusted semantic NSColor here can lose its alpha when AppKit
            // resolves the color inside SwiftUI's Form, producing an opaque black field.
            // Concrete appearance-aware colors keep the recorder consistent in both modes.
            fillColor = NSColor(calibratedWhite: isDark ? 0.18 : 0.95, alpha: 1)
        }
        fillColor.withAlphaComponent(isRecording ? 0.88 : 1).setFill()
        path.fill()

        if !isRecording {
            NSColor(calibratedWhite: isDark ? 1 : 0, alpha: isDark ? 0.10 : 0.07).setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }

        let text: String
        let textColor: NSColor
        if isRecording {
            text = "按下快捷键…"
            textColor = .white
        } else if let currentShortcut {
            text = currentShortcut.displayString
            textColor = .labelColor
        } else {
            text = "点击设置"
            textColor = .secondaryLabelColor
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: textColor
        ]
        let size = text.size(withAttributes: attributes)
        let origin = CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        text.draw(at: origin, withAttributes: attributes)
    }
}
