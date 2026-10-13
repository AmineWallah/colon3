import Foundation
import SoulseekKit

/// A song the album should have but the library doesn't.
struct MissingTrack: Identifiable, Hashable {
    enum Source: Hashable {
        /// Seen in the peer's folder when the album was downloaded; downloadable directly.
        case soulseek(username: String, file: SharedFile)
        /// From the MusicBrainz tracklist; has to be searched for.
        case musicBrainz
    }

    let id: String
    let disc: Int
    let number: Int?
    let title: String
    let duration: Double?
    let source: Source
}

struct AlbumCompleteness: Equatable {
    var missing: [MissingTrack]
    var expectedCount: Int
    var sourceDescription: String
    /// How many songs the album had when this was worked out; a change triggers a recheck.
    var localCount: Int
}

/// Works out which songs an album is missing, from the Soulseek folder it came from or from
/// MusicBrainz. Results are cached per album.
@MainActor
final class AlbumCompletenessStore: ObservableObject {
    @Published private(set) var results: [String: AlbumCompleteness] = [:]
    @Published private(set) var hiddenAlbums: Set<String>
    @Published private(set) var loading: Set<String> = []

    private let listings = FolderListingStore()

    init() {
        hiddenAlbums = Set(UserDefaults.standard.stringArray(forKey: "missing.hiddenAlbums") ?? [])
    }

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: AppSettings.showMissingKey) as? Bool ?? true }
    static var musicBrainzEnabled: Bool { UserDefaults.standard.object(forKey: AppSettings.musicBrainzKey) as? Bool ?? true }

    func isHidden(_ album: Album) -> Bool { hiddenAlbums.contains(album.id) }

    func setHidden(_ album: Album, _ hidden: Bool) {
        if hidden { hiddenAlbums.insert(album.id) } else { hiddenAlbums.remove(album.id) }
        UserDefaults.standard.set(Array(hiddenAlbums), forKey: "missing.hiddenAlbums")
    }

    /// Remember a peer's full folder listing when downloading from it.
    func recordListing(username: String, remoteFolder: String, files: [SharedFile]) {
        let audio = files.filter { LibraryStore.audioExtensions.contains($0.fileExtension) && $0.folder == remoteFolder }
        guard !audio.isEmpty else { return }
        let local = SoulseekClient.libraryFolderName(forRemoteFolder: SharedFile(path: remoteFolder + "\\x", size: 0).folderName)
        listings.save(FolderListing(username: username, remoteFolder: remoteFolder, files: audio), forLocalFolder: local)
    }

    func refresh(_ album: Album, force: Bool = false) {
        guard Self.isEnabled, !loading.contains(album.id) else { return }
        if !force, let existing = results[album.id], existing.localCount == album.tracks.count { return }
        loading.insert(album.id)

        // 1. The Soulseek folder it was downloaded from: exact and offline.
        if let listing = listings.listing(forLocalFolder: album.folder.lastPathComponent) {
            results[album.id] = Self.compare(album, expected: listing.expectedTracks(), source: "From \(listing.username)'s folder")
            loading.remove(album.id)
            return
        }

        // 2. MusicBrainz.
        guard Self.musicBrainzEnabled else {
            loading.remove(album.id)
            return
        }
        let mbid = album.tracks.compactMap(\.musicBrainzAlbumID).first
        let title = album.title, artist = album.artist, count = album.tracks.count
        Task {
            let tracklist = await MusicBrainz.shared.tracklist(albumID: album.id, releaseID: mbid,
                                                               title: title, artist: artist, localCount: count, force: force)
            if let tracklist {
                self.results[album.id] = Self.compare(album, expected: tracklist.tracks, source: "MusicBrainz: \(tracklist.title)")
            }
            self.loading.remove(album.id)
        }
    }

    private static func compare(_ album: Album, expected: [ExpectedTrack], source: String) -> AlbumCompleteness {
        let localFiles = Set(album.tracks.map { normalizeFilename($0.url.lastPathComponent) })
        let localTitles = album.tracks.map { normalizeTitle($0.title) }.filter { !$0.isEmpty }
        let localNumbers = Set(album.tracks.compactMap { track in track.trackNumber.map { "\(track.discNumber ?? 1)-\($0)" } })

        var missing: [MissingTrack] = []
        for entry in expected {
            if let filename = entry.filename, localFiles.contains(normalizeFilename(filename)) { continue }
            let title = normalizeTitle(entry.title)
            if !title.isEmpty, localTitles.contains(where: { local in
                local == title || (min(local.count, title.count) >= 5 && (local.hasPrefix(title) || title.hasPrefix(local)))
            }) { continue }
            // Same disc/track number and no title to go on: assume it's there.
            if title.isEmpty, let number = entry.number, localNumbers.contains("\(entry.disc)-\(number)") { continue }
            missing.append(MissingTrack(id: "\(entry.disc)-\(entry.number ?? 0)-\(entry.title)", disc: entry.disc,
                                        number: entry.number, title: entry.title, duration: entry.duration,
                                        source: entry.source))
        }
        return AlbumCompleteness(missing: missing, expectedCount: max(expected.count, album.tracks.count),
                                 sourceDescription: source, localCount: album.tracks.count)
    }

    static func normalizeTitle(_ title: String) -> String {
        var text = title.lowercased().folding(options: [.diacriticInsensitive], locale: nil)
        for pattern in [#"\([^)]*\)"#, #"\[[^\]]*\]"#, #"\b(feat|ft|featuring)\.?\s.*$"#, #"\s-\s.*(remaster|version|edit|mix).*$"#] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    private static func normalizeFilename(_ name: String) -> String {
        // Library copies may have gained " (1)" when a name was taken.
        name.lowercased().replacingOccurrences(of: #" \(\d+\)(?=\.[^.]+$)"#, with: "", options: .regularExpression)
    }
}

struct ExpectedTrack {
    let disc: Int
    let number: Int?
    let title: String
    let duration: Double?
    let filename: String?
    let source: MissingTrack.Source
}

// MARK: - Soulseek folder listings

struct FolderListing: Codable {
    struct File: Codable {
        let path: String
        let size: UInt64
        let duration: UInt32?
    }

    let username: String
    let remoteFolder: String
    let files: [File]

    init(username: String, remoteFolder: String, files: [SharedFile]) {
        self.username = username
        self.remoteFolder = remoteFolder
        self.files = files.map { File(path: $0.path, size: $0.size, duration: $0.attributes.duration) }
    }

    func expectedTracks() -> [ExpectedTrack] {
        files.map { file in
            let shared = SharedFile(path: file.path, size: file.size, attributes: FileAttributes(duration: file.duration))
            let parsed = MetadataReader.parseFilename((shared.filename as NSString).deletingPathExtension)
            return ExpectedTrack(disc: 1, number: parsed.number, title: parsed.title,
                                 duration: file.duration.map(Double.init), filename: shared.filename,
                                 source: .soulseek(username: username, file: shared))
        }
        .sorted { ($0.number ?? 999, $0.title) < ($1.number ?? 999, $1.title) }
    }
}

/// Folder listings keyed by the local folder name the album landed in.
final class FolderListingStore {
    private var listings: [String: FolderListing]
    private let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("album-sources.json")

    init() {
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([String: FolderListing].self, from: data) {
            listings = decoded
        } else {
            listings = [:]
        }
    }

    func listing(forLocalFolder name: String) -> FolderListing? { listings[name] }

    func save(_ listing: FolderListing, forLocalFolder name: String) {
        listings[name] = listing
        if let data = try? JSONEncoder().encode(listings) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - MusicBrainz

struct Tracklist: Codable {
    let title: String
    let tracks: [Entry]

    struct Entry: Codable {
        let disc: Int
        let number: Int?
        let title: String
        let duration: Double?
    }
}

extension Tracklist {
    fileprivate func expected() -> [ExpectedTrack] {
        tracks.map { ExpectedTrack(disc: $0.disc, number: $0.number, title: $0.title, duration: $0.duration,
                                   filename: nil, source: .musicBrainz) }
    }
}

/// Release tracklists from MusicBrainz (free, no key; max ~1 request/second, needs a User-Agent).
actor MusicBrainz {
    static let shared = MusicBrainz()

    private var lastRequest = Date.distantPast
    private let directory: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tracklists", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private struct Cached: Codable {
        let tracklist: Tracklist?
        let fetched: Date
    }

    /// The best-matching release's tracks, or nil if none was found.
    func tracklist(albumID: String, releaseID: String?, title: String, artist: String, localCount: Int,
                   force: Bool) async -> (title: String, tracks: [ExpectedTrack])? {
        let file = directory.appendingPathComponent(albumID + ".json")
        if !force, let data = try? Data(contentsOf: file), let cached = try? JSONDecoder().decode(Cached.self, from: data),
           cached.tracklist != nil || Date().timeIntervalSince(cached.fetched) < 7 * 86_400 {
            return cached.tracklist.map { ($0.title, $0.expected()) }
        }

        var found: Tracklist?
        do {
            let id: String?
            if let releaseID {
                id = releaseID
            } else {
                id = try await searchRelease(title: title, artist: artist, localCount: localCount)
            }
            if let id { found = try await fetchRelease(id) }
        } catch {
            return nil  // Network trouble: don't cache, try again later
        }
        if let data = try? JSONEncoder().encode(Cached(tracklist: found, fetched: Date())) {
            try? data.write(to: file, options: .atomic)
        }
        return found.map { ($0.title, $0.expected()) }
    }

    private func searchRelease(title: String, artist: String, localCount: Int) async throws -> String? {
        let escapedTitle = title.replacingOccurrences(of: "\"", with: "")
        let escapedArtist = artist.replacingOccurrences(of: "\"", with: "")
        var query = "release:\"\(escapedTitle)\""
        if artist != "Various Artists", artist != "Unknown Artist" { query += " AND artist:\"\(escapedArtist)\"" }
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/release/")!
        components.queryItems = [URLQueryItem(name: "query", value: query),
                                 URLQueryItem(name: "fmt", value: "json"),
                                 URLQueryItem(name: "limit", value: "10")]
        struct Response: Decodable {
            struct Release: Decodable {
                let id: String
                let title: String
                let score: Int?
                let trackCount: Int?
                enum CodingKeys: String, CodingKey {
                    case id, title, score
                    case trackCount = "track-count"
                }
            }
            let releases: [Release]
        }
        let response: Response = try await get(components.url!)
        let wanted = AlbumCompletenessStoreNormalizer.title(title)
        let candidates = response.releases.filter { ($0.score ?? 0) >= 80 }
            .filter { AlbumCompletenessStoreNormalizer.title($0.title) == wanted || ($0.score ?? 0) >= 95 }
        // Prefer the edition with at least as many tracks as we have, and the fewest extras.
        let best = candidates.min { lhs, rhs in
            func cost(_ release: Response.Release) -> Int {
                let count = release.trackCount ?? 0
                return count >= localCount ? count - localCount : 1000 + (localCount - count)
            }
            return cost(lhs) < cost(rhs)
        }
        return best?.id
    }

    private func fetchRelease(_ id: String) async throws -> Tracklist? {
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/release/\(id)")!
        components.queryItems = [URLQueryItem(name: "inc", value: "recordings"), URLQueryItem(name: "fmt", value: "json")]
        struct Response: Decodable {
            struct Medium: Decodable {
                struct Track: Decodable {
                    let number: String?
                    let position: Int?
                    let title: String
                    let length: Int?
                }
                let position: Int?
                let tracks: [Track]?
            }
            let title: String
            let media: [Medium]?
        }
        let response: Response = try await get(components.url!)
        let entries = (response.media ?? []).flatMap { medium in
            (medium.tracks ?? []).map { track in
                Tracklist.Entry(disc: medium.position ?? 1,
                                number: track.position ?? Int(track.number ?? ""),
                                title: track.title,
                                duration: track.length.map { Double($0) / 1000 })
            }
        }
        return entries.isEmpty ? nil : Tracklist(title: response.title, tracks: entries)
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        let wait = 1.1 - Date().timeIntervalSince(lastRequest)
        lastRequest = Date().addingTimeInterval(max(wait, 0))
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }

        var request = URLRequest(url: url)
        request.setValue(HTTP.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// Title normalisation usable off the main actor.
enum AlbumCompletenessStoreNormalizer {
    static func title(_ text: String) -> String {
        text.lowercased().folding(options: [.diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: #"\([^)]*\)|\[[^\]]*\]"#, with: "", options: .regularExpression)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
}
