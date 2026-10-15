import Foundation
import SoulseekKit

/// Last.fm scrobbling. You need your own API account (last.fm/api/account/create): the key and
/// secret live in the Keychain, never in the repo.
@MainActor
final class LastFM: ObservableObject, Scrobbler {
    @Published private(set) var username: String?
    @Published private(set) var pendingCount = 0
    @Published private(set) var lastError: String?
    @Published private(set) var scrobbledThisSession = 0

    var isConnected: Bool { sessionKey != nil && apiKey != nil && apiSecret != nil }

    private static let service = "colon3.lastfm"
    private var apiKey: String? { Keychain.load(account: "apiKey", service: Self.service) }
    private var apiSecret: String? { Keychain.load(account: "apiSecret", service: Self.service) }
    private var sessionKey: String? { Keychain.load(account: "session", service: Self.service) }

    private struct PendingScrobble: Codable {
        let artist: String
        let track: String
        let album: String?
        let albumArtist: String?
        let duration: Int
        let timestamp: Int
    }

    private var pending: [PendingScrobble] = []
    private var isFlushing = false
    private let pendingURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("lastfm-pending.json")

    init() {
        username = UserDefaults.standard.string(forKey: "lastfm.username")
        if let data = try? Data(contentsOf: pendingURL), let stored = try? JSONDecoder().decode([PendingScrobble].self, from: data) {
            pending = stored
        }
        pendingCount = pending.count
    }

    // MARK: Account

    func connect(apiKey: String, apiSecret: String, username: String, password: String) async throws {
        let key = apiKey.trimmingCharacters(in: .whitespaces)
        let secret = apiSecret.trimmingCharacters(in: .whitespaces)
        let response = try await call(method: "auth.getMobileSession",
                                      parameters: ["username": username, "password": password],
                                      apiKey: key, apiSecret: secret, sessionKey: nil)
        guard let session = response["session"] as? [String: Any], let sessionKey = session["key"] as? String else {
            throw LastFMError.message("Last.fm didn't return a session")
        }
        Keychain.save(key, account: "apiKey", service: Self.service)
        Keychain.save(secret, account: "apiSecret", service: Self.service)
        Keychain.save(sessionKey, account: "session", service: Self.service)
        let name = session["name"] as? String ?? username
        UserDefaults.standard.set(name, forKey: "lastfm.username")
        self.username = name
        lastError = nil
        flush()
    }

    func disconnect() {
        for account in ["apiKey", "apiSecret", "session"] {
            Keychain.delete(account: account, service: Self.service)
        }
        UserDefaults.standard.removeObject(forKey: "lastfm.username")
        username = nil
    }

    // MARK: Scrobbler

    func nowPlaying(_ track: Track) {
        guard isConnected, AppSettings.scrobblingEnabled else { return }
        var parameters = ["artist": track.artist, "track": track.title, "duration": String(Int(track.duration))]
        if let album = track.album { parameters["album"] = album }
        Task {
            _ = try? await self.call(method: "track.updateNowPlaying", parameters: parameters)
        }
    }

    func scrobble(_ track: Track, startedAt: Date) {
        guard AppSettings.scrobblingEnabled else { return }
        pending.append(PendingScrobble(artist: track.artist, track: track.title, album: track.album,
                                       albumArtist: track.albumArtist, duration: Int(track.duration),
                                       timestamp: Int(startedAt.timeIntervalSince1970)))
        savePending()
        flush()
    }

    /// Sends queued scrobbles, 50 at a time (the API limit). Failed batches stay queued for later.
    func flush() {
        guard isConnected, !isFlushing, !pending.isEmpty else { return }
        isFlushing = true
        let batch = Array(pending.prefix(50))
        var parameters: [String: String] = [:]
        for (index, item) in batch.enumerated() {
            parameters["artist[\(index)]"] = item.artist
            parameters["track[\(index)]"] = item.track
            parameters["timestamp[\(index)]"] = String(item.timestamp)
            parameters["duration[\(index)]"] = String(item.duration)
            if let album = item.album { parameters["album[\(index)]"] = album }
            if let albumArtist = item.albumArtist { parameters["albumArtist[\(index)]"] = albumArtist }
        }
        Task {
            do {
                _ = try await self.call(method: "track.scrobble", parameters: parameters)
                self.pending.removeFirst(min(batch.count, self.pending.count))
                self.scrobbledThisSession += batch.count
                self.lastError = nil
                self.savePending()
                self.isFlushing = false
                self.flush()  // next batch, if any
            } catch {
                self.lastError = error.localizedDescription
                self.isFlushing = false
            }
        }
    }

    private func savePending() {
        pendingCount = pending.count
        if let data = try? JSONEncoder().encode(pending) {
            try? data.write(to: pendingURL, options: .atomic)
        }
    }

    // MARK: API

