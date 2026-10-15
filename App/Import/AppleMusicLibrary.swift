import Foundation
import MediaPlayer

struct AppleMusicPlaylist: Identifiable, Hashable {
    let id: UInt64
    let name: String
    let songCount: Int
    let isSmart: Bool
}

/// Playlists in the Music app's library on this phone, read with MediaPlayer. Only the song
/// details are used; the songs themselves come from your library or Soulseek.
@MainActor
final class AppleMusicLibrary: ObservableObject {
    @Published private(set) var status = MPMediaLibrary.authorizationStatus()

    func requestAccess() async {
        guard status == .notDetermined else { return }
        let granted = await withCheckedContinuation { (continuation: CheckedContinuation<MPMediaLibraryAuthorizationStatus, Never>) in
            MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0) }
        }
        status = granted
    }

    func playlists() -> [AppleMusicPlaylist] {
        guard status == .authorized else { return [] }
        let collections = MPMediaQuery.playlists().collections ?? []
        return collections.compactMap { collection -> AppleMusicPlaylist? in
            guard let playlist = collection as? MPMediaPlaylist else { return nil }
            // Genius playlists are generated on the fly from one song; not worth keeping.
            if playlist.playlistAttributes.contains(.genius) { return nil }
            return AppleMusicPlaylist(id: playlist.persistentID,
                                      name: playlist.name ?? "Untitled Playlist",
                                      songCount: playlist.count,
                                      isSmart: playlist.playlistAttributes.contains(.smart))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func songs(inPlaylist id: UInt64) -> [WantedSong] {
        let query = MPMediaQuery.playlists()
        query.addFilterPredicate(MPMediaPropertyPredicate(value: NSNumber(value: id),
                                                          forProperty: MPMediaPlaylistPropertyPersistentID))
        guard let playlist = query.collections?.first as? MPMediaPlaylist else { return [] }
        return playlist.items.compactMap { item -> WantedSong? in
            guard let title = item.title, !title.isEmpty else { return nil }
            let artist = item.artist ?? item.albumArtist
            return WantedSong(title: title,
                              artists: artist.map { [$0] } ?? [],
                              album: item.albumTitle,
                              duration: item.playbackDuration > 0 ? item.playbackDuration : nil)
        }
    }
}
