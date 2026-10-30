import AppIntents
import Combine
import Foundation

// Siri and Shortcuts, through App Intents: "Play music in colon3", "Play Road Trip in colon3",
// "Shuffle colon3", "Pause colon3", … No SiriKit extension or entitlement is needed, so this
// works in sideloaded builds too. The intents run inside the app (launched in the background
// if it isn't running) and use the same player and library as the screen.

/// The app's stores, for intents. Set up once at launch.
@MainActor
enum AppServices {
    static weak var player: Player?
    static weak var library: LibraryStore?
    static weak var playlists: PlaylistStore?
    static weak var favorites: FavoritesStore?
    private static var subscriptions = Set<AnyCancellable>()

    static func configure(player: Player, library: LibraryStore, playlists: PlaylistStore, favorites: FavoritesStore) {
        self.player = player
        self.library = library
        self.playlists = playlists
        self.favorites = favorites
        // Siri learns playlist names for "Play <playlist> in colon3" from this.
        playlists.$playlists
            .map { $0.map(\.name) }
            .removeDuplicates()
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { _ in Colon3Shortcuts.updateAppShortcutParameters() }
            .store(in: &subscriptions)
    }

    /// The player, and the library once it has loaded (an intent can launch the app in the
    /// background, before anything scanned the Music folder).
    static func ready() async throws -> (Player, LibraryStore) {
        guard let player, let library else { throw SiriError.notReady }
        if library.scanRevision == 0 {
            if !library.isScanning { library.rescan() }
            for _ in 0..<150 where library.scanRevision == 0 {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        return (player, library)
    }
}

enum SiriError: Error, CustomLocalizedStringResourceConvertible {
    case notReady
    case emptyLibrary
    case notFound(String)
    case emptyPlaylist(String)
    case noFavorites

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady:
            return "colon3 isn't ready yet. Try again in a moment."
        case .emptyLibrary:
            return "There's no music in colon3 yet."
        case let .notFound(query):
            return "I couldn't find \(query) in your colon3 library."
        case let .emptyPlaylist(name):
            return "None of the songs in \(name) are on this phone."
        case .noFavorites:
            return "You haven't favourited any songs or albums yet."
        }
    }
}

// MARK: Playlists

struct PlaylistEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Playlist"
    static let defaultQuery = PlaylistEntityQuery()

    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct PlaylistEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [PlaylistEntity] {
        let all = AppServices.playlists?.playlists ?? []
        return identifiers.compactMap { id in
            all.first { $0.id == id }.map { PlaylistEntity(id: $0.id, name: $0.name) }
        }
    }

    @MainActor
    func entities(matching string: String) async throws -> [PlaylistEntity] {
        let wanted = TrackMatcher.normalizeName(string)
        return (AppServices.playlists?.playlists ?? [])
            .filter { TrackMatcher.normalizeName($0.name).contains(wanted) }
            .map { PlaylistEntity(id: $0.id, name: $0.name) }
    }

    @MainActor
    func suggestedEntities() async throws -> [PlaylistEntity] {
        (AppServices.playlists?.playlists ?? []).map { PlaylistEntity(id: $0.id, name: $0.name) }
    }
}

// MARK: Intents

struct PlayMusicIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Music"

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (player, library) = try await AppServices.ready()
        if player.current != nil {
            player.resume()
            return .result(dialog: "Resuming.")
        }
        guard !library.tracks.isEmpty else { throw SiriError.emptyLibrary }
        player.play(library.tracks, shuffled: true)
        return .result(dialog: "Shuffling your library.")
    }
}

struct PlaySearchIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Song, Album or Artist"

    @Parameter(title: "Song, Album or Artist", requestValueDialog: "What do you want to hear?")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$query)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (player, library) = try await AppServices.ready()
        guard let match = LibrarySearch.best(for: query, in: library) else { throw SiriError.notFound(query) }
        player.play(match.tracks, startAt: match.startIndex, shuffled: match.shuffled)
        return .result(dialog: "Playing \(match.name).")
    }
}

struct ShuffleLibraryIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Shuffle Library"

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (player, library) = try await AppServices.ready()
        guard !library.tracks.isEmpty else { throw SiriError.emptyLibrary }
        player.play(library.tracks, shuffled: true)
        return .result(dialog: "Shuffling your library.")
    }
}

