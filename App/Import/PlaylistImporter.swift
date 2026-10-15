import Combine
import Foundation
import SoulseekKit

enum ImportSource: String, Identifiable, CaseIterable {
    case spotify, appleMusic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .spotify: return "Spotify"
        case .appleMusic: return "Apple Music"
        }
    }

    var systemImage: String {
        switch self {
        case .spotify: return "dot.radiowaves.up.forward"
        case .appleMusic: return "music.note"
        }
    }
}

struct ImportSong: Identifiable {
    enum Status: Equatable {
        case waiting
        case inLibrary
        case searching
        case downloading(Double)
        case added
        case notFound(String)

        var isPending: Bool {
            switch self {
            case .waiting, .searching, .downloading: return true
            case .inLibrary, .added, .notFound: return false
            }
        }

        var isNotFound: Bool {
            if case .notFound = self { return true }
            return false
        }

        var isBusy: Bool {
            switch self {
            case .searching, .downloading: return true
            default: return false
            }
        }
    }

    let id: Int
    let song: WantedSong
    var status: Status = .waiting
    var trackID: String?
    /// The file being downloaded, e.g. "FLAC 16/44.1 · username".
    var detail: String?
}

struct ImportJob {
    let name: String
    let source: ImportSource
    let sourceKey: String
    var playlistID: UUID
    var songs: [ImportSong]
    var isRunning: Bool

    var inLibraryCount: Int { songs.filter { $0.status == .inLibrary }.count }
    var addedCount: Int { songs.filter { $0.status == .added }.count }
    var notFoundCount: Int { songs.filter(\.status.isNotFound).count }
    var pendingCount: Int { songs.filter(\.status.isPending).count }
    var doneCount: Int { songs.count - pendingCount }
}

/// Turns a playlist from another service into a colon3 playlist: songs already in the library
/// are added straight away, the rest are searched on Soulseek one at a time (spaced out so the
/// server isn't flooded), the best file is downloaded, and the playlist fills in the original
/// order as songs arrive. Runs on its own, so closing the import screen doesn't stop it.
@MainActor
final class PlaylistImporter: ObservableObject {
    @Published private(set) var job: ImportJob?
    @Published private(set) var waitingForSoulseek = false

    /// Time between the starts of two searches.
    static let searchSpacing: TimeInterval = 10
    /// How long results are collected for each search.
    static let searchWindow: TimeInterval = 10
    static let maxActiveDownloads = 4
    /// A download with no new bytes for this long (still queued on the peer, or stuck) is
    /// abandoned for the next-best file.
    static let stallTimeout: TimeInterval = 180

    private let soulseek: SoulseekModel
    private let library: LibraryStore
    private let playlists: PlaylistStore

    private struct Candidate {
        let username: String
        let file: SharedFile
        let score: Int
    }

    private struct ActiveDownload {
        let song: Int
        var fallbacks: [Candidate]
        var lastProgressAt: Date
        var lastReceived: UInt64
    }

    private var worker: Task<Void, Never>?
    private var watchdog: Timer?
    private var subscriptions = Set<AnyCancellable>()
    private var index = LibraryIndex([])
    private var indexRevision = -1
    private var active: [DownloadID: ActiveDownload] = [:]
    /// Finished files waiting for the library scan to pick them up.
    private var awaitingLibrary: [URL: Int] = [:]
    private var lastSearchAt = Date.distantPast
    private var collected: [SearchResponse] = []

    private static let mappingKey = "import.playlists"

