import Foundation

/// A song autoplay has lined up. Library songs are ready at once; discoveries (Last.fm picks
/// that aren't in the library) are searched and downloaded from Soulseek before they can play.
struct AutoplayItem: Identifiable, Equatable {
    enum State: Equatable {
        case ready(Track)
        /// A suggestion you don't have; downloads only once you confirm it (or with automatic
        /// downloads on).
        case offered
        /// Confirmed, waiting for a download slot.
        case waiting
        case searching
        case downloading(Double)
    }

    let id: String
    let song: WantedSong
    let isDiscovery: Bool
    var state: State

    var track: Track? {
        if case let .ready(track) = state { return track }
        return nil
    }

    static func library(_ track: Track) -> AutoplayItem {
        AutoplayItem(id: "t:" + track.id, song: WantedSong(title: track.title, artists: [track.artist]),
                     isDiscovery: false, state: .ready(track))
    }

    static func discovery(_ song: WantedSong) -> AutoplayItem {
        AutoplayItem(id: "d:" + TrackMatcher.songKey(song), song: song, isDiscovery: true, state: .offered)
    }
}

/// The song autoplay continues from.
struct AutoplaySeed {
    let title: String
    let artist: String

    init(_ track: Track) {
        title = track.title
        artist = track.artist
    }

    init(_ song: WantedSong) {
        title = song.title
        artist = song.primaryArtist
    }
}

/// Picks what autoplay plays after the queue ends.
///
/// In order: songs Last.fm calls similar to the seed (track.getSimilar), songs by artists it calls
/// similar (artist.getSimilar), more by the seed's artist, your most played, then anything.
/// Last.fm is only asked when an API key is saved; both calls need just the key. Similar songs
/// that aren't in the library can come back as discoveries (up to `maxDiscoveries`), which the
/// player downloads from Soulseek ahead of time. At most three songs per artist go into one
/// batch so autoplay doesn't get stuck on one artist.
@MainActor
final class AutoplayRecommender {
    weak var library: LibraryStore?
    weak var stats: StatsStore?

    private var index = LibraryIndex([])
    private var indexRevision = -1
    private var trackCache: [String: [LastFMSimilarTrack]] = [:]
    private var artistCache: [String: [LastFMSimilarArtist]] = [:]
    private var topTracksCache: [String: [LastFMSimilarTrack]] = [:]
    /// The last Last.fm error, for the note under Up Next.
    private var lastError: String?

    private static let perArtistLimit = 3
    /// Similar artists whose top tracks are fetched per batch, to find songs to download.
    private static let topTrackLookups = 4

    /// Set when Last.fm had nothing for the last seed (neither similar songs nor artists):
    /// why, in a sentence for Up Next. Nil when Last.fm wasn't asked or helped.
    private(set) var lastFMNote: String?

