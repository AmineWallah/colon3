import Foundation

/// One song on a chart.
struct ChartEntry: Identifiable, Hashable {
    /// Apple Music's song ID.
    let id: String
    let rank: Int
    let title: String
    let artist: String
    let artworkURL: URL?
    let appleMusicURL: URL?
    let releaseDate: Date?

    var song: WantedSong { WantedSong(title: title, artists: [artist]) }
}

/// One album on Apple's top albums chart.
struct ChartAlbum: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let artworkURL: URL?
    let appleMusicURL: URL?
    let releaseDate: Date?
}

/// A song on a release's tracklist (from Apple's lookup API).
struct ReleaseTrack: Identifiable, Hashable {
    /// Apple's song ID; the same one the songs chart uses, so download state is shared.
    let id: String
    let disc: Int
    let number: Int
    let title: String
    let artist: String
    let album: String
    let duration: Double?

    var song: WantedSong { WantedSong(title: title, artists: [artist], album: album, duration: duration) }
}

/// The shelves on the Home tab, in the order Settings › Home Sections keeps.
enum HomeSection: String, CaseIterable, Identifiable {
    case trending, top100, releases, recent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .trending: return "Trending Songs"
        case .top100: return "Top 100"
        case .releases: return "Recent Releases"
        case .recent: return "Recently Played"
        }
    }

    static let orderKey = "home.sections"
    static let hiddenKey = "home.hidden"

    /// Every section in the saved order (new ones at the end), as stored in `orderKey`.
    static func ordered(_ stored: String) -> [HomeSection] {
        var result = stored.split(separator: ",").compactMap { HomeSection(rawValue: String($0)) }
        for section in allCases where !result.contains(section) { result.append(section) }
        return result
    }

    static func hidden(_ stored: String) -> Set<HomeSection> {
        Set(stored.split(separator: ",").compactMap { HomeSection(rawValue: String($0)) })
    }

    static func encode<S: Sequence>(_ sections: S) -> String where S.Element == HomeSection {
        sections.map(\.rawValue).joined(separator: ",")
    }
}

/// Apple Music's charts for a country, from Apple's public feed (rss.marketingtools.apple.com,
/// no key, updated daily): the top 100 songs, the songs on it that came out recently
/// ("trending"), and the top albums that came out recently. Downloads go through the shared
/// Soulseek fetcher and keep going when you leave the tab.
@MainActor
final class TrendingStore: ObservableObject {
    enum Fetch: Equatable {
        case searching
        case downloading(Double)
        case done(trackID: String)
        case failed(String)

        var isActive: Bool {
            switch self {
            case .searching, .downloading: return true
            case .done, .failed: return false
            }
        }

        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    /// Lower-case ISO country code of the chart shown.
    @Published var country: String {
        didSet {
            guard country != oldValue else { return }
            UserDefaults.standard.set(country, forKey: "trending.country")
            entries = []
            albums = []
            staleNote = nil
            Task { await load(force: true) }
        }
    }
    /// The top 100 songs, in chart order.
    @Published private(set) var entries: [ChartEntry] = []
    /// The top 100 albums, in chart order.
    @Published private(set) var albums: [ChartAlbum] = []
    @Published private(set) var updated: Date?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    /// Set when the charts on screen are older than they should be: Apple's server didn't
    /// answer, so the last ones that loaded are shown.
    @Published private(set) var staleNote: String?
    /// Downloads started from the chart, by entry ID.
    @Published private(set) var fetches: [String: Fetch] = [:]

    private let fetcher: SongFetcher
    private let library: LibraryStore
    private var tasks: [String: Task<Void, Never>] = [:]
    private var tracklists: [String: [ReleaseTrack]] = [:]
    private var loadedAt = Date.distantPast
    private var loadedCountry = ""
    /// The newest load; an older one that finishes later (country changed) is ignored.
    private var loadToken = UUID()
    private var index = LibraryIndex([])
    private var indexRevision = -1

