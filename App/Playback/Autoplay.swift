import Foundation

/// A song autoplay has lined up. Library songs are ready at once; discoveries (Last.fm picks
/// that aren't in the library) are searched and downloaded from Soulseek before they can play.
struct AutoplayItem: Identifiable, Equatable {
    enum State: Equatable {
        case ready(Track)
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
        AutoplayItem(id: "d:" + TrackMatcher.songKey(song), song: song, isDiscovery: true, state: .waiting)
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

    private static let perArtistLimit = 3

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

        func discover(_ song: WantedSong) {
            let key = TrackMatcher.songKey(song)
            let artist = TrackMatcher.normalizeName(song.primaryArtist)
            guard picked.count < count, discoveries < maxDiscoveries, !usedSongs.contains(key),
                  perArtist[artist, default: 0] < AutoplayRecommender.perArtistLimit else { return }
            perArtist[artist, default: 0] += 1
            usedSongs.insert(key)
            discoveries += 1
            picked.append(.discovery(song))
        }

        if let apiKey = LastFM.publicAPIKey {
            // A little randomness so the same seed doesn't always give the same order.
            let similar = await similarTracks(to: seed, apiKey: apiKey)
                .map { ($0, $0.match * Double.random(in: 0.7...1)) }
                .sorted { $0.1 > $1.1 }
                .map { $0.0 }
            refreshIndex(library)
            for song in similar where picked.count < count {
                let wanted = WantedSong(title: song.title, artists: [song.artist], duration: song.duration)
                if let track = index.match(wanted) {
                    if !take(track) { usedSongs.insert(TrackMatcher.songKey(wanted)) }
                } else {
                    discover(wanted)
                }
            }

            if picked.count < count {
                let artists = await similarArtists(to: seed.artist, apiKey: apiKey)
                    .map { ($0, $0.match * Double.random(in: 0.6...1)) }
                    .sorted { $0.1 > $1.1 }
                    .map { $0.0 }
                refreshIndex(library)
                for artist in artists where picked.count < count {
                    var fromThisArtist = 0
                    for track in index.tracks(byArtist: artist.name).shuffled() where fromThisArtist < 2 {
                        if take(track) { fromThisArtist += 1 }
                    }
                }
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

    private func similarTracks(to seed: AutoplaySeed, apiKey: String) async -> [LastFMSimilarTrack] {
        let key = TrackMatcher.normalizeName(seed.artist) + "|" + TrackMatcher.normalizeTitle(seed.title)
        if let cached = trackCache[key] { return cached }
        do {
            let result = try await LastFM.similarTracks(artist: seed.artist, track: seed.title, apiKey: apiKey)
            if trackCache.count > 300 { trackCache.removeAll() }
            trackCache[key] = result
            return result
        } catch {
            Diagnostics.shared.log("Autoplay: Last.fm similar tracks failed: \(error.localizedDescription)", category: "autoplay")
            return []
        }
    }

    private func similarArtists(to artist: String, apiKey: String) async -> [LastFMSimilarArtist] {
        let key = TrackMatcher.normalizeName(artist)
        if let cached = artistCache[key] { return cached }
        do {
            let result = try await LastFM.similarArtists(artist: artist, apiKey: apiKey)
            if artistCache.count > 300 { artistCache.removeAll() }
            artistCache[key] = result
            return result
        } catch {
            Diagnostics.shared.log("Autoplay: Last.fm similar artists failed: \(error.localizedDescription)", category: "autoplay")
            return []
        }
    }
}