    /// - Parameters:
    ///   - excludedTracks: library track ids not to pick (queued, lined up, recently played).
    ///   - excludedSongs: `TrackMatcher.songKey`s not to discover (lined up, failed before).
    func recommendations(after seed: AutoplaySeed, count: Int, excludedTracks: Set<String>,
                         excludedSongs: Set<String>, maxDiscoveries: Int) async -> [AutoplayItem] {
        guard count > 0, let library else { return [] }
        refreshIndex(library)

        var picked: [AutoplayItem] = []
        var usedTracks = excludedTracks
        var usedSongs = excludedSongs
        usedSongs.insert(TrackMatcher.songKey(WantedSong(title: seed.title, artists: [seed.artist])))
        var perArtist: [String: Int] = [:]
        var discoveries = 0

        func take(_ track: Track, artistLimit: Int = AutoplayRecommender.perArtistLimit) -> Bool {
            guard picked.count < count, !usedTracks.contains(track.id) else { return false }
            let artist = TrackMatcher.normalizeName(track.artist)
            guard perArtist[artist, default: 0] < artistLimit else { return false }
            perArtist[artist, default: 0] += 1
            usedTracks.insert(track.id)
            picked.append(.library(track))
            return true
        }

        @discardableResult
        func discover(_ song: WantedSong) -> Bool {
            let key = TrackMatcher.songKey(song)
            let artist = TrackMatcher.normalizeName(song.primaryArtist)
            guard picked.count < count, discoveries < maxDiscoveries, !usedSongs.contains(key),
                  perArtist[artist, default: 0] < AutoplayRecommender.perArtistLimit else { return false }
            perArtist[artist, default: 0] += 1
            usedSongs.insert(key)
            discoveries += 1
            picked.append(.discovery(song))
            return true
        }

        /// While songs to download can still be found, library songs leave room for them, so
        /// a library full of similar artists doesn't crowd them out. Later steps fill any gap.
        func libraryHasRoom() -> Bool {
            picked.count < count - (maxDiscoveries - discoveries)
        }

        lastFMNote = nil
        if let apiKey = LastFM.publicAPIKey {
            lastError = nil
            // 1. Songs Last.fm calls similar. A little randomness so the same seed doesn't
            // always give the same order.
            let similar = await similarTracks(to: seed, apiKey: apiKey)
                .map { ($0, $0.match * Double.random(in: 0.7...1)) }
                .sorted { $0.1 > $1.1 }
                .map { $0.0 }
            refreshIndex(library)
            // No length: Last.fm's track.getSimilar doesn't document one, and a wrong unit would
            // reject every file. Title, artist and version checks still apply.
            for song in similar where picked.count < count {
                let wanted = WantedSong(title: song.title, artists: [song.artist])
                if let track = index.match(wanted) {
                    // In the library either way: never download it again.
                    if !libraryHasRoom() || !take(track) { usedSongs.insert(TrackMatcher.songKey(wanted)) }
                } else {
                    discover(wanted)
                }
            }
            let fromSimilarSongs = picked.count

            // 2. Similar artists: their songs in the library, and (for songs to download, since
            // track.getSimilar is often empty) a top track of theirs you don't have.
            var artists: [LastFMSimilarArtist] = []
            if picked.count < count {
                artists = await similarArtists(to: seed.artist, apiKey: apiKey)
                    .map { ($0, $0.match * Double.random(in: 0.6...1)) }
                    .sorted { $0.1 > $1.1 }
                    .map { $0.0 }
                refreshIndex(library)
                var lookups = 0
                for artist in artists where picked.count < count {
                    var fromThisArtist = 0
                    for track in index.tracks(byArtist: artist.name).shuffled() where fromThisArtist < 2 && libraryHasRoom() {
                        if take(track) { fromThisArtist += 1 }
                    }
                    guard discoveries < maxDiscoveries, lookups < Self.topTrackLookups, picked.count < count else { continue }
                    lookups += 1
                    let top = await topTracks(of: artist.name, apiKey: apiKey)
                    refreshIndex(library)
                    for song in top.prefix(10).shuffled() {
                        let wanted = WantedSong(title: song.title, artists: [song.artist])
                        if index.match(wanted) == nil, discover(wanted) { break }
                    }
                }
            }

            Diagnostics.shared.log("Autoplay: Last.fm has \(similar.count) similar songs and \(artists.count) similar artists "
                                   + "for \(seed.artist) – \(seed.title); picked \(fromSimilarSongs) from similar songs, "
                                   + "\(picked.count) in all, \(discoveries) to download (limit \(maxDiscoveries))",
                                   category: "autoplay")
            if similar.isEmpty, artists.isEmpty {
                lastFMNote = lastError.map { "Last.fm: \($0). Playing from your library." }
                    ?? "Last.fm has nothing similar to this song or artist, so these are from your library."
            }
        }

        guard library.tracks.count > 1 || !picked.isEmpty else { return picked }
        // The library may have changed while Last.fm answered.
        refreshIndex(library)

        for track in index.tracks(byArtist: seed.artist).shuffled() where picked.count < count {
            _ = take(track)
        }

        if picked.count < count, let stats {
            for track in stats.mostPlayed(limit: 100, in: library).shuffled() where picked.count < count {
                _ = take(track)
            }
        }

        for track in library.tracks.shuffled() where picked.count < count {
            _ = take(track)
        }
        // A library of one or two artists can't satisfy the per-artist limit.
        if picked.count < count {
            for track in library.tracks.shuffled() where picked.count < count {
                _ = take(track, artistLimit: .max)
            }
        }
        return picked
    }

