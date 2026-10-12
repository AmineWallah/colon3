import Foundation

/// Favourite songs (by track id) and albums (by album id), saved as JSON.
@MainActor
final class FavoritesStore: ObservableObject {
    @Published private(set) var songs: Set<String> = []
    @Published private(set) var albums: Set<String> = []

    private struct Stored: Codable {
        var songs: [String]
        var albums: [String]
    }

    private let fileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("favorites.json")

    init() {
        if let data = try? Data(contentsOf: fileURL), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            songs = Set(stored.songs)
            albums = Set(stored.albums)
        }
    }

    func isFavorite(_ track: Track) -> Bool { songs.contains(track.id) }
    func isFavorite(_ album: Album) -> Bool { albums.contains(album.id) }

    func isFavorite(_ item: LibraryItem) -> Bool {
        switch item {
        case let .album(album): return isFavorite(album)
        case let .single(track): return isFavorite(track)
        }
    }

    func toggle(_ track: Track) { set(track, favorite: !isFavorite(track)) }
    func toggle(_ album: Album) { set(album, favorite: !isFavorite(album)) }

    func set(_ track: Track, favorite: Bool) {
        if favorite { songs.insert(track.id) } else { songs.remove(track.id) }
        save()
    }

    func set(_ album: Album, favorite: Bool) {
        if favorite { albums.insert(album.id) } else { albums.remove(album.id) }
        save()
    }

    func set(_ items: [LibraryItem], favorite: Bool) {
        for item in items {
            switch item {
            case let .album(album): if favorite { albums.insert(album.id) } else { albums.remove(album.id) }
            case let .single(track): if favorite { songs.insert(track.id) } else { songs.remove(track.id) }
            }
        }
        save()
    }

    func forget(_ tracks: [Track]) {
        for track in tracks { songs.remove(track.id) }
        save()
    }

    private func save() {
        let stored = Stored(songs: songs.sorted(), albums: albums.sorted())
        if let data = try? JSONEncoder().encode(stored) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
