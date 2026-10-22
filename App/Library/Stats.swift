import Foundation

/// Listening and sharing statistics, kept on the phone only (stats.json in Application Support).
/// Listening time is counted while audio actually plays, so seeking doesn't inflate it.
@MainActor
final class StatsStore: ObservableObject {
    struct TrackStat: Codable {
        var plays: Int
        var seconds: Double
        var lastPlayed: Date?
        /// Copied in so stats survive the file being deleted or renamed.
        var title: String
        var artist: String
        var album: String?
    }

    struct Totals: Codable {
        var downloadedBytes: UInt64 = 0
        var downloadedFiles = 0
        var uploadedBytes: UInt64 = 0
        var uploadedFiles = 0
        var peers: Set<String> = []
        var since = Date()
    }

    private struct Stored: Codable {
        var tracks: [String: TrackStat] = [:]
        /// "yyyy-MM-dd" → seconds listened that day.
        var days: [String: Double] = [:]
        var totals = Totals()
    }

    struct Ranked: Identifiable {
        let name: String
        let detail: String
        let plays: Int
        let seconds: Double
        var id: String { name + "|" + detail }
    }

    struct DayTotal: Identifiable {
        let date: Date
        let minutes: Double
        var id: Date { date }
    }

    /// Bumped on saves so open stats screens refresh (not on every listening tick).
    @Published private(set) var revision = 0
    /// Since the app launched; shown while seeding.
    @Published private(set) var sessionUploadedBytes: UInt64 = 0
    @Published private(set) var sessionUploadedFiles = 0
    @Published private(set) var sessionDownloadedBytes: UInt64 = 0

    private var stored = Stored()
    private var saveScheduled = false
    private let fileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("stats.json")

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    init() {
        if let data = try? Data(contentsOf: fileURL), let decoded = try? JSONDecoder().decode(Stored.self, from: data) {
            stored = decoded
        }
    }

    // MARK: Recording

    func addListening(_ track: Track, album: String?, seconds: Double) {
        update(track, album: album) { $0.seconds += seconds }
        stored.days[Self.dayFormatter.string(from: Date()), default: 0] += seconds
        scheduleSave()
    }

    func recordPlay(_ track: Track, album: String?) {
        update(track, album: album) {
            $0.plays += 1
            $0.lastPlayed = Date()
        }
        scheduleSave()
        revision += 1
    }

    func recordDownload(bytes: UInt64, from username: String) {
        stored.totals.downloadedBytes += bytes
        stored.totals.downloadedFiles += 1
        sessionDownloadedBytes += bytes
        scheduleSave()
    }

    func recordUpload(bytes: UInt64, to username: String) {
        stored.totals.uploadedBytes += bytes
        stored.totals.uploadedFiles += 1
        stored.totals.peers.insert(username)
        sessionUploadedBytes += bytes
        sessionUploadedFiles += 1
        scheduleSave()
    }

    func reset() {
        stored = Stored()
        save()
    }

    private func update(_ track: Track, album: String?, _ change: (inout TrackStat) -> Void) {
        var stat = stored.tracks[track.id]
            ?? TrackStat(plays: 0, seconds: 0, lastPlayed: nil, title: track.title, artist: track.artist, album: album)
        stat.title = track.title
        stat.artist = track.artist
        stat.album = album ?? stat.album
        change(&stat)
        stored.tracks[track.id] = stat
    }

    // MARK: Reading

    var totals: Totals { stored.totals }
    var totalSeconds: Double { stored.tracks.values.reduce(0) { $0 + $1.seconds } }
    var totalPlays: Int { stored.tracks.values.reduce(0) { $0 + $1.plays } }
    var distinctSongs: Int { stored.tracks.values.filter { $0.plays > 0 }.count }

    func plays(of track: Track) -> Int { stored.tracks[track.id]?.plays ?? 0 }

    func mostPlayed(limit: Int, in library: LibraryStore) -> [Track] {
        let ranked = stored.tracks
            .filter { $0.value.plays > 0 }
            .sorted { ($0.value.plays, $0.value.seconds) > ($1.value.plays, $1.value.seconds) }
        return Array(ranked.lazy.compactMap { library.track(id: $0.key) }.prefix(limit))
    }

    /// Albums and loose songs you played, most recent first (an album appears once, at its
    /// latest play). Only things still in the library.
    func recentlyPlayed(limit: Int, in library: LibraryStore) -> [LibraryItem] {
        let played = stored.tracks
            .compactMap { id, stat -> (String, Date)? in stat.lastPlayed.map { (id, $0) } }
            .sorted { $0.1 > $1.1 }
        var seen = Set<String>()
        var result: [LibraryItem] = []
        for (id, _) in played {
            guard let track = library.track(id: id) else { continue }
            let item = library.album(containing: track).map(LibraryItem.album) ?? .single(track)
            guard seen.insert(item.id).inserted else { continue }
            result.append(item)
            if result.count == limit { break }
        }
        return result
    }

    func topSongs(limit: Int) -> [Ranked] {
        stored.tracks.values
            .filter { $0.plays > 0 }
            .sorted { ($0.plays, $0.seconds) > ($1.plays, $1.seconds) }
            .prefix(limit)
            .map { Ranked(name: $0.title, detail: $0.artist, plays: $0.plays, seconds: $0.seconds) }
    }

    func topArtists(limit: Int) -> [Ranked] {
        var plays: [String: Int] = [:]
        var seconds: [String: Double] = [:]
        for stat in stored.tracks.values {
            plays[stat.artist, default: 0] += stat.plays
            seconds[stat.artist, default: 0] += stat.seconds
        }
        return seconds.keys
            .sorted { (seconds[$0] ?? 0) > (seconds[$1] ?? 0) }
            .prefix(limit)
            .map { Ranked(name: $0, detail: "", plays: plays[$0] ?? 0, seconds: seconds[$0] ?? 0) }
    }

    func topAlbums(limit: Int) -> [Ranked] {
        struct Key: Hashable { let album: String; let artist: String }
        var plays: [Key: Int] = [:]
        var seconds: [Key: Double] = [:]
        for stat in stored.tracks.values {
            guard let album = stat.album, !album.isEmpty else { continue }
            let key = Key(album: album, artist: stat.artist)
            plays[key, default: 0] += stat.plays
            seconds[key, default: 0] += stat.seconds
        }
        return seconds.keys
            .sorted { (seconds[$0] ?? 0) > (seconds[$1] ?? 0) }
            .prefix(limit)
            .map { Ranked(name: $0.album, detail: $0.artist, plays: plays[$0] ?? 0, seconds: seconds[$0] ?? 0) }
    }

    /// Listening per day for the last `count` days, oldest first, including zero days.
    func lastDays(_ count: Int) -> [DayTotal] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<count).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return DayTotal(date: day, minutes: (stored.days[Self.dayFormatter.string(from: day)] ?? 0) / 60)
        }
    }

    func seconds(inLast days: Int) -> Double {
        lastDays(days).reduce(0) { $0 + $1.minutes * 60 }
    }

    // MARK: Saving

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            self?.save()
        }
    }

    /// Also called when the app goes to the background.
    func save() {
        saveScheduled = false
        revision += 1
        let snapshot = stored
        let url = fileURL
        Task.detached(priority: .background) {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
