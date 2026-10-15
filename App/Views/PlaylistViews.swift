import SwiftUI
import UIKit

enum PlaylistRoute: Hashable {
    case user(UUID)
    case favorites
    case mostPlayed
}

/// The Playlists scope of the library: smart lists first, then the user's own.
struct PlaylistsListContent: View {
    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var stats: StatsStore
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var importer: PlaylistImporter
    let query: String

    @State private var naming = false
    @State private var newName = ""

    private var favoriteTracks: [Track] { library.tracks.filter { favorites.isFavorite($0) } }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            Button {
                newName = ""
                naming = true
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "plus")
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 64, height: 64)
                        .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text("New Playlist…").foregroundStyle(.tint)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider().padding(.leading, 98)

            if let job = importer.job {
                importRow(job)
            }

            if query.isEmpty {
                row(route: .favorites, name: "Favorite Songs", tracks: favoriteTracks, symbol: "star.fill")
                row(route: .mostPlayed, name: "Most Played", tracks: stats.mostPlayed(limit: 4, in: library),
                    symbol: "chart.bar.fill", subtitle: "Top 50 by plays")
            }

            ForEach(playlists.playlists.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { playlist in
                let tracks = playlists.tracks(of: playlist, in: library)
                row(route: .user(playlist.id), name: playlist.name, tracks: tracks, symbol: nil)
                    .contextMenu {
                        Button { player.play(tracks) } label: {
                            Label("Play", systemImage: "play")
                        }
                        .disabled(tracks.isEmpty)
                        Button { player.play(tracks, shuffled: true) } label: {
                            Label("Shuffle", systemImage: "shuffle")
                        }
                        .disabled(tracks.isEmpty)
                        Button(role: .destructive) { playlists.delete(playlist) } label: {
                            Label("Delete Playlist", systemImage: "trash")
                        }
                    }
            }

            VStack(alignment: .leading, spacing: 0) {
                importButton("Import from Spotify…", systemImage: ImportSource.spotify.systemImage) {
                    router.importPlaylist(from: .spotify)
                }
                importButton("Import from Apple Music…", systemImage: ImportSource.appleMusic.systemImage) {
                    router.importPlaylist(from: .appleMusic)
                }
                importButton("Import .m3u Playlist…", systemImage: "square.and.arrow.down") {
                    router.importPlaylist()
                }
            }
            .padding(.vertical, 8)
        }
        .padding(.bottom, 24)
        .alert("New Playlist", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { playlists.create(named: newName) }
        }
    }

    private func importButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
        }
    }

    /// The running (or last finished) Spotify / Apple Music import; opens its progress.
    private func importRow(_ job: ImportJob) -> some View {
        Button {
            router.showImportProgress()
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.15))
                    if job.isRunning {
                        ProgressView()
                    } else {
                        Image(systemName: job.notFoundCount > 0 ? "exclamationmark.circle" : "checkmark.circle")
                            .font(.title2)
                            .foregroundStyle(.tint)
                    }
                }
                .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.isRunning ? "Importing “\(job.name)”" : "Imported “\(job.name)”").lineLimit(1)
                    Text(job.isRunning ? "\(job.doneCount) of \(job.songs.count) songs" : ImportProgressView.summary(job))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Divider().padding(.leading, 98) }
    }

    private func row(route: PlaylistRoute, name: String, tracks: [Track], symbol: String?, subtitle: String? = nil) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: 14) {
                PlaylistArtwork(tracks: tracks, symbol: symbol, size: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).lineLimit(1)
                    Text(subtitle ?? "\(tracks.count) song\(tracks.count == 1 ? "" : "s")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Divider().padding(.leading, 98) }
    }
}

/// A 2×2 mosaic of the first four different covers, like Apple Music.
struct PlaylistArtwork: View {
    let tracks: [Track]
    var symbol: String?
    let size: CGFloat

    @EnvironmentObject private var library: LibraryStore