struct PlayPlaylistIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Playlist"

    @Parameter(title: "Playlist")
    var playlist: PlaylistEntity

    @Parameter(title: "Shuffle", default: false)
    var shuffle: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$playlist)") {
            \.$shuffle
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (player, library) = try await AppServices.ready()
        guard let store = AppServices.playlists, let found = store.playlist(id: playlist.id) else {
            throw SiriError.notFound(playlist.name)
        }
        let tracks = store.tracks(of: found, in: library)
        guard !tracks.isEmpty else { throw SiriError.emptyPlaylist(found.name) }
        player.play(tracks, shuffled: shuffle)
        if shuffle {
            return .result(dialog: "Shuffling \(found.name).")
        }
        return .result(dialog: "Playing \(found.name).")
    }
}

struct ShufflePlaylistIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Shuffle Playlist"

    @Parameter(title: "Playlist")
    var playlist: PlaylistEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Shuffle \(\.$playlist)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (player, library) = try await AppServices.ready()
        guard let store = AppServices.playlists, let found = store.playlist(id: playlist.id) else {
            throw SiriError.notFound(playlist.name)
        }
        let tracks = store.tracks(of: found, in: library)
        guard !tracks.isEmpty else { throw SiriError.emptyPlaylist(found.name) }
        player.play(tracks, shuffled: true)
        return .result(dialog: "Shuffling \(found.name).")
    }
}

struct PlayFavoritesIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Favourites"

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (player, library) = try await AppServices.ready()
        guard let favorites = AppServices.favorites else { throw SiriError.notReady }
        var seen = Set<String>()
        var tracks: [Track] = []
        for id in favorites.songs.sorted() {
            if let track = library.track(id: id), seen.insert(track.id).inserted { tracks.append(track) }
        }
        for id in favorites.albums.sorted() {
            for track in library.album(id: id)?.tracks ?? [] where seen.insert(track.id).inserted {
                tracks.append(track)
            }
        }
        guard !tracks.isEmpty else { throw SiriError.noFavorites }
        player.play(tracks, shuffled: true)
        return .result(dialog: "Shuffling your favourites.")
    }
}

struct PausePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Pause"

    @MainActor
    func perform() async throws -> some IntentResult {
        AppServices.player?.pause()
        return .result()
    }
}

struct NextTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Next Song"

    @MainActor
    func perform() async throws -> some IntentResult {
        AppServices.player?.next()
        return .result()
    }
}

struct PreviousTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Previous Song"

    @MainActor
    func perform() async throws -> some IntentResult {
        AppServices.player?.previous()
        return .result()
    }
}

struct NowPlayingIntent: AppIntent {
    static let title: LocalizedStringResource = "What's Playing"

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let player = AppServices.player, let track = player.current else {
            return .result(dialog: "Nothing is playing in colon3.")
        }
        let verb = player.isPlaying ? "This is" : "Paused on"
        return .result(dialog: "\(verb) \(track.title) by \(track.artist).")
    }
}

// MARK: Phrases

