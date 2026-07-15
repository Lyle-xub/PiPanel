import Foundation

/// Wraps the bundled mediaremote-adapter helper (Lyrics/MediaRemoteAdapter/, vendored from
/// https://github.com/ungive/mediaremote-adapter, BSD-3-Clause) to read system-wide "now playing"
/// information. Runs the adapter's `stream` command as a long-lived `/usr/bin/perl` subprocess and
/// republishes each JSON-per-line update as a merged NowPlayingInfo snapshot.
///
/// One shared instance for the whole app rather than one per PiP session — MediaRemote only ever
/// reports a single system-wide "now playing" app at a time, so running a separate helper
/// subprocess per session would just be redundant. Supports multiple simultaneous observers (two
/// or more PiP sessions can each be in lyrics mode at once, each caring about a different
/// bundle identifier) via addObserver/removeObserver rather than a single overwritable callback;
/// the helper subprocess itself only actually runs while at least one observer is registered.
@MainActor
final class NowPlayingMonitor {
    static let shared = NowPlayingMonitor()

    /// The MRCommand IDs the bundled adapter's `send` function accepts (see mediaremote-adapter.pl
    /// --help and https://github.com/ungive/mediaremote-adapter's own command table) — only the
    /// subset PiPMusicControlsBar's transport buttons actually need.
    ///
    /// "send" always targets whichever app is currently the system's one active "Now Playing"
    /// client, the same single system-wide target `stream`/`get` report on — there's no way to
    /// direct a command at a specific *other* app's playback, since MediaRemote itself has no
    /// concept of that. PiPPanelController only offers this to a music-app session on the
    /// reasonable assumption that its own source app is the one actually playing.
    enum Command: Int {
        case togglePlayPause = 2
        case nextTrack = 4
        case previousTrack = 5
    }

    private(set) var current: NowPlayingInfo?
    private var observers: [UUID: (NowPlayingInfo?) -> Void] = [:]

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var lineBuffer = Data()

    private init() {}

