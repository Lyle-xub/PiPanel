import Foundation

/// Searches and fetches lyrics from QQ Music's own (unofficial, undocumented) web endpoints —
/// the same approach LDDC uses. Request/response shapes below were verified directly against the
/// live API while building this feature (both the search gateway and the lyric endpoint returned
/// real, correctly-shaped data for a live test track). Being unofficial and undocumented, these
/// can change without notice — that's exactly why this always sits ahead of NetEaseLyricsSource
/// as the first of two sources tried, not the only one.
struct QQMusicLyricsSource: LyricsSource {
    enum ClientError: Error {
        case invalidResponse
    }

    private static let searchURL = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!
    private static let lyricURL = URL(string: "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg")!
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"

    func fetchLyrics(title: String, artist: String?) async throws -> [LyricLine]? {
        guard let mid = try await search(title: title, artist: artist) else { return nil }
        return try await fetchLyric(mid: mid)
    }

    /// QQ Music's unified search gateway — a single JSON-RPC-style endpoint keyed by an arbitrary
    /// "req_1" request name, rather than a plain REST search route. Trusts the first result
    /// rather than scoring candidates against `artist` — search relevance ranking already does
    /// that server-side, and LyricsController falls back to NetEaseLyricsSource anyway if this
    /// picks badly.
    private func search(title: String, artist: String?) async throws -> String? {
        let query = [title, artist].compactMap { $0 }.joined(separator: " ")
        var request = URLRequest(url: Self.searchURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "req_1": [
                "method": "DoSearchForQQMusicDesktop",
                "module": "music.search.SearchCgiService",
                "param": [
                    "num_per_page": 5,
                    "page_num": 1,
                    "query": query,
                    "search_type": 0,
                ],
            ],
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ClientError.invalidResponse
        }

        struct SearchResponse: Decodable {
            struct Req1: Decodable {
                struct SongData: Decodable {
                    struct Body: Decodable {
                        struct Song: Decodable {
                            struct SongEntry: Decodable { let mid: String }
                            let list: [SongEntry]
                        }
                        let song: Song
                    }
                    let body: Body
                }
                let data: SongData
            }
            let req_1: Req1
        }

        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        return decoded.req_1.data.body.song.list.first?.mid
    }

    /// Requires the player-page Referer or the request is rejected — a known quirk of this
    /// specific endpoint (undocumented, but consistently reproducible).
    private func fetchLyric(mid: String) async throws -> [LyricLine]? {
        var components = URLComponents(url: Self.lyricURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "songmid", value: mid),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "nobase64", value: "0"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://y.qq.com/portal/player.html", forHTTPHeaderField: "Referer")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ClientError.invalidResponse
        }

        struct LyricResponse: Decodable { let lyric: String? }
        let decoded = try JSONDecoder().decode(LyricResponse.self, from: data)
        guard
            let base64 = decoded.lyric,
            let lyricData = Data(base64Encoded: base64),
            let lrcText = String(data: lyricData, encoding: .utf8)
        else { return nil }

        let lines = LRCParser.parse(lrcText)
        return lines.isEmpty ? nil : lines
    }
}