/// The phrases Siri knows without any setup. Each must name the app; at most 10 shortcuts.
struct Colon3Shortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayMusicIntent(), phrases: [
            "Play music in \(.applicationName)",
            "Play \(.applicationName)",
            "Resume \(.applicationName)",
        ], shortTitle: "Play Music", systemImageName: "play.fill")
        AppShortcut(intent: PlaySearchIntent(), phrases: [
            "Play a song in \(.applicationName)",
            "Play something in \(.applicationName)",
            "Search \(.applicationName)",
        ], shortTitle: "Play a Song", systemImageName: "magnifyingglass")
        AppShortcut(intent: PlayPlaylistIntent(), phrases: [
            "Play \(\.$playlist) in \(.applicationName)",
            "Play my \(\.$playlist) playlist in \(.applicationName)",
            "Play a playlist in \(.applicationName)",
        ], shortTitle: "Play Playlist", systemImageName: "music.note.list")
        AppShortcut(intent: ShufflePlaylistIntent(), phrases: [
            "Shuffle \(\.$playlist) in \(.applicationName)",
            "Shuffle my \(\.$playlist) playlist in \(.applicationName)",
        ], shortTitle: "Shuffle Playlist", systemImageName: "shuffle")
        AppShortcut(intent: ShuffleLibraryIntent(), phrases: [
            "Shuffle \(.applicationName)",
            "Shuffle my music in \(.applicationName)",
            "Shuffle my library in \(.applicationName)",
        ], shortTitle: "Shuffle Library", systemImageName: "shuffle")
        AppShortcut(intent: PlayFavoritesIntent(), phrases: [
            "Play my favorites in \(.applicationName)",
            "Play my favourites in \(.applicationName)",
            "Shuffle my favorites in \(.applicationName)",
        ], shortTitle: "Play Favourites", systemImageName: "heart.fill")
        AppShortcut(intent: PausePlaybackIntent(), phrases: [
            "Pause \(.applicationName)",
            "Stop \(.applicationName)",
        ], shortTitle: "Pause", systemImageName: "pause.fill")
        AppShortcut(intent: NextTrackIntent(), phrases: [
            "Next song in \(.applicationName)",
            "Skip this song in \(.applicationName)",
        ], shortTitle: "Next Song", systemImageName: "forward.fill")
        AppShortcut(intent: PreviousTrackIntent(), phrases: [
            "Previous song in \(.applicationName)",
            "Go back in \(.applicationName)",
        ], shortTitle: "Previous Song", systemImageName: "backward.fill")
        AppShortcut(intent: NowPlayingIntent(), phrases: [
            "What's playing in \(.applicationName)",
            "What song is this in \(.applicationName)",
        ], shortTitle: "What's Playing", systemImageName: "music.note")
    }
}

// MARK: Search

/// Finds what "Play <query>" means in the library: a song, an album or an artist.
@MainActor
enum LibrarySearch {
    struct Match {
        let name: String
        let tracks: [Track]
        var startIndex = 0
        var shuffled = false
    }

    static func best(for query: String, in library: LibraryStore) -> Match? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // "Song by Artist"
        let parts = trimmed.components(separatedBy: " by ")
        if parts.count == 2 {
            let title = key(parts[0])
            let artist = key(parts[1])
            if let track = library.tracks.first(where: { key($0.title) == title && artistMatches($0, artist) }) {
                return songMatch(track, in: library)
            }
            if let album = library.albums.first(where: { key($0.title) == title && key($0.artist).contains(artist) }) {
                return Match(name: "\(album.title) by \(album.artist)", tracks: album.tracks)
            }
        }

        let wanted = key(trimmed)
        guard !wanted.isEmpty else { return nil }

        // Exact names first: a song, then an album, then an artist.
        if let track = library.tracks.first(where: { key($0.title) == wanted }) {
            return songMatch(track, in: library)
        }
        if let album = library.albums.first(where: { key($0.title) == wanted }) {
            return Match(name: "\(album.title) by \(album.artist)", tracks: album.tracks)
        }
        if let artist = library.artists.first(where: { key($0.name) == wanted }) {
            return artistMatch(artist)
        }

        // Then partial ones, in the same order.
        if let track = library.tracks.first(where: { key($0.title).contains(wanted) }) {
            return songMatch(track, in: library)
        }
        if let album = library.albums.first(where: { key($0.title).contains(wanted) }) {
            return Match(name: "\(album.title) by \(album.artist)", tracks: album.tracks)
        }
        if let artist = library.artists.first(where: { key($0.name).contains(wanted) }) {
            return artistMatch(artist)
        }
        return nil
    }

    private static func key(_ text: String) -> String {
        TrackMatcher.normalizeName(text)
    }

    private static func artistMatches(_ track: Track, _ artist: String) -> Bool {
        key(track.artist).contains(artist) || (track.albumArtist.map { key($0).contains(artist) } ?? false)
    }

    /// A song plays from its place in its album, so the album carries on after it.
    private static func songMatch(_ track: Track, in library: LibraryStore) -> Match {
        let name = "\(track.title) by \(track.artist)"
        if let album = library.album(containing: track), let index = album.tracks.firstIndex(of: track) {
            return Match(name: name, tracks: album.tracks, startIndex: index)
        }
        return Match(name: name, tracks: [track])
    }

    private static func artistMatch(_ artist: ArtistEntry) -> Match {
        let tracks = artist.albums.flatMap(\.tracks) + artist.singles
        return Match(name: artist.name, tracks: tracks, shuffled: true)
    }
}
