import SwiftUI

/// Settings › Library › Storage: what takes up space (albums, artists, songs), and songs you
/// haven't played in a while, with a way to delete them.
struct StorageView: View {
    enum Grouping: String, CaseIterable, Identifiable {
        case albums = "Albums"
        case artists = "Artists"
        case songs = "Songs"
        var id: String { rawValue }
    }

    /// Never played and downloaded more than this long ago, or last played this long ago.
    static let staleAge: TimeInterval = 30 * 86_400

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var stats: StatsStore
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var player: Player
    @State private var sizes: [String: Int64] = [:]
    @State private var measured = false
    @State private var grouping: Grouping = .albums
    @State private var showAll = false
    @AppStorage("storage.includeFavorites") private var includeFavorites = false
    @State private var pendingDelete: [Track]?

    var body: some View {
        List {
            Section {
                if measured {
                    LabeledContent("Music", value: Formatting.bytes(UInt64(max(total, 0))))
                    LabeledContent("Songs", value: "\(library.tracks.count)")
                } else {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Measuring\u{2026}").foregroundStyle(.secondary)
                    }
                }
            }

            if measured {
                staleSection
                largestSection
            }
        }
        .navigationTitle("Storage")
        .task(id: library.tracks.count) { await measure() }
        .confirmDelete($pendingDelete) { _ in
            Task { await measure() }
        }
    }

    // MARK: Not played lately

    private var staleSection: some View {
        let stale = staleTracks
        let staleSize = size(of: stale)
        return Section {
            if stale.isEmpty {
                Text("Everything here was played in the last 30 days, or downloaded less than 30 days ago.")
                    .foregroundStyle(.secondary)
            } else {
                let label = "\(stale.count) song" + (stale.count == 1 ? "" : "s")
                NavigationLink {
                    StaleSongsView(tracks: stale, sizes: sizes)
                } label: {
                    LabeledContent(label, value: Formatting.bytes(UInt64(max(staleSize, 0))))
                }
                Button(role: .destructive) {
                    pendingDelete = stale
                } label: {
                    Text("Delete All (\(Formatting.bytes(UInt64(max(staleSize, 0)))))")
                }
            }
            Toggle("Include Favourites", isOn: $includeFavorites)
        } header: {
            Text("Not Played in 30 Days")
        } footer: {
            Text("Songs never played that were downloaded over 30 days ago, and songs last played over 30 days ago. Favourites are left out unless you include them. Deleting removes the files from this iPhone and the songs from your playlists.")
        }
    }

    private var staleTracks: [Track] {
        let now = Date()
        let favoriteAlbumTracks = Set(favorites.albums.compactMap { library.album(id: $0) }.flatMap { $0.tracks.map(\.id) })
        let playing = player.current?.id
        return library.tracks
            .filter { track in
                if track.id == playing { return false }
                if !includeFavorites, favorites.songs.contains(track.id) || favoriteAlbumTracks.contains(track.id) { return false }
                if let last = stats.lastPlayed(track.id) { return now.timeIntervalSince(last) > Self.staleAge }
                return now.timeIntervalSince(track.addedAt) > Self.staleAge
            }
            .sorted { (sizes[$0.id] ?? 0) > (sizes[$1.id] ?? 0) }
    }

    // MARK: Largest

    private struct Row: Identifiable {
        let id: String
        let title: String
        let detail: String
        let bytes: Int64
        let tracks: [Track]
        var album: Album?
    }

    private var largestSection: some View {
        let rows = rows(for: grouping)
        let largest = max(rows.first?.bytes ?? 1, 1)
        let shown = showAll ? rows : Array(rows.prefix(25))
        return Section {
            Picker("Group By", selection: $grouping) {
                ForEach(Grouping.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)

            ForEach(shown) { row in
                rowView(row, largest: largest)
                    .swipeActions {
                        Button(role: .destructive) {
                            pendingDelete = row.tracks
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
            if rows.count > shown.count {
                Button("Show All \(rows.count)") { showAll = true }
            }
        } header: {
            Text("Largest")
        } footer: {
            Text("Swipe left to delete.")
        }
    }

    @ViewBuilder
    private func rowView(_ row: Row, largest: Int64) -> some View {
        let content = StorageRow(title: row.title, detail: row.detail, bytes: row.bytes,
                                 fraction: Double(row.bytes) / Double(largest))
        if let album = row.album {
            NavigationLink { AlbumDetailView(album: album) } label: { content }
        } else {
            content
        }
    }

    private func rows(for grouping: Grouping) -> [Row] {
        switch grouping {
        case .albums:
            return library.albums
                .map { album -> Row in
                    Row(id: "a:" + album.id, title: album.title,
                        detail: "\(album.artist) \u{00B7} \(album.tracks.count) song\(album.tracks.count == 1 ? "" : "s")",
                        bytes: size(of: album.tracks), tracks: album.tracks, album: album)
                }
                .sorted { $0.bytes > $1.bytes }
        case .artists:
            return library.artists
                .map { artist -> Row in
                    let tracks = artist.albums.flatMap(\.tracks) + artist.singles
                    return Row(id: "r:" + artist.name, title: artist.name,
                               detail: "\(tracks.count) song\(tracks.count == 1 ? "" : "s")",
                               bytes: size(of: tracks), tracks: tracks)
                }
                .sorted { $0.bytes > $1.bytes }
        case .songs:
            return library.tracks
                .map { track -> Row in
                    Row(id: "t:" + track.id, title: track.title, detail: track.artist,
                        bytes: sizes[track.id] ?? 0, tracks: [track])
                }
                .sorted { $0.bytes > $1.bytes }
        }
    }

    // MARK: Sizes

    private var total: Int64 { sizes.values.reduce(0, +) }

    private func size(of tracks: [Track]) -> Int64 {
        tracks.reduce(0) { $0 + (sizes[$1.id] ?? 0) }
    }

    private func measure() async {
        let files = library.tracks.map { ($0.id, $0.url) }
        let result = await Task.detached(priority: .utility) { Self.fileSizes(files) }.value
        sizes = result
        measured = true
    }

    nonisolated private static func fileSizes(_ files: [(String, URL)]) -> [String: Int64] {
        var result: [String: Int64] = [:]
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileSizeKey]
        for (id, url) in files {
            let values = try? url.resourceValues(forKeys: keys)
            result[id] = Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return result
    }
}

private struct StorageRow: View {
    let title: String
    let detail: String
    let bytes: Int64
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).lineLimit(1)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(Formatting.bytes(UInt64(max(bytes, 0))))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                Capsule()
                    .fill(.tint)
                    .frame(width: max(4, proxy.size.width * min(max(fraction, 0), 1)))
            }
            .frame(height: 4)
        }
        .padding(.vertical, 2)
    }
}

