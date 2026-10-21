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

    var song: WantedSong { WantedSong(title: title, artists: [artist]) }
}

/// Today's most played songs on Apple Music for a country, from Apple's public chart feed
/// (rss.marketingtools.apple.com, no key, updated daily), with downloads through the shared
/// Soulseek fetcher. Downloads keep going when you leave the tab.
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
            Task { await load(force: true) }
        }
    }
    @Published private(set) var entries: [ChartEntry] = []
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
            let (chart, date) = try await Self.fetchChart(country: wanted)
            guard token == loadToken else { return }  // A newer load (another country) takes over.
            entries = chart
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

    nonisolated private static func fetchChart(country: String) async throws -> ([ChartEntry], Date?) {
        guard let url = URL(string: "https://rss.marketingtools.apple.com/api/v2/\(country)/music/most-played/100/songs.json") else {
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
        let entries = feed.feed.results.enumerated().map { offset, result -> ChartEntry in
            // The feed links 100 px covers; Apple's image server makes any size from the same URL.
            let artwork = result.artworkUrl100?.replacingOccurrences(of: "100x100bb", with: "300x300bb")
            return ChartEntry(id: result.id, rank: offset + 1, title: result.name, artist: result.artistName,
                              artworkURL: artwork.flatMap { URL(string: $0) },
                              appleMusicURL: result.url.flatMap { URL(string: $0) })
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return (entries, feed.feed.updated.flatMap { formatter.date(from: $0) })
    }

    // MARK: Library and downloads

    /// The library copy of a chart song, if you have it.
    func libraryTrack(for entry: ChartEntry) -> Track? {
        if case let .done(trackID)? = fetches[entry.id], let track = library.track(id: trackID) { return track }
        refreshIndex()
        return index.match(entry.song)
    }

    /// Chart songs you have, in chart order (to queue them when one is played).
    func libraryTracks() -> [Track] {
        entries.compactMap { libraryTrack(for: $0) }
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
