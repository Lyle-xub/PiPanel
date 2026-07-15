import CoreGraphics
import Foundation

/// Polls the system's HID+software idle time on a repeating timer and fires once accumulated idle
/// time first crosses a configurable threshold — used by PiPSessionManager to auto-stack every open
/// PiP session after a long period of no activity anywhere on the system, not just within a PiP
/// panel.
///
/// Deliberately not a global NSEvent monitor, the pattern used elsewhere in Interaction/
/// (GlobalHotkeyManager, WindowFlingDetector, InteractionForwarder's cursor-capture tracking): a
/// monitor only fires on each new event, which is the wrong shape for "how long has NOTHING
/// happened" — it'd mean hand-rolling a reset-on-every-event Timer across every event type worth
/// watching. CGEventSource's own idle-time accessor already tracks that natively and system-wide
/// via a single call, with no monitor to register or tear down.
///
/// Uses .combinedSessionState (hardware input *and* events this process itself posts) rather than
/// .hidSystemState (hardware only): InteractionForwarder forwards keystrokes/clicks into the source
/// app by synthesizing CGEvents (KeyboardEventForwarder.post), and cursor-capture moves the real
/// hardware cursor onto the virtual display — both should count as "the user is actively using
/// this PiP", so a forwarded keystroke must reset the idle clock the same as a physical one would.
///
/// See anyInputEventType's own doc comment for a real bug this already went through: the eventType
/// argument has to be the kCGAnyInputEventType wildcard, not CGEventType.null (a same-shaped but
/// entirely different constant) — confirmed by directly polling both on this machine.
final class GlobalIdleMonitor {
    private var timer: Timer?
    /// Tracks whether the current idle stretch has already fired, so onIdleThresholdReached is
    /// called exactly once per idle period (not on every poll tick while remaining idle) — cleared
    /// the moment activity brings idle time back under the threshold, so the *next* idle period can
    /// fire again.
    private var hasFiredForCurrentIdlePeriod = false
    var onIdleThresholdReached: (() -> Void)?

    private static let pollInterval: TimeInterval = 1.0

    /// The C constant kCGAnyInputEventType (0xFFFFFFFF) — "return the time since the last event of
    /// *any* type," per CGEventSourceSecondsSinceLastEventType's own documentation. Not exposed as
    /// a named case on Swift's CGEventType (unlike kCGEventNull, which *is* — as `.null` — and is a
    /// completely different constant: the "no event" placeholder, not a wildcard). Passing `.null`
    /// here was tried first and is a real, confirmed-by-testing bug: CGEventSourceSecondsSinceLastEventType
    /// with eventType .null never matches any event macOS actually dispatches, so it doesn't track
    /// idle time at all — it returns a huge, monotonically-increasing number (empirically, something
    /// close to system uptime) that's already far past any sane threshold from the very first poll,
    /// and never decreases no matter how much real input follows. That fired this monitor exactly
    /// once, near-instantly, the moment it was ever started — then never again, since
    /// hasFiredForCurrentIdlePeriod's reset condition (idle time dropping back under the threshold)
    /// could never become true afterward.
    private static let anyInputEventType = CGEventType(rawValue: 0xFFFFFFFF)!

    /// thresholdProvider is called fresh on every poll tick, not captured once at start(_:) time —
    /// so a live change to the configured idle duration (dragging Settings' slider while already
    /// running) takes effect on the very next tick, with no need to restart the monitor.
    func start(thresholdProvider: @escaping () -> TimeInterval) {
        stop()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.poll(threshold: thresholdProvider())
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        hasFiredForCurrentIdlePeriod = false
    }

    private func poll(threshold: TimeInterval) {
        let idleSeconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: Self.anyInputEventType)
        guard idleSeconds >= threshold else {
            hasFiredForCurrentIdlePeriod = false
            return
        }
        guard !hasFiredForCurrentIdlePeriod else { return }
        hasFiredForCurrentIdlePeriod = true
        debugTrace("idle: threshold reached idleSeconds=\(idleSeconds) threshold=\(threshold), firing onIdleThresholdReached")
        onIdleThresholdReached?()
    }
}