    enum LastFMError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self {
            case let .message(text): return text
            }
        }
    }

    private func call(method: String, parameters: [String: String]) async throws -> [String: Any] {
        guard let apiKey, let apiSecret, let sessionKey else { throw LastFMError.message("Not connected to Last.fm") }
        return try await call(method: method, parameters: parameters, apiKey: apiKey, apiSecret: apiSecret, sessionKey: sessionKey)
    }

    private func call(method: String, parameters: [String: String], apiKey: String, apiSecret: String,
                      sessionKey: String?) async throws -> [String: Any] {
        var all = parameters
        all["method"] = method
        all["api_key"] = apiKey
        if let sessionKey { all["sk"] = sessionKey }
        // Signature: every parameter except "format", sorted by name, as name+value, then the secret, MD5'd.
        let signatureBase = all.keys.sorted().map { $0 + all[$0]! }.joined() + apiSecret
        all["api_sig"] = MD5.hex(signatureBase)
        all["format"] = "json"

        var request = URLRequest(url: URL(string: "https://ws.audioscrobbler.com/2.0/")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(HTTP.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = HTTP.formBody(all)
        request.timeoutInterval = 20

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LastFMError.message("Unexpected reply from Last.fm")
        }
        if let message = json["message"] as? String, json["error"] != nil {
            throw LastFMError.message(message)
        }
        return json
    }
}

// MARK: - Similar tracks and artists (autoplay)

struct LastFMSimilarTrack {
    let title: String
    let artist: String
    let match: Double
}

struct LastFMSimilarArtist {
    let name: String
    let match: Double
}

extension LastFM {
    /// The saved API key. track.getSimilar and artist.getSimilar only need this, not a session.
    static var publicAPIKey: String? {
        guard let key = Keychain.load(account: "apiKey", service: service), !key.isEmpty else { return nil }
        return key
    }

    static func similarTracks(artist: String, track: String, apiKey: String) async throws -> [LastFMSimilarTrack] {
        let json = try await publicCall(method: "track.getSimilar",
                                        parameters: ["artist": artist, "track": track, "limit": "100", "autocorrect": "1"],
                                        apiKey: apiKey)
        let container = json["similartracks"] as? [String: Any]
        return list(container?["track"]).compactMap { entry -> LastFMSimilarTrack? in
            guard let title = entry["name"] as? String,
                  let artist = (entry["artist"] as? [String: Any])?["name"] as? String else { return nil }
            return LastFMSimilarTrack(title: title, artist: artist, match: number(entry["match"]))
        }
    }

    static func similarArtists(artist: String, apiKey: String) async throws -> [LastFMSimilarArtist] {
        let json = try await publicCall(method: "artist.getSimilar",
                                        parameters: ["artist": artist, "limit": "50", "autocorrect": "1"],
                                        apiKey: apiKey)
        let container = json["similarartists"] as? [String: Any]
        return list(container?["artist"]).compactMap { entry -> LastFMSimilarArtist? in
            guard let name = entry["name"] as? String else { return nil }
            return LastFMSimilarArtist(name: name, match: number(entry["match"]))
        }
    }

    /// An artist's most played songs on Last.fm, most played first.
    static func topTracks(artist: String, apiKey: String) async throws -> [LastFMSimilarTrack] {
        let json = try await publicCall(method: "artist.getTopTracks",
                                        parameters: ["artist": artist, "limit": "15", "autocorrect": "1"],
                                        apiKey: apiKey)
        let container = json["toptracks"] as? [String: Any]
        return list(container?["track"]).compactMap { entry -> LastFMSimilarTrack? in
            guard let title = entry["name"] as? String,
                  let name = (entry["artist"] as? [String: Any])?["name"] as? String else { return nil }
            return LastFMSimilarTrack(title: title, artist: name, match: 1)
        }
    }

    /// Unsigned read-only GET.
    private static func publicCall(method: String, parameters: [String: String], apiKey: String) async throws -> [String: Any] {
        var components = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")!
        let all = parameters.merging(["method": method, "api_key": apiKey, "format": "json"]) { first, _ in first }
        components.queryItems = all.map { URLQueryItem(name: $0.key, value: $0.value) }
        // URLComponents leaves "+" alone, which Last.fm would read as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw LastFMError.message("Bad Last.fm request") }
        var request = URLRequest(url: url)
        request.setValue(HTTP.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LastFMError.message("Unexpected reply from Last.fm")
        }
        if let message = json["message"] as? String, json["error"] != nil {
            throw LastFMError.message(message)
        }
        return json
    }

    /// Last.fm sends a lone object instead of a one-element array.
    private static func list(_ value: Any?) -> [[String: Any]] {
        if let array = value as? [[String: Any]] { return array }
        if let single = value as? [String: Any] { return [single] }
        return []
    }

    /// "match" is a number in some replies and a string in others.
    private static func number(_ value: Any?) -> Double {
        if let double = value as? Double { return double }
        if let string = value as? String { return Double(string) ?? 0 }
        if let int = value as? Int { return Double(int) }
        return 0
    }
}
