import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: Player
    @State private var filter = ""

    private var albums: [Album] {
        let all = library.albums
        guard !filter.isEmpty else { return all }
        return all.compactMap { album in
            let matches = album.tracks.filter {
                $0.title.localizedCaseInsensitiveContains(filter)
                    || $0.artist.localizedCaseInsensitiveContains(filter)
                    || $0.album.localizedCaseInsensitiveContains(filter)
            }
            return matches.isEmpty ? nil : Album(name: album.name, tracks: matches)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(albums) { album in
                    Section(album.name) {
                        ForEach(album.tracks.indices, id: \.self) { offset in
                            let track = album.tracks[offset]
                            Button {
                                player.play(album.tracks, startAt: offset)
                            } label: {
                                TrackRow(track: track, isCurrent: player.current?.url == track.url)
                            }
                            .foregroundStyle(.primary)
                            .swipeActions {
                                Button(role: .destructive) {
                                    player.remove(track)
                                    library.delete(track)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Library")
            .searchable(text: $filter, prompt: "Filter")
            .refreshable { library.rescan() }
            .overlay {
                if library.tracks.isEmpty && !library.isScanning {
                    ContentUnavailableHint(title: "Nothing here yet",
                                           message: "Downloads land here. You can also copy music into Shoal › Music in the Files app.",
                                           systemImage: "music.note")
                }
            }
        }
    }
}

struct TrackRow: View {
    let track: Track
    let isCurrent: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isCurrent {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.tint)
            }
            Text(Formatting.duration(track.duration))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}