    private var sources: [ArtworkSource] {
        var seen = Set<String>()
        var result: [ArtworkSource] = []
        for track in tracks {
            let source = library.artwork(for: track)
            if seen.insert(source.key).inserted { result.append(source) }
            if result.count == 4 { break }
        }
        return result
    }

    var body: some View {
        let covers = sources
        Group {
            if let symbol {
                ZStack {
                    Rectangle().fill(.tint)
                    LinearGradient(colors: [.white.opacity(0.18), .black.opacity(0.3)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.38, weight: .semibold))
                        .foregroundStyle(.white)
                }
            } else if covers.count >= 4 {
                let half = size / 2
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ArtworkView(source: covers[0], size: half, cornerRadius: 0)
                        ArtworkView(source: covers[1], size: half, cornerRadius: 0)
                    }
                    HStack(spacing: 0) {
                        ArtworkView(source: covers[2], size: half, cornerRadius: 0)
                        ArtworkView(source: covers[3], size: half, cornerRadius: 0)
                    }
                }
            } else if let first = covers.first {
                ArtworkView(source: first, size: size, cornerRadius: 0)
            } else {
                ZStack {
                    ArtworkPlaceholder()
                    Image(systemName: "music.note.list").font(.system(size: size * 0.3)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 100 ? 12 : 8, style: .continuous))
    }
}

struct PlaylistDetailView: View {
    let route: PlaylistRoute

    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var stats: StatsStore
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var router: AppRouter
    @Environment(\.dismiss) private var dismiss

    @State private var renaming = false
    @State private var newName = ""
    @State private var addingSongs = false
    @State private var confirmDelete = false
    @State private var exportURL: ExportFile?
    @State private var pendingDelete: [Track]?

    private var playlist: Playlist? {
        if case let .user(id) = route { return playlists.playlist(id: id) }
        return nil
    }

    private var name: String {
        switch route {
        case .user: return playlist?.name ?? "Playlist"
        case .favorites: return "Favorite Songs"
        case .mostPlayed: return "Most Played"
        }
    }

    private var tracks: [Track] {
        switch route {
        case .user: return playlist.map { playlists.tracks(of: $0, in: library) } ?? []
        case .favorites:
            return library.tracks.filter { favorites.isFavorite($0) }.sorted { SortKey.less($0.title, $1.title) }
        case .mostPlayed: return stats.mostPlayed(limit: 50, in: library)
        }
    }

    var body: some View {
        let tracks = self.tracks
        List {
            header(tracks)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 12, trailing: 20))

