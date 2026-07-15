import Foundation

/// Searches and fetches lyrics from NetEase Cloud Music's own (unofficial, undocumented) web
/// endpoints — the second of the two sources LyricsController tries. Request/response shapes
/// below were verified directly against the live API while building this feature.
struct NetEaseLyricsSource: LyricsSource {
    enum ClientError: Error {
        case invalidResponse
    }

    private static let searchURL = URL(string: "https://music.163.com/api/search/get/web")!
    private static let lyricURL = URL(string: "https://music.163.com/api/song/lyric")!
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"

    func fetchLyrics(title: String, artist: String?) async throws -> [LyricLine]? {
        guard let songId = try await search(title: title, artist: artist) else { return nil }
        return try await fetchLyric(id: songId)
    }

    private func search(title: String, artist: String?) async throws -> Int? {
        let query = [title, artist].compactMap { $0 }.joined(separator: " ")
        var components = URLComponents(url: Self.searchURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "s", value: query),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "total", value: "true"),
            URLQueryItem(name: "limit", value: "5"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ClientError.invalidResponse
        }

        struct SearchResponse: Decodable {
            struct Result: Decodable {
                struct Song: Decodable { let id: Int }
                let songs: [Song]?
            }
            let result: Result
        }

        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        return decoded.result.songs?.first?.id
    }

    private func fetchLyric(id: Int) async throws -> [LyricLine]? {
        var components = URLComponents(url: Self.lyricURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "id", value: String(id)),
            URLQueryItem(name: "lv", value: "1"),
            URLQueryItem(name: "kv", value: "1"),
            URLQueryItem(name: "tv", value: "-1"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ClientError.invalidResponse
        }

        struct LyricResponse: Decodable {
            struct Lrc: Decodable { let lyric: String? }
            let lrc: Lrc?
        }
        let decoded = try JSONDecoder().decode(LyricResponse.self, from: data)
        guard let lrcText = decoded.lrc?.lyric else { return nil }

        let lines = LRCParser.parse(lrcText)
        return lines.isEmpty ? nil : lines
    }
}
