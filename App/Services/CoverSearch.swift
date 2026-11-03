import Foundation

/// A cover found online.
struct CoverCandidate: Identifiable, Hashable, Sendable {
    let id: String
    /// "Apple Music", "Deezer" or "MusicBrainz".
    let source: String
    let title: String
    let artist: String
    let thumbnailURL: URL
    let fullURL: URL
    /// How well title and artist match what was searched for (higher is better).
    let score: Int
}

/// Album and song covers from Apple Music (iTunes Search), Deezer and MusicBrainz's Cover Art
/// Archive: the fallback when Apple has none, and the choices in "Find Cover Online…".
/// All three are keyless public APIs.
enum CoverSearch {
    enum Kind: Sendable {
        case album
        case song
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 25
        return URLSession(configuration: configuration)
    }()

    /// Up to `limit` covers from all sources, best matches first.
    static func search(artist: String, title: String, kind: Kind, limit: Int = 5) async -> [CoverCandidate] {
        async let appleResults = itunes(artist: artist, title: title, kind: kind)
        async let deezerResults = deezer(artist: artist, title: title, kind: kind)
        async let brainzResults = musicBrainz(artist: artist, title: title, kind: kind)
        let all = await appleResults + deezerResults + brainzResults
        var seen = Set<URL>()
        let unique = all.filter { seen.insert($0.fullURL).inserted }
        // Best score first; on a tie, keep the source order (Apple, Deezer, MusicBrainz).
        let ranked = unique.enumerated().sorted { lhs, rhs in
            lhs.element.score != rhs.element.score ? lhs.element.score > rhs.element.score : lhs.offset < rhs.offset
        }
        return Array(ranked.map(\.element).prefix(limit))
    }

    /// The cover of a confident match (same title and artist) from Deezer or MusicBrainz, for
    /// when Apple has none. nil when nothing matches well enough to use without asking.
    static func fallbackCover(artist: String, title: String, kind: Kind) async -> Data? {
        let fromDeezer = await deezer(artist: artist, title: title, kind: kind)
        let fromBrainz = await musicBrainz(artist: artist, title: title, kind: kind)
        let found = fromDeezer + fromBrainz
        for candidate in found.sorted(by: { $0.score > $1.score }) where candidate.score >= confidentScore {
            if let data = await download(candidate.fullURL) { return data }
        }
        return nil
    }

    static func download(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.setValue(HTTP.userAgent, forHTTPHeaderField: "User-Agent")
        guard let reply = try? await session.data(for: request),
              (reply.1 as? HTTPURLResponse)?.statusCode == 200, reply.0.count > 1000 else { return nil }
        return reply.0
    }

    // MARK: Matching

    /// Title equal and artist overlapping.
    private static let confidentScore = 5

    private static func score(title: String, artist: String, wantedTitle: String, wantedArtist: String) -> Int {
        var score = 0
        let found = TrackMatcher.normalizeTitle(title)
        let wanted = TrackMatcher.normalizeTitle(wantedTitle)
        if !wanted.isEmpty {
            if found == wanted {
                score += 3
            } else if found.contains(wanted) || wanted.contains(found) {
                score += 1
            }
        }
        if !wantedArtist.isEmpty,
           TrackMatcher.artistsOverlap(TrackMatcher.artistKeys(artist), TrackMatcher.artistKeys(wantedArtist)) {
            score += 2
        }
        return score
    }

