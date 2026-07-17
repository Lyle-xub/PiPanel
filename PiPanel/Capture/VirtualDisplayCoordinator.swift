/// Serializes every operation that can mutate or react to the process-wide display topology:
/// pool warm-up/overflow creation, virtual-display mode changes, exceptional slot teardown, and
/// existing-session re-anchoring. Ordinary PiP open/close now only leases/returns a stable host.
///
/// Stress testing found that starting topology operations back-to-back (for example, opening a
/// new capture while a previous cleanup was still finishing) could leave the source window never
/// actually moved onto its virtual display — its capture stream ran
/// against an empty virtual desktop while the real window stayed put at its original screen
/// position. The prime suspect: CGBeginDisplayConfiguration/CGCompleteDisplayConfiguration
/// (VirtualDisplayHost's mirroring guard) are process-wide display-configuration transactions,
/// not scoped to a single display, so two in flight at once can step on each other.
///
/// Swift actors are reentrant at suspension points by default, so a plain `actor` guarding this
/// wouldn't actually stop a second `start()` from interleaving through its own awaits — this
/// needs a real async lock instead. Holding one shared lock across both the mutation and the
/// resulting re-anchor is also essential: CGVirtualDisplay.apply temporarily reflows existing
/// displays before PiPanel restores the intended arrangement, and a re-anchor that reads inside
/// that gap can put an old source window onto the newly-created display. The cost is that topology
/// operations queue rather than run in parallel; each is rare and correctness matters more.
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