    private func refreshIndex(_ library: LibraryStore) {
        guard library.scanRevision != indexRevision else { return }
        index = LibraryIndex(library.tracks)
        indexRevision = library.scanRevision
    }

    /// track.getSimilar with the cleaned-up title, first under the full artist credit (bands
    /// like "Earth, Wind & Fire" have commas), then under its first name ("A feat. B" → "A"),
    /// then with the tags exactly as they are. Stops at the first form Last.fm knows.
    private func similarTracks(to seed: AutoplaySeed, apiKey: String) async -> [LastFMSimilarTrack] {
        let title = TrackMatcher.lookupTitle(seed.title)
        var forms: [(String, String)] = [(seed.artist, title)]
        for form in [(TrackMatcher.lookupArtist(seed.artist), title), (seed.artist, seed.title)]
            where !forms.contains(where: { $0 == form }) {
            forms.append(form)
        }
        for (artist, title) in forms {
            let key = TrackMatcher.normalizeName(artist) + "|" + TrackMatcher.normalizeTitle(title)
            let result: [LastFMSimilarTrack]
            if let cached = trackCache[key] {
                result = cached
            } else {
                do {
                    result = try await LastFM.similarTracks(artist: artist, track: title, apiKey: apiKey)
                } catch {
                    lastError = error.localizedDescription
                    Diagnostics.shared.log("Autoplay: track.getSimilar \(artist) – \(title) failed: \(error.localizedDescription)", category: "autoplay")
                    result = []
                }
                if trackCache.count > 300 { trackCache.removeAll() }
                trackCache[key] = result
            }
            if !result.isEmpty { return result }
        }
        return []
    }

    /// artist.getSimilar for the full credit, then its first name.
    private func similarArtists(to credit: String, apiKey: String) async -> [LastFMSimilarArtist] {
        var names = [credit]
        if TrackMatcher.lookupArtist(credit) != credit { names.append(TrackMatcher.lookupArtist(credit)) }
        for name in names {
            let key = TrackMatcher.normalizeName(name)
            let result: [LastFMSimilarArtist]
            if let cached = artistCache[key] {
                result = cached
            } else {
                do {
                    result = try await LastFM.similarArtists(artist: name, apiKey: apiKey)
                } catch {
                    lastError = error.localizedDescription
                    Diagnostics.shared.log("Autoplay: artist.getSimilar \(name) failed: \(error.localizedDescription)", category: "autoplay")
                    result = []
                }
                if artistCache.count > 300 { artistCache.removeAll() }
                artistCache[key] = result
            }
            if !result.isEmpty { return result }
        }
        return []
    }

    private func topTracks(of artist: String, apiKey: String) async -> [LastFMSimilarTrack] {
        let key = TrackMatcher.normalizeName(artist)
        if let cached = topTracksCache[key] { return cached }
        do {
            let result = try await LastFM.topTracks(artist: artist, apiKey: apiKey)
            if topTracksCache.count > 300 { topTracksCache.removeAll() }
            topTracksCache[key] = result
            return result
        } catch {
            Diagnostics.shared.log("Autoplay: artist.getTopTracks \(artist) failed: \(error.localizedDescription)", category: "autoplay")
            return []
        }
    }
}
