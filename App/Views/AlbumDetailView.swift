import SwiftUI

struct AlbumDetailView: View {
    let album: Album

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var favorites: FavoritesStore
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDelete: [Track]?

    /// Re-read after rescans so edits and deletions show up.
    private var current: Album { library.album(id: album.id) ?? album }

    private struct Disc: Identifiable {
        let number: Int
        let tracks: [Track]
        var id: Int { number }
    }

    private var discs: [Disc] {
        let grouped = Dictionary(grouping: current.tracks, by: { $0.discNumber ?? 1 })
        return grouped.keys.sorted().map { Disc(number: $0, tracks: grouped[$0] ?? []) }
    }

    var body: some View {
        let album = current
        ScrollView {
            VStack(spacing: 6) {
                ArtworkView(source: .album(album), cornerRadius: 12)
                    .frame(maxWidth: 270)
                    .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
                    .padding(.top, 8)
                    .padding(.bottom, 14)

                Text(album.title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                if let artist = library.artist(named: album.artist) {
                    NavigationLink(value: artist) {
                        Text(album.artist).font(.title3).foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(album.artist).font(.title3).foregroundStyle(Color.accentColor)
                }
                HStack(spacing: 6) {
                    Text(details(album))
                    if album.tracks.allSatisfy({ ["flac", "alac", "wav", "aif", "aiff"].contains($0.fileExtension) }) {
                        BadgeLabel(text: "Lossless", systemImage: "waveform")
                    }
                    if album.isSpatial {
                        BadgeLabel(text: "Spatial", systemImage: "dot.radiowaves.left.and.right")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button { player.play(album.tracks) } label: {
                        Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    Button { player.play(album.tracks, shuffled: true) } label: {
                        Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .padding(.top, 12)
            }
            .padding(.horizontal, 20)

            LazyVStack(alignment: .leading, spacing: 0) {
                let showDiscs = discs.count > 1
                ForEach(discs) { disc in
                    if showDiscs {
                        Text("Disc \(disc.number)")
                            .font(.headline)
                            .padding(.horizontal, 20)
                            .padding(.top, 18)
                            .padding(.bottom, 4)
                    }
                    ForEach(Array(disc.tracks.enumerated()), id: \.element.id) { offset, track in
                        Button {
                            if let index = album.tracks.firstIndex(of: track) { player.play(album.tracks, startAt: index) }
                        } label: {
                            TrackRow(track: track, number: track.trackNumber ?? offset + 1, showArtwork: false,
                                     subtitle: track.artist != album.artist ? track.artist : nil)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            TrackMenuItems(tracks: [track]) { pendingDelete = $0 }
                        }
                        Divider().padding(.leading, 56)
                    }
                }
            }
            .padding(.top, 16)

            Text("\(album.tracks.count) song\(album.tracks.count == 1 ? "" : "s"), \(minutes(album.duration))")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    favorites.toggle(album)
                } label: {
                    Image(systemName: favorites.isFavorite(album) ? "star.fill" : "star")
                }
                Menu {
                    TrackMenuItems(tracks: album.tracks, album: album) { pendingDelete = $0 }
                    Button {
                        Task {
                            await ArtworkStore.shared.invalidate(.album(album))
                            library.bumpArtwork()
                        }
                    } label: {
                        Label("Refresh Artwork", systemImage: "photo.badge.arrow.down")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmDelete($pendingDelete) { deleted in
            // Leave the page once the whole album is gone.
            let remaining = Set(album.tracks.map(\.id)).subtracting(deleted.map(\.id))
            if remaining.isEmpty { dismiss() }
        }
    }

    private func details(_ album: Album) -> String {
        [album.year.map(String.init), "\(album.tracks.count) songs"].compactMap { $0 }.joined(separator: " · ")
    }

    private func minutes(_ seconds: Double) -> String {
        let total = Int(seconds / 60)
        return total >= 60 ? "\(total / 60) hr \(total % 60) min" : "\(total) minute\(total == 1 ? "" : "s")"
    }
}

struct ArtistDetailView: View {
    let artist: ArtistEntry

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: Player
    @State private var pendingDelete: [Track]?

    private var current: ArtistEntry { library.artist(named: artist.name) ?? artist }
    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        let artist = current
        let allTracks = artist.albums.flatMap(\.tracks) + artist.singles
        ScrollView {
            HStack(spacing: 12) {
                Button { player.play(allTracks) } label: {
                    Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                Button { player.play(allTracks, shuffled: true) } label: {
                    Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

            if !artist.albums.isEmpty {
                Text("Albums")
                    .font(.title3.weight(.bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                    ForEach(artist.albums) { album in
                        NavigationLink(value: album) {
                            VStack(alignment: .leading, spacing: 3) {
                                ArtworkView(source: .album(album), cornerRadius: 8)
                                Text(album.title).font(.subheadline.weight(.medium)).lineLimit(1)
                                Text(album.year.map(String.init) ?? " ")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }

            if !artist.singles.isEmpty {
                Text("Songs")
                    .font(.title3.weight(.bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                LazyVStack(spacing: 0) {
                    ForEach(artist.singles) { track in
                        Button {
                            if let index = artist.singles.firstIndex(of: track) { player.play(artist.singles, startAt: index) }
                        } label: {
                            TrackRow(track: track).padding(.horizontal, 20).padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { TrackMenuItems(tracks: [track]) { pendingDelete = $0 } }
                        Divider().padding(.leading, 80)
                    }
                }
            }
        }
        .padding(.bottom, 24)
        .navigationTitle(artist.name)
        .confirmDelete($pendingDelete)
    }
}
