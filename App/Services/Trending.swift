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
    /// Downloads started from the chart, by entry ID.
    @Published private(set) var fetches: [String: Fetch] = [:]

    private let fetcher: SongFetcher
    private let library: LibraryStore
    private var tasks: [String: Task<Void, Never>] = [:]
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
            let (songResults, date) = try await songsFeed
            let albumResults = (await albumsFeed)?.0 ?? []
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
            updated = date
            loadedAt = Date()
            loadedCountry = wanted
            error = nil
        } catch {
            guard token == loadToken else { return }
            // Leaving the tab cancels the load; that isn't worth an error screen.
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                self.error = error.localizedDescription
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

    /// "songs" or "albums": the 100 most played for the country.
    nonisolated private static func fetchFeed(country: String, kind: String) async throws -> ([Feed.Result], Date?) {
        guard let url = URL(string: "https://rss.marketingtools.apple.com/api/v2/\(country)/music/most-played/100/\(kind).json") else {
            throw TrendingError.message("Bad chart address.")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue(HTTP.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw TrendingError.message(status == 404 ? "Apple has no chart for \(countryName(country))." : "Apple's chart server answered \(status).")
        }
        let feed: Feed
        do {
            feed = try JSONDecoder().decode(Feed.self, from: data)
        } catch {
            throw TrendingError.message("Couldn't read Apple's chart.")
        }
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
        if case let .done(trackID)? = fetches[entry.id], let track = library.track(id: trackID) { return track }
        refreshIndex()
        return index.match(entry.song)
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
        guard tasks[entry.id] == nil else { return }
        fetches[entry.id] = .searching
        let id = entry.id
        let song = entry.song
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
        tasks[entry.id]?.cancel()
        tasks[entry.id] = nil
        fetches[entry.id] = nil
    }

    private func refreshIndex() {
        guard library.scanRevision != indexRevision else { return }
        index = LibraryIndex(library.tracks)
        indexRevision = library.scanRevision
    }
}
