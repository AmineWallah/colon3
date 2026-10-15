import Foundation

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
/// are added straight away, the rest are found on Soulseek through the shared SongFetcher (which
/// spaces searches out so the server isn't flooded), and the playlist fills in the original
/// order as songs arrive. Runs on its own, so closing the import screen doesn't stop it.
@MainActor
final class PlaylistImporter: ObservableObject {
    @Published private(set) var job: ImportJob?

    /// Songs being fetched at once. Searches still run one at a time inside the fetcher; this
    /// lets downloads overlap with the next searches.
    static let maxInFlight = 4

    private let soulseek: SoulseekModel
    private let library: LibraryStore
    private let playlists: PlaylistStore
    private let fetcher: SongFetcher

    private var worker: Task<Void, Never>?
    /// Fetches in flight by song position, each with a token so a stale task can't clear a
    /// newer one's entry after a retry.
    private var fetches: [Int: (token: UUID, task: Task<Void, Never>)] = [:]
    private var index = LibraryIndex([])
    private var indexRevision = -1

    private static let mappingKey = "import.playlists"

    init(soulseek: SoulseekModel, library: LibraryStore, playlists: PlaylistStore, fetcher: SongFetcher) {
        self.soulseek = soulseek
        self.library = library
        self.playlists = playlists
        self.fetcher = fetcher
    }

    var isRunning: Bool { job?.isRunning ?? false }

    // MARK: Control

    func start(name: String, source: ImportSource, sourceKey: String, songs: [WantedSong]) {
        guard !isRunning, !songs.isEmpty else { return }
        stopFetches()

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
        stopFetches()
        for position in current.songs.indices where current.songs[position].status.isPending {
            current.songs[position].status = .notFound("Cancelled")
            current.songs[position].detail = nil
        }
        current.isRunning = false
        job = current
        soulseek.isImportingPlaylist = false
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
        worker = Task { [weak self] in
            await self?.work()
        }
        checkFinished()
    }

    private func stopFetches() {
        worker?.cancel()
        worker = nil
        for entry in fetches.values { entry.task.cancel() }
        fetches.removeAll()
    }

    /// Starts fetches until every song has one or has finished. Songs listed twice wait for the
    /// first copy and share its result.
    private func work() async {
        while !Task.isCancelled {
            while fetches.count >= Self.maxInFlight {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
            }
            guard let position = nextSongToFetch(), let song = job?.songs[position].song else { return }

            // It may have arrived meanwhile: an earlier download, or added by hand.
            refreshIndex()
            if let track = index.match(song) {
                resolve(position, track: track, status: .inLibrary)
                continue
            }
            launch(position, song: song)
        }
    }

    private func launch(_ position: Int, song: WantedSong) {
        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.fetcher.fetch(song) { [weak self] progress in
                self?.apply(progress, to: position, token: token)
            }
            guard !Task.isCancelled, self.fetches[position]?.token == token else { return }
            self.fetches[position] = nil
            switch outcome {
            case let .found(track, downloaded):
                self.resolve(position, track: track, status: downloaded ? .added : .inLibrary)
            case let .notFound(reason):
                self.markNotFound(position, reason: reason)
            }
        }
        fetches[position] = (token, task)
    }

    private func apply(_ progress: SongFetcher.Progress, to position: Int, token: UUID) {
        guard fetches[position]?.token == token else { return }
        switch progress {
        case .searching:
            update(position) { $0.status = .searching }
        case let .downloading(fraction, source):
            update(position) {
                $0.status = .downloading(fraction)
                $0.detail = source
            }
        }
    }

    /// The next waiting song without a fetch, skipping copies of a song already being fetched.
    private func nextSongToFetch() -> Int? {
        guard let songs = job?.songs else { return nil }
        let busy = Set(fetches.keys.compactMap { songs.indices.contains($0) ? Self.key(songs[$0].song) : nil })
        return songs.firstIndex { song in
            song.status == .waiting && fetches[song.id] == nil && !busy.contains(Self.key(song.song))
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
        for other in songs.indices where other == position
            || (songs[other].status == .waiting && fetches[other] == nil && Self.key(songs[other].song) == key) {
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
        for other in songs.indices where other == position
            || (songs[other].status == .waiting && fetches[other] == nil && Self.key(songs[other].song) == key) {
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
        guard let current = job, current.isRunning, current.pendingCount == 0, fetches.isEmpty else { return }
        job?.isRunning = false
        worker?.cancel()
        worker = nil
        soulseek.isImportingPlaylist = false
        Diagnostics.shared.log("Imported \(current.name): \(current.addedCount) downloaded, \(current.inLibraryCount) already in library, \(current.notFoundCount) not found", category: "import")
    }

    private func refreshIndex() {
        guard library.scanRevision != indexRevision else { return }
        index = LibraryIndex(library.tracks)
        indexRevision = library.scanRevision
    }

    private static func key(_ song: WantedSong) -> String {
        TrackMatcher.songKey(song)
    }
}