    /// Countries offered in the picker. Apple publishes charts for every Apple Music storefront;
    /// these are the common ones plus your own region.
    static let countries: [String] = {
        var codes = ["us", "gb", "ca", "au", "ie", "nz", "fr", "de", "es", "it", "nl", "be", "ch", "at", "se", "no",
                     "dk", "fi", "pt", "pl", "br", "mx", "ar", "cl", "co", "jp", "kr", "in", "id", "ph", "th", "vn",
                     "my", "sg", "tw", "hk", "tr", "sa", "ae", "eg", "ma", "dz", "tn", "za", "ng", "ke", "il", "ua"]
        if let own = Locale.current.region?.identifier.lowercased(), !codes.contains(own) { codes.append(own) }
        return codes.sorted { countryName($0) < countryName($1) }
    }()

    nonisolated static func countryName(_ code: String) -> String {
        Locale.current.localizedString(forRegionCode: code.uppercased()) ?? code.uppercased()
    }

    init(fetcher: SongFetcher, library: LibraryStore) {
        self.fetcher = fetcher
        self.library = library
        let saved = UserDefaults.standard.string(forKey: "trending.country")
        let own = Locale.current.region?.identifier.lowercased()
        country = saved ?? (own.map { Self.countries.contains($0) ? $0 : "us" } ?? "us")
    }

    // MARK: Chart

    /// Loads the chart unless it was loaded for this country in the last hour.
    func load(force: Bool = false) async {
        let wanted = country
        if !force, loadedCountry == wanted, !entries.isEmpty, Date().timeIntervalSince(loadedAt) < 3600 { return }
        let token = UUID()
        loadToken = token
        isLoading = true
        do {
            // Albums are a bonus: the page still works if only the songs chart loads.
            async let songsFeed = Self.fetchFeed(country: wanted, kind: "songs")
            async let albumsFeed = try? Self.fetchFeed(country: wanted, kind: "albums")
            let songs = try await songsFeed
            let songResults = songs.results
            let albumResults = (await albumsFeed)?.results ?? []
            guard token == loadToken else { return }  // A newer load (another country) takes over.
            entries = songResults.enumerated().map { offset, result in
                ChartEntry(id: result.id, rank: offset + 1, title: result.name, artist: result.artistName,
                           artworkURL: Self.artwork(result.artworkUrl100, size: 300),
                           appleMusicURL: result.url.flatMap { URL(string: $0) },
                           releaseDate: Self.day(result.releaseDate))
            }
            albums = albumResults.map { result in
                ChartAlbum(id: result.id, title: result.name, artist: result.artistName,
                           artworkURL: Self.artwork(result.artworkUrl100, size: 600),
                           appleMusicURL: result.url.flatMap { URL(string: $0) },
                           releaseDate: Self.day(result.releaseDate))
            }
            updated = songs.updated
            loadedCountry = wanted
            error = nil
            if songs.cached {
                // Try again sooner than the usual hour.
                loadedAt = Date().addingTimeInterval(-3000)
                staleNote = "Apple's chart server isn't answering, so these are the charts from "
                    + (songs.updated.map { $0.formatted(.relative(presentation: .named)) } ?? "earlier")
                    + ". Pull down to try again."
            } else {
                loadedAt = Date()
                staleNote = nil
            }
        } catch {
            guard token == loadToken else { return }
            // Leaving the tab cancels the load; that isn't worth an error screen.
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                self.error = error.localizedDescription
                // Charts already on screen stay; say why they didn't refresh.
                if !entries.isEmpty, loadedCountry == wanted {
                    staleNote = error.localizedDescription + " Showing the charts from "
                        + (updated.map { $0.formatted(.relative(presentation: .named)) } ?? "earlier") + "."
                }
            }
        }
        isLoading = false
    }

    private struct Feed: Decodable {
        struct Body: Decodable {
            let updated: String?
            let results: [Result]
        }
        struct Result: Decodable {
            let id: String
            let name: String
            let artistName: String
            let artworkUrl100: String?
            let url: String?
            let releaseDate: String?
        }
        let feed: Body
    }

