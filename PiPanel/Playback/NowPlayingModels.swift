import Foundation

/// One snapshot of the system's "now playing" state, as reported by the bundled
/// mediaremote-adapter helper (see Playback/MediaRemoteAdapter/ for what that is and why it's
/// needed — Apple's MediaRemote framework has required a special entitlement for direct
/// in-process access since macOS 15.4; this works around that by spawning /usr/bin/perl, a
/// system binary Apple already grants that entitlement to, to load the adapter framework
/// instead of loading it directly into PiPanel's own process).
struct NowPlayingInfo: Equatable {
    var bundleIdentifier: String?
    var title: String?
    var artist: String?
    var album: String?
    var playing: Bool?
    var duration: Double?
    var elapsedTime: Double?
    var timestamp: Date?
    var artworkData: Data?

    /// A best-effort estimate of the current playback position, extrapolated from
    /// (elapsedTime, timestamp) — the adapter only emits a fresh sample when something actually
    /// changes (track/seek/play-pause), not continuously, so anything driving a live progress UI
    /// (such as a progress display) needs to extrapolate between samples itself rather than only ever
    /// updating on a fresh sample.
    func estimatedElapsedTime(at now: Date = Date()) -> Double? {
        guard let elapsedTime else { return nil }
        guard playing == true, let timestamp else { return elapsedTime }
        return elapsedTime + now.timeIntervalSince(timestamp)
    }
}