            ForEach(Array(tracks.enumerated()), id: \.offset) { offset, track in
                Button {
                    player.play(tracks, startAt: offset)
                } label: {
                    HStack(spacing: 10) {
                        if case .mostPlayed = route {
                            Text("\(offset + 1)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 22, alignment: .trailing)
                        }
                        TrackRow(track: track, subtitle: subtitle(for: track))
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    TrackMenuItems(tracks: [track]) { pendingDelete = $0 }
                }
            }
            .onMove(perform: moveAction)
            .onDelete(perform: deleteAction)

            if !tracks.isEmpty {
                Text("\(tracks.count) song\(tracks.count == 1 ? "" : "s"), \(Formatting.longDuration(tracks.reduce(0) { $0 + $1.duration }))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if tracks.isEmpty {
                EmptyStateView(title: "No Songs",
                               message: emptyMessage,
                               systemImage: "music.note.list")
                    .padding(.top, 200)
            }
        }
        .toolbar {
            if let playlist {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    EditButton()
                    Menu {
                        Button { addingSongs = true } label: { Label("Add Songs", systemImage: "plus") }
                        Button {
                            newName = playlist.name
                            renaming = true
                        } label: { Label("Rename", systemImage: "pencil") }
                        Button {
                            exportURL = playlists.exportM3U(playlist, library: library).map(ExportFile.init)
                        } label: { Label("Export .m3u8", systemImage: "square.and.arrow.up") }
                        Divider()
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Label("Delete Playlist", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .alert("Rename Playlist", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { if let playlist { playlists.rename(playlist, to: newName) } }
        }
        .confirmationDialog("Delete “\(name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Playlist", role: .destructive) {
                if let playlist { playlists.delete(playlist) }
                dismiss()
            }
        } message: {
            Text("The songs stay in your library.")
        }
        .sheet(isPresented: $addingSongs) {
            if let playlist { SongPickerSheet(playlist: playlist) }
        }
        .sheet(item: $exportURL) { file in
            ActivityView(items: [file.url]).presentationDetents([.medium, .large])
        }
        .confirmDelete($pendingDelete)
    }

    /// Only user playlists can be reordered or edited.
    private var moveAction: ((IndexSet, Int) -> Void)? {
        guard let playlist else { return nil }
        return { offsets, destination in
            playlists.move(from: offsets, to: destination, in: playlist, library: library)
        }
    }

    private var deleteAction: ((IndexSet) -> Void)? {
        guard let playlist else { return nil }
        return { offsets in playlists.remove(at: offsets, from: playlist, library: library) }
    }

    private var emptyMessage: String {
        switch route {
        case .user: return "Tap ⋯ › Add Songs, or long-press any song and choose Add to Playlist."
        case .favorites: return "Star songs to collect them here."
        case .mostPlayed: return "Songs you play show up here."
        }
    }

    private func subtitle(for track: Track) -> String {
        if case .mostPlayed = route {
            let plays = stats.plays(of: track)
            return "\(track.artist) · \(plays) play\(plays == 1 ? "" : "s")"
        }
        return track.artist
    }

    private func header(_ tracks: [Track]) -> some View {
        VStack(spacing: 10) {
            PlaylistArtwork(tracks: tracks, symbol: route == .favorites ? "star.fill" : (route == .mostPlayed ? "chart.bar.fill" : nil),
                            size: 220)
                .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
            Text(name).font(.title2.weight(.bold)).multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button { player.play(tracks) } label: {
                    Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                Button { player.play(tracks, shuffled: true) } label: {
                    Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(tracks.isEmpty)
        }
        .frame(maxWidth: .infinity)
    }
}

struct ExportFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// "Add to Playlist" from any song menu or selection.
struct AddToPlaylistSheet: View {
    let request: PlaylistRequest

    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Button {
                    newName = ""
                    naming = true
                } label: {
                    Label("New Playlist…", systemImage: "plus")
                }
                ForEach(playlists.playlists) { playlist in
                    Button {
                        playlists.add(request.tracks, to: playlist)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            PlaylistArtwork(tracks: playlists.tracks(of: playlist, in: library), size: 48)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.name).foregroundStyle(.primary)
                                Text("\(playlist.trackIDs.count) songs").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if request.tracks.allSatisfy({ playlist.trackIDs.contains($0.id) }) {
                                Image(systemName: "checkmark").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(request.tracks.count == 1 ? "Add to Playlist" : "Add \(request.tracks.count) Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .alert("New Playlist", isPresented: $naming) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    playlists.create(named: newName, with: request.tracks)
                    dismiss()
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Pick songs from the library to add to a playlist.
struct SongPickerSheet: View {
    let playlist: Playlist

    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var chosen: [String] = []

    private var results: [Track] {
        let sorted = library.tracks.sorted { SortKey.less($0.title, $1.title) }
        guard !query.isEmpty else { return sorted }
        return sorted.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query)
                || ($0.album ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List(results) { track in
                let picked = chosen.contains(track.id)
                let already = playlist.trackIDs.contains(track.id)
                Button {
                    if let index = chosen.firstIndex(of: track.id) { chosen.remove(at: index) } else { chosen.append(track.id) }
                } label: {
                    TrackRow(track: track, subtitle: track.artist, isSelected: picked || already)
                }
                .buttonStyle(.plain)
                .disabled(already)
            }
            .listStyle(.plain)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Songs, artists, albums")
            .navigationTitle("Add Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(chosen.isEmpty ? "Add" : "Add \(chosen.count)") {
                        playlists.add(chosen.compactMap { library.track(id: $0) }, to: playlist)
                        dismiss()
                    }
                    .disabled(chosen.isEmpty)
                }
            }
        }
    }
}