/// The songs not played in 30 days, to pick which to delete.
private struct StaleSongsView: View {
    let tracks: [Track]
    let sizes: [String: Int64]

    @EnvironmentObject private var stats: StatsStore
    @Environment(\.dismiss) private var dismiss
    @State private var selection = Set<String>()
    @State private var pendingDelete: [Track]?

    var body: some View {
        List(tracks, selection: $selection) { track in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).lineLimit(1)
                    Text("\(track.artist) \u{00B7} \(when(track))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(Formatting.bytes(UInt64(max(sizes[track.id] ?? 0, 0))))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .tag(track.id)
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Not Played in 30 Days")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(selection.count == tracks.count ? "Select None" : "Select All") {
                    selection = selection.count == tracks.count ? [] : Set(tracks.map(\.id))
                }
            }
            ToolbarItem(placement: .bottomBar) {
                Button(role: .destructive) {
                    pendingDelete = tracks.filter { selection.contains($0.id) }
                } label: {
                    Text(selection.isEmpty ? "Delete" : "Delete \(selection.count) (\(selectedSize))")
                }
                .disabled(selection.isEmpty)
            }
        }
        .confirmDelete($pendingDelete) { _ in dismiss() }
    }

    private var selectedSize: String {
        let bytes = tracks.filter { selection.contains($0.id) }.reduce(Int64(0)) { $0 + (sizes[$1.id] ?? 0) }
        return Formatting.bytes(UInt64(max(bytes, 0)))
    }

    private func when(_ track: Track) -> String {
        if let last = stats.lastPlayed(track.id) {
            return "played " + last.formatted(.relative(presentation: .named))
        }
        return "never played, added " + track.addedAt.formatted(.relative(presentation: .named))
    }
}
