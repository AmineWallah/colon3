import Foundation

/// Picks library songs to keep playing after the queue ends.
///
/// In order: songs Last.fm calls similar to the seed (track.getSimilar), songs by artists it calls
/// similar (artist.getSimilar), more by the seed's artist, your most played, then anything.
/// Last.fm is only asked when an API key is saved; both calls need just the key. At most three
/// songs per artist go into one batch so autoplay doesn't get stuck on one artist.
@MainActor
final class AutoplayRecommender {
    weak var library: LibraryStore?
    weak var stats: StatsStore?

    private var index = LibraryIndex([])
    private var indexRevision = -1
    private var trackCache: [String: [LastFMSimilarTrack]] = [:]
    private var artistCache: [String: [LastFMSimilarArtist]] = [:]

    private static let perArtistLimit = 3

    func recommendations(after seed: Track, count: Int, excluding excluded: Set<String>) async -> [Track] {
        guard count > 0, let library, library.tracks.count > 1 else { return [] }
        refreshIndex(library)

        var picked: [Track] = []
        var used = excluded
        used.insert(seed.id)
        var perArtist: [String: Int] = [:]

        func take(_ track: Track, artistLimit: Int = AutoplayRecommender.perArtistLimit) -> Bool {
            guard picked.count < count, !used.contains(track.id) else { return false }
            let artist = TrackMatcher.normalizeName(track.artist)
            guard perArtist[artist, default: 0] < artistLimit else { return false }
            perArtist[artist, default: 0] += 1
            used.insert(track.id)
            picked.append(track)
            return true
        }

        if let apiKey = LastFM.publicAPIKey {
            // A little randomness so the same seed doesn't always give the same order.
            let similar = await similarTracks(to: seed, apiKey: apiKey)
                .map { ($0, $0.match * Double.random(in: 0.7...1)) }
                .sorted { $0.1 > $1.1 }
                .map { $0.0 }
            for song in similar where picked.count < count {
                if let track = index.match(WantedSong(title: song.title, artists: [song.artist])) {
                    _ = take(track)
                }
            }

            if picked.count < count {
                let artists = await similarArtists(to: seed.artist, apiKey: apiKey)
                    .map { ($0, $0.match * Double.random(in: 0.6...1)) }
                    .sorted { $0.1 > $1.1 }
                    .map { $0.0 }
                for artist in artists where picked.count < count {
                    var fromThisArtist = 0
                    for track in index.tracks(byArtist: artist.name).shuffled() where fromThisArtist < 2 {
                        if take(track) { fromThisArtist += 1 }
                    }
                }
            }
        }

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

    private func similarTracks(to seed: Track, apiKey: String) async -> [LastFMSimilarTrack] {
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