    enum TrendingError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self {
            case let .message(text): return text
            }
        }
    }

    private struct FeedResult {
        let results: [Feed.Result]
        let updated: Date?
        /// Read from the last copy saved on the phone because Apple's server didn't answer.
        let cached: Bool
    }

    nonisolated private static var cacheDirectory: URL {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Charts", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// "songs" or "albums": the 100 most played for the country. Apple's feed server
    /// sometimes answers 502/503 for a moment (seemingly while it rebuilds a chart), so
    /// server errors and network drops are retried twice; if it still fails, the last copy
    /// that loaded is used.
    nonisolated private static func fetchFeed(country: String, kind: String) async throws -> FeedResult {
        guard let url = URL(string: "https://rss.marketingtools.apple.com/api/v2/\(country)/music/most-played/100/\(kind).json") else {
            throw TrendingError.message("Bad chart address.")
        }
        let cacheFile = cacheDirectory.appendingPathComponent("\(country)-\(kind).json")
        var lastError: Error = TrendingError.message("Apple's chart server didn't answer.")
        for attempt in 0..<3 {
            if attempt > 0 {
                try await Task.sleep(nanoseconds: attempt == 1 ? 1_500_000_000 : 4_000_000_000)
            }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue(HTTP.userAgent, forHTTPHeaderField: "User-Agent")
            let data: Data
            let status: Int
            do {
                let (body, response) = try await URLSession.shared.data(for: request)
                data = body
                status = (response as? HTTPURLResponse)?.statusCode ?? 0
            } catch let error as URLError where error.code != .cancelled {
                lastError = error
                continue
            }
            if status == 404 { throw TrendingError.message("Apple has no chart for \(countryName(country)).") }
            guard status == 200 else {
                lastError = TrendingError.message("Apple's chart server answered \(status). Pull down to try again.")
                if status >= 500 || status == 429 { continue }
                break
            }
            guard let parsed = decode(data) else {
                lastError = TrendingError.message("Couldn't read Apple's chart.")
                continue
            }
            try? data.write(to: cacheFile, options: .atomic)
            return FeedResult(results: parsed.results, updated: parsed.updated, cached: false)
        }
        if let data = try? Data(contentsOf: cacheFile), let parsed = decode(data) {
            return FeedResult(results: parsed.results, updated: parsed.updated, cached: true)
        }
        throw lastError
    }

    nonisolated private static func decode(_ data: Data) -> (results: [Feed.Result], updated: Date?)? {
        guard let feed = try? JSONDecoder().decode(Feed.self, from: data) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return (feed.feed.results, feed.feed.updated.flatMap { formatter.date(from: $0) })
    }

    /// The feed links 100 px covers; Apple's image server makes any size from the same URL.
    nonisolated private static func artwork(_ address: String?, size: Int) -> URL? {
        address.flatMap { URL(string: $0.replacingOccurrences(of: "100x100bb", with: "\(size)x\(size)bb")) }
    }

    /// "2026-10-16" → that day.
    nonisolated private static func day(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }

    // MARK: Shelves

    /// Songs on the top 100 that came out recently, in chart order: what's new and catching on.
    /// The window widens (6 weeks, then 3 and 6 months) until there are at least 8, so a chart
    /// full of older hits still has a shelf.
    var trendingSongs: [ChartEntry] {
        Self.recent(entries, at: \.releaseDate, minimum: 8)
    }

    /// Albums on the top 100 albums chart that came out recently, newest first.
    var recentReleases: [ChartAlbum] {
        Self.recent(albums, at: \.releaseDate, minimum: 6)
            .sorted { ($0.releaseDate ?? .distantPast) > ($1.releaseDate ?? .distantPast) }
    }

    private static func recent<Item>(_ items: [Item], at date: KeyPath<Item, Date?>, minimum: Int) -> [Item] {
        let now = Date()
        for days in [42.0, 90, 180] {
            let cutoff = now.addingTimeInterval(-days * 86_400)
            let picked = items.filter { ($0[keyPath: date] ?? .distantPast) >= cutoff }
            if picked.count >= minimum { return picked }
        }
        return items.filter { ($0[keyPath: date] ?? .distantPast) >= now.addingTimeInterval(-365 * 86_400) }
    }

    // MARK: Library and downloads

    /// The library copy of a chart song, if you have it.
    func libraryTrack(for entry: ChartEntry) -> Track? {
        libraryTrack(id: entry.id, song: entry.song)
    }

    func libraryTrack(for track: ReleaseTrack) -> Track? {
        libraryTrack(id: track.id, song: track.song)
    }

    private func libraryTrack(id: String, song: WantedSong) -> Track? {
        if case let .done(trackID)? = fetches[id], let track = library.track(id: trackID) { return track }
        refreshIndex()
        return index.match(song)
    }

    /// Songs you have among `list`, in order (to queue them when one is played).
    func libraryTracks(in list: [ChartEntry]) -> [Track] {
        list.compactMap { libraryTrack(for: $0) }
    }

    /// The library album matching a chart album, if you have it.
    func libraryAlbum(for album: ChartAlbum) -> Album? {
        let title = TrackMatcher.normalizeTitle(album.title.replacingOccurrences(of: #"\s+-\s+(EP|Single)$"#, with: "",
                                                                                   options: .regularExpression))
        let artists = TrackMatcher.artistKeys(album.artist)
        return library.albums.first { candidate in
            TrackMatcher.normalizeTitle(candidate.title) == title
                && TrackMatcher.artistsOverlap(TrackMatcher.artistKeys(candidate.artist), artists)
        }
    }

    func download(_ entry: ChartEntry) {
        download(id: entry.id, song: entry.song)
    }

    func download(_ track: ReleaseTrack) {
        download(id: track.id, song: track.song)
    }

    private func download(id: String, song: WantedSong) {
        guard tasks[id] == nil else { return }
        fetches[id] = .searching
        tasks[id] = Task { [weak self] in
            guard let fetcher = self?.fetcher else { return }
            let outcome = await fetcher.fetch(song) { progress in
                self?.update(id, progress)
            }
            guard let self, !Task.isCancelled else { return }
            self.tasks[id] = nil
            switch outcome {
            case let .found(track, _):
                self.fetches[id] = .done(trackID: track.id)
            case let .notFound(reason):
                self.fetches[id] = .failed(reason)
            }
        }
    }

    private func update(_ id: String, _ progress: SongFetcher.Progress) {
        guard tasks[id] != nil else { return }
        switch progress {
        case .searching: fetches[id] = .searching
        case let .downloading(fraction, _): fetches[id] = .downloading(fraction)
        }
    }

    func cancel(_ entry: ChartEntry) {
        cancel(id: entry.id)
    }

    func cancel(_ track: ReleaseTrack) {
        cancel(id: track.id)
    }

    private func cancel(id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        fetches[id] = nil
    }

    // MARK: Release tracklists

    /// The album's songs in order, from Apple's lookup API (no key). Some storefronts (Algeria,
    /// for one) return the album without its songs, so the US store is asked next; album IDs
    /// are the same everywhere.
    func tracklist(for album: ChartAlbum) async throws -> [ReleaseTrack] {
        if let cached = tracklists[album.id] { return cached }
        var tracks = try await Self.lookupTracks(albumID: album.id, country: country)
        if tracks.isEmpty, country != "us" {
            tracks = try await Self.lookupTracks(albumID: album.id, country: "us")
        }
        guard !tracks.isEmpty else { throw TrendingError.message("Apple didn't list the songs on this album.") }
        tracklists[album.id] = tracks
        return tracks
    }

    nonisolated private static func lookupTracks(albumID: String, country: String) async throws -> [ReleaseTrack] {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [
            URLQueryItem(name: "id", value: albumID),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "limit", value: "200"),
        ]
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.setValue(HTTP.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw TrendingError.message(status == 403 || status == 429
                ? "Apple is limiting requests right now. Try again in a minute."
                : "Apple's lookup server answered \(status).")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TrendingError.message("Couldn't read Apple's album info.")
        }
        let results = json["results"] as? [[String: Any]] ?? []
        let tracks = results.compactMap { item -> ReleaseTrack? in
            guard item["wrapperType"] as? String == "track", item["kind"] as? String == "song",
                  let id = item["trackId"] as? Int, let title = item["trackName"] as? String else { return nil }
            let milliseconds = item["trackTimeMillis"] as? Double ?? 0
            return ReleaseTrack(id: String(id),
                                disc: item["discNumber"] as? Int ?? 1,
                                number: item["trackNumber"] as? Int ?? 0,
                                title: title,
                                artist: item["artistName"] as? String ?? "",
                                album: item["collectionName"] as? String ?? "",
                                duration: milliseconds > 0 ? milliseconds / 1000 : nil)
        }
        return tracks.sorted { ($0.disc, $0.number) < ($1.disc, $1.number) }
    }

    private func refreshIndex() {
        guard library.scanRevision != indexRevision else { return }
        index = LibraryIndex(library.tracks)
        indexRevision = library.scanRevision
    }
}