    init(soulseek: SoulseekModel, library: LibraryStore, playlists: PlaylistStore) {
        self.soulseek = soulseek
        self.library = library
        self.playlists = playlists

        soulseek.downloadEvents
            .sink { [weak self] update in
                MainActor.assumeIsolated { self?.handle(update) }
            }
            .store(in: &subscriptions)

        // @Published fires before the new value is stored; hop once so lookups see the new scan.
        library.$tracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.resolveFinished() }
            }
            .store(in: &subscriptions)
    }

    var isRunning: Bool { job?.isRunning ?? false }

    // MARK: Control

    func start(name: String, source: ImportSource, sourceKey: String, songs: [WantedSong]) {
        guard !isRunning, !songs.isEmpty else { return }
        worker?.cancel()
        active.removeAll()
        awaitingLibrary.removeAll()

        // Importing the same playlist again updates the colon3 playlist made last time.
        var mapping = UserDefaults.standard.dictionary(forKey: Self.mappingKey) as? [String: String] ?? [:]
        let playlistID: UUID
        if let saved = mapping[sourceKey].flatMap(UUID.init(uuidString:)), playlists.playlist(id: saved) != nil {
            playlistID = saved
        } else {
            playlistID = playlists.create(named: name).id
            mapping[sourceKey] = playlistID.uuidString
            UserDefaults.standard.set(mapping, forKey: Self.mappingKey)
        }

        job = ImportJob(name: name, source: source, sourceKey: sourceKey, playlistID: playlistID,
                        songs: songs.enumerated().map { ImportSong(id: $0.offset, song: $0.element) },
                        isRunning: true)
        Diagnostics.shared.log("Importing \(songs.count) songs from \(source.title) playlist \(name)", category: "import")
        matchLibrary()
        syncPlaylist()
        runWorker()
    }

    /// Stops searching and cancels this import's downloads. Songs already added stay.
    func cancel() {
        guard var current = job, current.isRunning else { return }
        worker?.cancel()
        worker = nil
        if !active.isEmpty { soulseek.remove(Set(active.keys)) }
        active.removeAll()
        let arriving = Set(awaitingLibrary.values)
        for position in current.songs.indices where current.songs[position].status.isPending && !arriving.contains(position) {
            current.songs[position].status = .notFound("Cancelled")
            current.songs[position].detail = nil
        }
        current.isRunning = false
        job = current
        stopRunning()
        Diagnostics.shared.log("Import of \(current.name) cancelled", category: "import")
    }

    /// Searches again for songs that weren't found (or were cancelled).
    func retryNotFound() {
        guard var current = job, !current.isRunning, current.notFoundCount > 0 else { return }
        for position in current.songs.indices where current.songs[position].status.isNotFound {
            current.songs[position].status = .waiting
            current.songs[position].detail = nil
        }
        current.isRunning = true
        job = current
        matchLibrary()
        syncPlaylist()
        runWorker()
    }

    /// Forgets a finished import (its playlist stays).
    func dismiss() {
        guard !isRunning else { return }
        job = nil
    }

    // MARK: Worker

    private func runWorker() {
        worker?.cancel()
        soulseek.isImportingPlaylist = true
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkStalls() }
        }
        worker = Task { [weak self] in
            await self?.work()
        }
        checkFinished()
    }

    private func work() async {
        while !Task.isCancelled {
            guard await waitForCapacity() else { return }
            guard let position = nextSongToSearch(), let song = job?.songs[position].song else { return }

            // It may have arrived meanwhile: a download for the same song, or added by hand.
            refreshIndex()
            if let track = index.match(song) {
                resolve(position, track: track, status: .inLibrary)
                continue
            }

            update(position) { $0.status = .searching }
            let query = TrackMatcher.searchQuery(for: song)
            var candidates = await search(query, for: song, requireArtistInPath: false)
            if Task.isCancelled { return }
            if candidates.isEmpty {
                // The artist may be spelled differently on disk (accents, "&" vs "and"): search the
                // title alone and check the artist in the path instead.
                let titleOnly = TrackMatcher.searchQuery(for: song, includeArtist: false)
                if titleOnly != query, titleOnly.split(separator: " ").count >= 2 || titleOnly.count >= 6 {
                    candidates = await search(titleOnly, for: song, requireArtistInPath: true)
                    if Task.isCancelled { return }
                }
            }
            guard job?.songs.indices.contains(position) == true else { return }
            if candidates.isEmpty {
                markNotFound(position, reason: "No match on Soulseek")
            } else {
                startDownload(position, candidates: candidates)
            }
        }
    }

    /// Waits until Soulseek is connected and fewer than `maxActiveDownloads` of ours are running.
    /// False if the import was cancelled.
    private func waitForCapacity() async -> Bool {
        var waited = 0
        while !Task.isCancelled {
            let connected = soulseek.isLoggedIn
            if waitingForSoulseek == connected { waitingForSoulseek = !connected }
            if connected, active.count < Self.maxActiveDownloads { return true }
            if !connected, waited % 30 == 0 { soulseek.reconnectIfNeeded() }
            waited += 1
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }

    /// The next song to look for, skipping copies of a song that's already being looked for
    /// (they share its result when it lands).
    private func nextSongToSearch() -> Int? {
        guard let songs = job?.songs else { return nil }
        let busy = Set(songs.filter(\.status.isBusy).map { Self.key($0.song) })
        return songs.firstIndex { $0.status == .waiting && !busy.contains(Self.key($0.song)) }
    }

    private func search(_ query: String, for song: WantedSong, requireArtistInPath: Bool) async -> [Candidate] {
        guard !query.isEmpty else { return [] }
        let wait = Self.searchSpacing - Date().timeIntervalSince(lastSearchAt)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        guard !Task.isCancelled, await waitForCapacity() else { return [] }

        collected = []
        guard let token = soulseek.sideSearch(query, onResponse: { [weak self] response in
            self?.collected.append(response)
        }) else { return [] }
        lastSearchAt = Date()
        try? await Task.sleep(nanoseconds: UInt64(Self.searchWindow * 1_000_000_000))
        soulseek.endSideSearch(token)
        let responses = collected
        collected = []
        return rank(responses, for: song, requireArtistInPath: requireArtistInPath)
    }

    /// The best file from each user, best first, at most five (the rest are fallbacks if a
    /// download fails or stalls).
    private func rank(_ responses: [SearchResponse], for song: WantedSong, requireArtistInPath: Bool) -> [Candidate] {
        let wanted = TrackMatcher.Prepared(song)
        let ownName = soulseek.username.lowercased()
        var bestPerUser: [String: Candidate] = [:]
        for response in responses where response.username.lowercased() != ownName {
            for file in response.files {
                guard let score = TrackMatcher.score(file, slotFree: response.slotFree, queueLength: response.queueLength,
                                                     speed: response.averageSpeed, for: wanted,
                                                     requireArtistInPath: requireArtistInPath) else { continue }
                if score > bestPerUser[response.username]?.score ?? .min {
                    bestPerUser[response.username] = Candidate(username: response.username, file: file, score: score)
                }
            }
        }
        return Array(bestPerUser.values.sorted { $0.score > $1.score }.prefix(5))
    }

    // MARK: Downloads

    private func startDownload(_ position: Int, candidates: [Candidate]) {
        var remaining = candidates
        guard !remaining.isEmpty else {
            markNotFound(position, reason: "No match on Soulseek")
            return
        }
        let candidate = remaining.removeFirst()
        let id = DownloadID(username: candidate.username, path: candidate.file.path)
        update(position) {
            $0.status = .downloading(0)
            $0.detail = Self.describe(candidate)
        }

        // This exact file was downloaded before.
        if let state = soulseek.state(of: candidate.file, from: candidate.username) {
            switch state {
            case let .completed(url):
                if let track = library.track(at: url) {
                    resolve(position, track: track, status: .added)
                    return
                }
                if FileManager.default.fileExists(atPath: url.path) {
                    awaitingLibrary[url] = position
                    update(position) { $0.status = .downloading(1) }
                    library.rescan()
                    return
                }
                soulseek.remove([id])  // Deleted since: let the client fetch it again.
            case .failed:
                soulseek.remove([id])
            default:
                // Already running (started from Search): follow that download.
                active[id] = ActiveDownload(song: position, fallbacks: remaining, lastProgressAt: Date(), lastReceived: 0)
                return
            }
        }

        active[id] = ActiveDownload(song: position, fallbacks: remaining, lastProgressAt: Date(), lastReceived: 0)
        soulseek.download(candidate.file, from: candidate.username)
    }

    private func handle(_ update: DownloadUpdate) {
        guard var download = active[update.id] else { return }
        switch update.state {
        case .transferring:
            if update.received > download.lastReceived {
                download.lastReceived = update.received
                download.lastProgressAt = Date()
                active[update.id] = download
            }
            let fraction = update.size > 0 ? min(1, Double(update.received) / Double(update.size)) : 0
            // Coarse steps keep a long list from redrawing on every packet.
            if case let .downloading(shown)? = job?.songs[download.song].status, fraction - shown < 0.02 { return }
            self.update(download.song) { $0.status = .downloading(fraction) }

        case let .completed(url):
            active[update.id] = nil
            awaitingLibrary[url] = download.song
            self.update(download.song) { $0.status = .downloading(1) }
            resolveFinished()

        case let .failed(reason):
            active[update.id] = nil
            // We move on to another peer; don't leave the failure in the Downloads list.
            soulseek.remove([update.id])
            Diagnostics.shared.log("Import: \(update.id.username) failed (\(reason)), trying the next file", category: "import")
            startNext(download, reason: reason)

        case .requesting, .queued, .starting:
            break
        }
    }

    private func startNext(_ download: ActiveDownload, reason: String) {
        if download.fallbacks.isEmpty {
            markNotFound(download.song, reason: "Download failed: \(reason)")
        } else {
            startDownload(download.song, candidates: download.fallbacks)
        }
    }

    private func checkStalls() {
        let now = Date()
        for (id, download) in active where now.timeIntervalSince(download.lastProgressAt) > Self.stallTimeout {
            active[id] = nil
            soulseek.remove([id])
            Diagnostics.shared.log("Import: \(id.username) made no progress, trying the next file", category: "import")
            startNext(download, reason: "peer didn't send the file")
        }
        resolveFinished()
    }

    /// Picks up finished downloads once the library scan has them.
    private func resolveFinished() {
        for (url, position) in awaitingLibrary {
            if let track = library.track(at: url) {
                awaitingLibrary[url] = nil
                resolve(position, track: track, status: .added)
            } else if !FileManager.default.fileExists(atPath: url.path) {
                awaitingLibrary[url] = nil
                markNotFound(position, reason: "The downloaded file is gone")
            }
        }
    }

    // MARK: Results

    private func matchLibrary() {
        guard let songs = job?.songs else { return }
        refreshIndex()
        for song in songs where song.status == .waiting {
            if let track = index.match(song.song) {
                update(song.id) {
                    $0.status = .inLibrary
                    $0.trackID = track.id
                }
            }
        }
    }

    private func resolve(_ position: Int, track: Track, status: ImportSong.Status) {
        guard let songs = job?.songs, songs.indices.contains(position) else { return }
        let key = Self.key(songs[position].song)
        for other in songs.indices where other == position || (songs[other].status == .waiting && Self.key(songs[other].song) == key) {
            update(other) {
                $0.status = status
                $0.trackID = track.id
            }
        }
        syncPlaylist()
        checkFinished()
    }

    private func markNotFound(_ position: Int, reason: String) {
        guard let songs = job?.songs, songs.indices.contains(position) else { return }
        let key = Self.key(songs[position].song)
        for other in songs.indices where other == position || (songs[other].status == .waiting && Self.key(songs[other].song) == key) {
            update(other) {
                $0.status = .notFound(reason)
                $0.detail = nil
            }
        }
        checkFinished()
    }

    private func update(_ position: Int, _ change: (inout ImportSong) -> Void) {
        guard var current = job, current.songs.indices.contains(position) else { return }
        change(&current.songs[position])
        job = current
    }

    /// Writes the found songs into the playlist, in the source's order.
    private func syncPlaylist() {
        guard let current = job else { return }
        var playlistID = current.playlistID
        if playlists.playlist(id: playlistID) == nil {
            // Deleted mid-import: make it again.
            playlistID = playlists.create(named: current.name).id
            job?.playlistID = playlistID
            var mapping = UserDefaults.standard.dictionary(forKey: Self.mappingKey) as? [String: String] ?? [:]
            mapping[current.sourceKey] = playlistID.uuidString
            UserDefaults.standard.set(mapping, forKey: Self.mappingKey)
        }
        playlists.setTrackIDs(current.songs.compactMap(\.trackID), for: playlistID)
    }

    private func checkFinished() {
        guard let current = job, current.isRunning, current.pendingCount == 0, active.isEmpty, awaitingLibrary.isEmpty else { return }
        job?.isRunning = false
        stopRunning()
        Diagnostics.shared.log("Imported \(current.name): \(current.addedCount) downloaded, \(current.inLibraryCount) already in library, \(current.notFoundCount) not found", category: "import")
    }

    private func stopRunning() {
        worker?.cancel()
        worker = nil
        watchdog?.invalidate()
        watchdog = nil
        waitingForSoulseek = false
        soulseek.isImportingPlaylist = false
    }

    private func refreshIndex() {
        guard library.scanRevision != indexRevision else { return }
        index = LibraryIndex(library.tracks)
        indexRevision = library.scanRevision
    }

    private static func key(_ song: WantedSong) -> String {
        TrackMatcher.normalizeTitle(song.title) + "|" + TrackMatcher.normalizeName(song.primaryArtist)
    }

    private static func describe(_ candidate: Candidate) -> String {
        let file = candidate.file
        var format = file.fileExtension.uppercased()
        if let depth = file.attributes.bitDepth, let rate = file.attributes.sampleRate {
            format += " \(depth)/\(Formatting.kilohertz(rate))"
        } else if let bitrate = file.attributes.bitrate {
            format += " \(bitrate)k"
        }
        return format + " · " + candidate.username
    }
}