    private static func json(_ url: URL) async -> Any? {
        var request = URLRequest(url: url)
        request.setValue(HTTP.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let reply = try? await session.data(for: request),
              (reply.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: reply.0)
    }

    // MARK: Sources

    private static func itunes(artist: String, title: String, kind: Kind) async -> [CoverCandidate] {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: "\(artist) \(title)"),
            URLQueryItem(name: "entity", value: kind == .album ? "album" : "song"),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "limit", value: "8"),
        ]
        guard let url = components.url, let json = await json(url) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { result -> CoverCandidate? in
            guard let small = result["artworkUrl100"] as? String,
                  let thumbnail = URL(string: small.replacingOccurrences(of: "100x100bb", with: "300x300bb")),
                  let full = URL(string: small.replacingOccurrences(of: "100x100bb", with: "1200x1200bb")) else { return nil }
            let name = (kind == .album ? result["collectionName"] : result["trackName"]) as? String ?? ""
            let by = result["artistName"] as? String ?? ""
            return CoverCandidate(id: "itunes-" + full.absoluteString, source: "Apple Music", title: name, artist: by,
                                  thumbnailURL: thumbnail, fullURL: full,
                                  score: score(title: name, artist: by, wantedTitle: title, wantedArtist: artist))
        }
    }

    private static func deezer(artist: String, title: String, kind: Kind) async -> [CoverCandidate] {
        var components = URLComponents(string: kind == .album ? "https://api.deezer.com/search/album" : "https://api.deezer.com/search/track")!
        let field = kind == .album ? "album" : "track"
        let quoted = { (text: String) in text.replacingOccurrences(of: "\"", with: "") }
        components.queryItems = [
            URLQueryItem(name: "q", value: "artist:\"\(quoted(artist))\" \(field):\"\(quoted(title))\""),
            URLQueryItem(name: "limit", value: "8"),
        ]
        guard let url = components.url, let json = await json(url) as? [String: Any],
              let results = json["data"] as? [[String: Any]] else { return [] }
        return results.compactMap { result -> CoverCandidate? in
            // Songs carry their album's cover.
            let holder = kind == .album ? result : (result["album"] as? [String: Any] ?? [:])
            guard let medium = holder["cover_medium"] as? String, let thumbnail = URL(string: medium),
                  let big = holder["cover_xl"] as? String, let full = URL(string: big) else { return nil }
            let name = result["title"] as? String ?? ""
            let by = (result["artist"] as? [String: Any])?["name"] as? String ?? ""
            return CoverCandidate(id: "deezer-" + big, source: "Deezer", title: name, artist: by,
                                  thumbnailURL: thumbnail, fullURL: full,
                                  score: score(title: name, artist: by, wantedTitle: title, wantedArtist: artist))
        }
    }

    /// Release groups (albums) on MusicBrainz that have a front cover in the Cover Art Archive.
    private static func musicBrainz(artist: String, title: String, kind: Kind) async -> [CoverCandidate] {
        guard kind == .album else { return [] }
        let escape = { (text: String) in text.replacingOccurrences(of: "\"", with: "") }
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/release-group/")!
        components.queryItems = [
            URLQueryItem(name: "query", value: "releasegroup:\"\(escape(title))\" AND artist:\"\(escape(artist))\""),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "5"),
        ]
        guard let url = components.url, let json = await json(url) as? [String: Any],
              let groups = json["release-groups"] as? [[String: Any]] else { return [] }
        var found: [CoverCandidate] = []
        for group in groups.prefix(4) {
            guard let id = group["id"] as? String,
                  let thumbnail = URL(string: "https://coverartarchive.org/release-group/\(id)/front-250"),
                  let full = URL(string: "https://coverartarchive.org/release-group/\(id)/front-1200") else { continue }
            // Most release groups have no cover; ask before offering one.
            guard await exists(thumbnail) else { continue }
            let name = group["title"] as? String ?? ""
            let credits = group["artist-credit"] as? [[String: Any]] ?? []
            let by = credits.compactMap { $0["name"] as? String }.joined(separator: ", ")
            found.append(CoverCandidate(id: "caa-" + id, source: "MusicBrainz", title: name, artist: by,
                                        thumbnailURL: thumbnail, fullURL: full,
                                        score: score(title: name, artist: by, wantedTitle: title, wantedArtist: artist)))
        }
        return found
    }

    private static func exists(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue(HTTP.userAgent, forHTTPHeaderField: "User-Agent")
        guard let reply = try? await session.data(for: request) else { return false }
        return (reply.1 as? HTTPURLResponse)?.statusCode == 200
    }
}