    /// One-shot fire-and-forget — unlike the long-lived `stream` subprocess this doesn't need a
    /// persistent Process reference or any output at all, so it's a fresh Process per call rather
    /// than something requiring lifecycle management.
    func send(_ command: Command) {
        guard let (scriptURL, frameworkURL) = Self.resolveAdapterPaths() else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptURL.path, frameworkURL.path, "send", String(command.rawValue)]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            PiPanelLogger.lyrics.error("NowPlayingMonitor: failed to send command \(command.rawValue): \(String(describing: error))")
        }
    }

    private static func resolveAdapterPaths() -> (script: URL, framework: URL)? {
        guard let resourcesRoot = Bundle.main.resourceURL?.appendingPathComponent("MediaRemoteAdapter") else {
            PiPanelLogger.lyrics.error("NowPlayingMonitor: could not resolve bundle resources URL")
            return nil
        }
        let scriptURL = resourcesRoot.appendingPathComponent("mediaremote-adapter.pl")
        let frameworkURL = resourcesRoot.appendingPathComponent("MediaRemoteAdapter.framework")
        guard FileManager.default.fileExists(atPath: scriptURL.path),
              FileManager.default.fileExists(atPath: frameworkURL.path) else {
            PiPanelLogger.lyrics.error("NowPlayingMonitor: bundled adapter resources not found at \(resourcesRoot.path)")
            return nil
        }
        return (scriptURL, frameworkURL)
    }

    /// Registers a handler for every future update and immediately delivers the current snapshot
    /// (possibly nil, if nothing is playing or the helper hasn't reported anything yet) so a late
    /// subscriber isn't stuck waiting for the next change. Returns a token to pass back to
    /// removeObserver once the caller (PiPPanelController.setLyricsMode(false)) no longer needs
    /// updates.
    @discardableResult
    func addObserver(_ handler: @escaping (NowPlayingInfo?) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        if process == nil { launchHelperProcess() }
        handler(current)
        return id
    }

    func removeObserver(_ id: UUID) {
        guard observers.removeValue(forKey: id) != nil else { return }
        guard observers.isEmpty else { return }
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        stdoutPipe = nil
        lineBuffer.removeAll()
        current = nil
    }

    private func launchHelperProcess() {
        guard let resourcesRoot = Bundle.main.resourceURL?.appendingPathComponent("MediaRemoteAdapter") else {
            PiPanelLogger.lyrics.error("NowPlayingMonitor: could not resolve bundle resources URL")
            return
        }
        let scriptURL = resourcesRoot.appendingPathComponent("mediaremote-adapter.pl")
        let frameworkURL = resourcesRoot.appendingPathComponent("MediaRemoteAdapter.framework")
        guard FileManager.default.fileExists(atPath: scriptURL.path),
              FileManager.default.fileExists(atPath: frameworkURL.path) else {
            PiPanelLogger.lyrics.error("NowPlayingMonitor: bundled adapter resources not found at \(resourcesRoot.path)")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptURL.path, frameworkURL.path, "stream", "--debounce=250"]

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe() // discarded — non-fatal per the adapter's own docs

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in
                self?.consume(data)
            }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.handleProcessTermination()
            }
        }

        do {
            try process.run()
            self.process = process
            self.stdoutPipe = outPipe
            debugTrace("lyrics: NowPlayingMonitor helper process started")
        } catch {
            PiPanelLogger.lyrics.error("NowPlayingMonitor: failed to launch adapter helper: \(String(describing: error))")
        }
    }

    /// The helper can die on its own (e.g. a future macOS update breaking MediaRemote access
    /// again, matching this whole project's own stated motivation) — if that happens while
    /// callers still want updates, this clears state so a later start() (the next lyrics-mode
    /// toggle) gets a clean relaunch attempt rather than silently doing nothing forever against a
    /// dead process reference.
    private func handleProcessTermination() {
        debugTrace("lyrics: NowPlayingMonitor helper process terminated")
        process = nil
        stdoutPipe = nil
        current = nil
        notifyObservers()
    }

    private func consume(_ data: Data) {
        lineBuffer.append(data)
        while let newlineIndex = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer[lineBuffer.startIndex..<newlineIndex]
            lineBuffer.removeSubrange(lineBuffer.startIndex...newlineIndex)
            guard !lineData.isEmpty else { continue }
            handle(Data(lineData))
        }
    }

    private func handle(_ lineData: Data) {
        guard
            let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
            let payload = json["payload"] as? [String: Any]
        else { return }
        let isDiff = json["diff"] as? Bool ?? false
        current = Self.merge(previous: isDiff ? current : nil, payload: payload)
        notifyObservers()
    }

    private func notifyObservers() {
        for handler in observers.values { handler(current) }
    }

    /// Non-diff payloads replace the previous snapshot entirely (a fresh `NowPlayingInfo()`);
    /// diff payloads only overwrite the keys actually present — see the adapter's own `stream`
    /// command documentation for this contract.
    private static func merge(previous: NowPlayingInfo?, payload: [String: Any]) -> NowPlayingInfo {
        var info = previous ?? NowPlayingInfo()
        if let value = payload["bundleIdentifier"] as? String { info.bundleIdentifier = value }
        if let value = payload["title"] as? String { info.title = value }
        if let value = payload["artist"] as? String { info.artist = value }
        if let value = payload["album"] as? String { info.album = value }
        if let value = payload["playing"] as? Bool { info.playing = value }
        if let value = payload["duration"] as? Double { info.duration = value }
        if let value = payload["elapsedTime"] as? Double { info.elapsedTime = value }
        if let value = payload["timestamp"] as? String {
            info.timestamp = ISO8601DateFormatter().date(from: value)
        }
        if let value = payload["artworkData"] as? String {
            info.artworkData = Data(base64Encoded: value)
        }
        return info
    }
}
