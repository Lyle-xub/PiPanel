import Foundation

/// Parses standard LRC lyric text (`[mm:ss.xx]lyric line`, possibly with multiple timestamp tags
/// on one line and metadata tags like `[ar:...]`/`[ti:...]` mixed in) into timed `LyricLine`
/// values, sorted by timestamp.
///
/// Line-level timing only — this is the v1 scope decided with the user: QQ Music's word-by-word
/// QRC format needs a separate decryption step (it's an encrypted format, not plain LRC) and
/// renders a karaoke-style sweep across each word rather than just highlighting a whole line;
/// that's deliberately left out for now as a documented future enhancement, not an oversight.
enum LRCParser {
    /// Matches "[mm:ss]", "[mm:ss.xx]" or "[mm:ss:xx]" — both '.' and ':' separators show up
    /// across different lyric sources in practice. Metadata tags like "[ar:Artist Name]" never
    /// match this (the content after the first colon isn't all digits), so they're naturally
    /// skipped without any special-casing.
    private static let timestampPattern = try! NSRegularExpression(
        pattern: #"\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]"#
    )

    static func parse(_ lrcText: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        for rawLine in lrcText.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let fullRange = NSRange(line.startIndex..., in: line)
            let matches = timestampPattern.matches(in: line, range: fullRange)
            guard !matches.isEmpty else { continue }

            let text = timestampPattern
                .stringByReplacingMatches(in: line, range: fullRange, withTemplate: "")
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            for match in matches {
                guard
                    let minutesRange = Range(match.range(at: 1), in: line),
                    let secondsRange = Range(match.range(at: 2), in: line),
                    let minutes = Int(line[minutesRange]),
                    let seconds = Int(line[secondsRange])
                else { continue }

                var fraction = 0.0
                if match.range(at: 3).location != NSNotFound,
                   let fractionRange = Range(match.range(at: 3), in: line) {
                    let fractionDigits = String(line[fractionRange])
                    if let value = Int(fractionDigits) {
                        fraction = Double(value) / pow(10, Double(fractionDigits.count))
                    }
                }

                let timestamp = Double(minutes) * 60 + Double(seconds) + fraction
                lines.append(LyricLine(timestamp: timestamp, text: text))
            }
        }
        return lines.sorted { $0.timestamp < $1.timestamp }
    }
}
