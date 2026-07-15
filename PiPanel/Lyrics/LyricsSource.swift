/// A single online lyrics provider — LyricsController tries each configured source in order
/// (QQMusicLyricsSource, then NetEaseLyricsSource) until one returns a match, so a track missing
/// from one catalog can still be found via the other.
protocol LyricsSource {
    /// Searches for `title`/`artist` and returns its line-timed lyrics if found, or nil if this
    /// source simply has no match for the track — LyricsController treats nil as "try the next
    /// source" and reserves thrown errors for genuine network/decoding failures.
    func fetchLyrics(title: String, artist: String?) async throws -> [LyricLine]?
}
