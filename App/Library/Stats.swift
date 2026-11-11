import Foundation

/// What a chart covers: the last 7, 30 or 365 days, or everything.
enum ChartPeriod: String, CaseIterable, Identifiable {
    case week, month, year, allTime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: return "Week"
        case .month: return "Month"
        case .year: return "Year"
        case .allTime: return "All Time"
        }
    }

    /// As written on the shared image.
    var caption: String {
        switch self {
        case .week: return "Last 7 days"
        case .month: return "Last 30 days"
        case .year: return "Last 12 months"
        case .allTime: return "All time"
        }
    }

    var days: Int? {
        switch self {
        case .week: return 7
        case .month: return 30
        case .year: return 365
        case .allTime: return nil
        }
    }
}

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
        /// "yyyy-MM-dd" → song id → plays that day, for the week, month and year charts.
        /// Optional so stats saved before 1.4.0 (which only kept totals) still load.
        var dayPlays: [String: [String: Int]]?
    }

    /// An album or loose song and how much it was played in a period.
    struct PlayedItem: Identifiable {
        let item: LibraryItem
        let plays: Int
        let seconds: Double
        var id: String { item.id }
    }

    /// Days of per-day plays kept: a year and some slack.
    private static let dayPlaysKept = 400

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
        if stored.dayPlays == nil {
            // Stats from before plays were kept per day: all that's known is when each song was
            // last played, so count one play on that day. The period charts start from that.
            var log: [String: [String: Int]] = [:]
            for (id, stat) in stored.tracks {
                guard stat.plays > 0, let last = stat.lastPlayed else { continue }
                log[Self.dayFormatter.string(from: last), default: [:]][id] = 1
            }
            stored.dayPlays = log
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
        var log = stored.dayPlays ?? [:]
        log[Self.dayFormatter.string(from: Date()), default: [:]][track.id, default: 0] += 1
        stored.dayPlays = log
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
        stored.dayPlays = [:]
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

    /// When a song (by id) was last played, if ever.
    func lastPlayed(_ trackID: String) -> Date? { stored.tracks[trackID]?.lastPlayed }

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

    /// The most played albums and loose songs in a period, most played first; ties go to the
    /// one listened to longest overall. Only things still in the library (they need a cover).
    func topItems(_ period: ChartPeriod, limit: Int, in library: LibraryStore) -> [PlayedItem] {
        var playsBySong: [String: Int] = [:]
        if let days = period.days {
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            guard let first = calendar.date(byAdding: .day, value: 1 - days, to: today) else { return [] }
            // Day keys are yyyy-MM-dd, so they sort like dates.
            let firstKey = Self.dayFormatter.string(from: first)
            for (day, counts) in stored.dayPlays ?? [:] where day >= firstKey {
                for (id, count) in counts { playsBySong[id, default: 0] += count }
            }
        } else {
            for (id, stat) in stored.tracks where stat.plays > 0 { playsBySong[id] = stat.plays }
        }

        var items: [String: LibraryItem] = [:]
        var plays: [String: Int] = [:]
        var seconds: [String: Double] = [:]
        for (id, count) in playsBySong {
            guard let track = library.track(id: id) else { continue }
            let item = library.album(containing: track).map(LibraryItem.album) ?? .single(track)
            items[item.id] = item
            plays[item.id, default: 0] += count
            seconds[item.id, default: 0] += stored.tracks[id]?.seconds ?? 0
        }
        let ranked = items.values
            .map { PlayedItem(item: $0, plays: plays[$0.id] ?? 0, seconds: seconds[$0.id] ?? 0) }
            .sorted { lhs, rhs in
                if lhs.plays != rhs.plays { return lhs.plays > rhs.plays }
                if lhs.seconds != rhs.seconds { return lhs.seconds > rhs.seconds }
                return lhs.item.title < rhs.item.title
            }
        return Array(ranked.prefix(limit))
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

    // MARK: Backup

    /// Everything, as stats.json stores it.
    func exportData() -> Data? {
        try? JSONEncoder().encode(stored)
    }

    /// Merges stats from a backup. `remap` turns the backup's song ids into this library's.
    /// Keeps the larger number for each song, day and total, so restoring the same backup twice
    /// (or onto the phone it came from) doesn't count anything twice.
    @discardableResult
    func merge(_ data: Data, remap: [String: String]) -> Bool {
        guard let incoming = try? JSONDecoder().decode(Stored.self, from: data) else { return false }
        for (oldID, stat) in incoming.tracks {
            let id = remap[oldID] ?? oldID
            if let current = stored.tracks[id] {
                stored.tracks[id] = Self.combined(current, stat)
            } else {
                stored.tracks[id] = stat
            }
        }
        for (day, seconds) in incoming.days {
            stored.days[day] = max(stored.days[day] ?? 0, seconds)
        }
        var log = stored.dayPlays ?? [:]
        for (day, counts) in incoming.dayPlays ?? [:] {
            for (oldID, count) in counts {
                let id = remap[oldID] ?? oldID
                let known = log[day]?[id] ?? 0
                log[day, default: [:]][id] = max(known, count)
            }
        }
        stored.dayPlays = log
        var totals = stored.totals
        totals.downloadedBytes = max(totals.downloadedBytes, incoming.totals.downloadedBytes)
        totals.downloadedFiles = max(totals.downloadedFiles, incoming.totals.downloadedFiles)
        totals.uploadedBytes = max(totals.uploadedBytes, incoming.totals.uploadedBytes)
        totals.uploadedFiles = max(totals.uploadedFiles, incoming.totals.uploadedFiles)
        totals.peers.formUnion(incoming.totals.peers)
        totals.since = min(totals.since, incoming.totals.since)
        stored.totals = totals
        save()
        return true
    }

    /// A song's file moved (found again after a restore): its stats follow it.
    func moveStats(from oldID: String, to newID: String) {
        guard oldID != newID, let stat = stored.tracks.removeValue(forKey: oldID) else { return }
        if let current = stored.tracks[newID] {
            stored.tracks[newID] = Self.combined(current, stat)
        } else {
            stored.tracks[newID] = stat
        }
        var log = stored.dayPlays ?? [:]
        for day in Array(log.keys) {
            guard let count = log[day]?.removeValue(forKey: oldID) else { continue }
            let known = log[day]?[newID] ?? 0
            log[day]?[newID] = max(known, count)
        }
        stored.dayPlays = log
        scheduleSave()
    }

    private static func combined(_ current: TrackStat, _ other: TrackStat) -> TrackStat {
        var result = current
        result.plays = max(current.plays, other.plays)
        result.seconds = max(current.seconds, other.seconds)
        if let played = other.lastPlayed, played > (current.lastPlayed ?? .distantPast) { result.lastPlayed = played }
        if result.album == nil { result.album = other.album }
        return result
    }

    /// Also called when the app goes to the background.
    func save() {
        saveScheduled = false
        revision += 1
        // Per-day plays older than the longest chart aren't needed.
        if let log = stored.dayPlays, log.count > Self.dayPlaysKept,
           let oldest = Calendar.current.date(byAdding: .day, value: -Self.dayPlaysKept, to: Date()) {
            let oldestKey = Self.dayFormatter.string(from: oldest)
            stored.dayPlays = log.filter { $0.key >= oldestKey }
        }
        let snapshot = stored
        let url = fileURL
        Task.detached(priority: .background) {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
