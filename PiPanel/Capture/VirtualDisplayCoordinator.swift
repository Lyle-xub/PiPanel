/// Serializes PiP session startup across concurrent sessions.
///
/// Multi-session testing (M4) found that starting two sessions back-to-back (e.g. picking a
/// second window from the picker while the first was still spinning up) could leave the
/// *second* window never actually moved onto its virtual display — its capture stream ran
/// against an empty virtual desktop while the real window stayed put at its original screen
/// position. The prime suspect: CGBeginDisplayConfiguration/CGCompleteDisplayConfiguration
/// (VirtualDisplayHost's mirroring guard) are process-wide display-configuration transactions,
/// not scoped to a single display, so two in flight at once can step on each other.
///
/// Swift actors are reentrant at suspension points by default, so a plain `actor` guarding this
/// wouldn't actually stop a second `start()` from interleaving through its own awaits — this
/// needs a real async lock instead, held for the whole startup sequence (CaptureSession.start).
/// The cost is that concurrent session starts queue up and run one at a time rather than in
/// parallel; each only takes a few seconds, and correctness matters more than shaving that off.
actor VirtualDisplayCoordinator {
    static let shared = VirtualDisplayCoordinator()

    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func unlock() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }
        let next = waiters.removeFirst()
        next.resume()
    }
}
