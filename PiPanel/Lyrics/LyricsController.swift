import Foundation

@MainActor
protocol LyricsControllerDelegate: AnyObject {
    /// A new lyric set was loaded for a new track — called once per track change (empty array if
    /// the track changed but no source had a match), not on every playback-progress tick.
    func lyricsController(_ controller: LyricsController, didLoadLines lines: [LyricLine])
    /// The line that should be highlighted right now changed — nil if nothing is currently active
    /// (before the first line, or no lyrics loaded at all).
    func lyricsController(_ controller: LyricsController, didUpdateHighlightedIndex index: Int?)
}

/// Per-session lyrics orchestration: watches the now-playing track (fed in via update(with:) —
/// PiPPanelController forwards NowPlayingMonitor updates here once they're confirmed to belong to
/// this session's own source app), fetches line-timed lyrics for it by trying each LyricsSource
/// in order until one has a match, and drives which line should be highlighted right now using
/// NowPlayingInfo's own elapsed-time extrapolation (see that type's own doc comment for why the
/// extrapolation exists — the underlying MediaRemote stream only reports a fresh sample on
/// meaningful change, not continuously, so smooth scrolling needs to interpolate locally between
/// samples via a timer rather than only ever updating on a fresh one).
@MainActor
final class LyricsController {
    weak var delegate: LyricsControllerDelegate?

    private let sources: [LyricsSource] = [QQMusicLyricsSource(), NetEaseLyricsSource()]
    private var lines: [LyricLine] = []
    private var currentTrackKey: String?
    private var fetchTask: Task<Void, Never>?
    private var highlightTimer: Timer?
    private var latestInfo: NowPlayingInfo?

    init() {
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateHighlight()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        highlightTimer = timer
    }

    deinit {
        highlightTimer?.invalidate()
        fetchTask?.cancel()
    }

    func update(with info: NowPlayingInfo) {
        latestInfo = info
        let trackKey = [info.title, info.artist].compactMap { $0 }.joined(separator: "|")
        guard !trackKey.isEmpty, trackKey != currentTrackKey else {
            updateHighlight()
            return
        }
        currentTrackKey = trackKey
        lines = []
        delegate?.lyricsController(self, didLoadLines: [])
        delegate?.lyricsController(self, didUpdateHighlightedIndex: nil)

        fetchTask?.cancel()
        guard let title = info.title else { return }
        let artist = info.artist
        let sources = self.sources
        fetchTask = Task { [weak self] in
            for source in sources {
                guard !Task.isCancelled else { return }
                guard let found = try? await source.fetchLyrics(title: title, artist: artist), !found.isEmpty else {
                    continue
                }
                guard !Task.isCancelled, let self, trackKey == self.currentTrackKey else { return }
                self.lines = found
                self.delegate?.lyricsController(self, didLoadLines: found)
                self.updateHighlight()
                return
            }
        }
    }

    private func updateHighlight() {
        guard !lines.isEmpty, let elapsed = latestInfo?.estimatedElapsedTime() else {
            delegate?.lyricsController(self, didUpdateHighlightedIndex: nil)
            return
        }
        var index: Int?
        for (lineIndex, line) in lines.enumerated() where line.timestamp <= elapsed {
            index = lineIndex
        }
        delegate?.lyricsController(self, didUpdateHighlightedIndex: index)
    }
}
