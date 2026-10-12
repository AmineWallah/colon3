import SwiftUI

struct LibraryView: View {
    enum Scope: String, CaseIterable, Identifiable {
        case albums = "Albums", songs = "Songs", artists = "Artists"
        var id: String { rawValue }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case title = "Title", artist = "Artist", recent = "Recently Added"
        var id: String { rawValue }
    }

    struct Section<Item>: Identifiable {
        let letter: String
        let items: [Item]
        var id: String { letter }
    }

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var player: Player

    @AppStorage("library.scope") private var scope: Scope = .albums
    @AppStorage("library.sort") private var sort: Sort = .title
    @State private var favoritesOnly = false
    @State private var query = ""
    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var showImporter = false
    @State private var importMessage: String?
    @State private var pendingDelete: [Track]?

    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Library")
                .searchable(text: $query, prompt: "Search your library")
                .toolbar { toolbar }
                .navigationDestination(for: Album.self) { AlbumDetailView(album: $0) }
                .navigationDestination(for: ArtistEntry.self) { ArtistDetailView(artist: $0) }
                .fileImporter(isPresented: $showImporter, allowedContentTypes: LibraryStore.importableTypes,
                              allowsMultipleSelection: true) { result in
                    guard case let .success(urls) = result, !urls.isEmpty else { return }
                    Task {
                        let count = await library.importItems(urls)
                        importMessage = count == 0 ? "No audio files found." : "Imported \(count) song\(count == 1 ? "" : "s")."
                    }
                }
                .alert(importMessage ?? "", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
                    Button("OK", role: .cancel) {}
                }
                .safeAreaInset(edge: .bottom) {
                    if selecting { selectionBar }
                }
                .confirmDelete($pendingDelete) { _ in
                    selection.removeAll()
                    selecting = false
                }
                .onChange(of: scope) { _, _ in selection.removeAll() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if library.tracks.isEmpty {
            ScrollView {
                scopePicker
                EmptyStateView(title: library.isScanning ? "Loading Library…" : "No Music Yet",
                               message: "Download from Search, tap + to import files, or copy music into colon3 › Music in the Files app.",
                               systemImage: "music.note.house")
                    .padding(.top, 60)
                if !library.isScanning {
                    Button("Import Music") { showImporter = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        } else {
            switch scope {
            case .albums: albumsGrid
            case .songs: songsList
            case .artists: artistsList
            }
        }
    }

    private var scopePicker: some View {
        Picker("View", selection: $scope) {
            ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: Filtering and sections

    private func matches(_ text: String...) -> Bool {
        guard !query.isEmpty else { return true }
        return text.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private var filteredItems: [LibraryItem] {
        library.items.filter { item in
            if favoritesOnly {
                let favorite = favorites.isFavorite(item) || item.tracks.contains { favorites.isFavorite($0) }
                if !favorite { return false }
            }
            switch item {
            case let .album(album):
                return matches(album.title, album.artist) || album.tracks.contains { matches($0.title, $0.artist) }
            case let .single(track):
                return matches(track.title, track.artist)
            }
        }
    }

    private var filteredTracks: [Track] {
        library.tracks.filter { track in
            let albumIsFavorite = library.album(containing: track).map { favorites.isFavorite($0) } ?? false
            if favoritesOnly, !favorites.isFavorite(track), !albumIsFavorite {
                return false
            }
            return matches(track.title, track.artist, track.album ?? "")
        }
    }

    private var filteredArtists: [ArtistEntry] {
        library.artists.filter { artist in
            matches(artist.name) || artist.albums.contains { matches($0.title) } || artist.singles.contains { matches($0.title) }
        }
    }

    private func makeSections<Item>(_ items: [Item], title: @escaping (Item) -> String, artist: @escaping (Item) -> String,
                                    added: @escaping (Item) -> Date) -> [Section<Item>] {
        switch sort {
        case .recent:
            return [Section(letter: "", items: items.sorted { added($0) > added($1) })]
        case .title, .artist:
            let key = sort == .title ? title : artist
            let sorted = items.sorted { lhs, rhs in
                let left = key(lhs), right = key(rhs)
                if left != right { return SortKey.less(left, right) }
                return SortKey.less(title(lhs), title(rhs))
            }
            var result: [Section<Item>] = []
            for item in sorted {
                let letter = SortKey.section(for: key(item))
                if result.last?.letter == letter {
                    result[result.count - 1] = Section(letter: letter, items: result[result.count - 1].items + [item])
                } else {
                    result.append(Section(letter: letter, items: [item]))
                }
            }
            return result
        }
    }

    private func sectionHeader(_ letter: String) -> some View {
        Text(letter)
            .font(.title3.weight(.bold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
            .id("section-" + letter)
    }

    private func indexBar(_ letters: [String], proxy: ScrollViewProxy) -> some View {
        SectionIndexBar(available: letters) { letter in
            proxy.scrollTo("section-" + letter, anchor: .top)
        }
        .padding(.trailing, 2)
    }

    // MARK: Albums

    private var albumsGrid: some View {
        let sections = makeSections(filteredItems, title: \.title, artist: \.artist, added: \.addedAt)
        let letters = sections.map(\.letter).filter { !$0.isEmpty }
        return ScrollViewReader { proxy in
            ScrollView {
                scopePicker
                LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                    ForEach(sections) { section in
                        SwiftUI.Section {
                            ForEach(section.items) { item in tile(item) }
                        } header: {
                            if !section.letter.isEmpty { sectionHeader(section.letter) }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .overlay(alignment: .trailing) {
                if sort != .recent, letters.count > 1, query.isEmpty { indexBar(letters, proxy: proxy) }
            }
        }
    }

    @ViewBuilder
    private func tile(_ item: LibraryItem) -> some View {
        let label = VStack(alignment: .leading, spacing: 3) {
            ArtworkView(source: item.artwork, cornerRadius: 8)
                .overlay(alignment: .bottomTrailing) {
                    if selecting {
                        Image(systemName: selection.contains(item.id) ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, selection.contains(item.id) ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.black.opacity(0.3)))
                            .padding(6)
                    }
                }
            HStack(spacing: 4) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if favorites.isFavorite(item) {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                }
            }
            Text(itemSubtitle(item))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())

        Group {
            if selecting {
                Button { toggleSelection(item.id) } label: { label }
            } else {
                switch item {
                case let .album(album):
                    NavigationLink(value: album) { label }
                case let .single(track):
                    Button { player.play([track]) } label: { label }
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                player.play(item.tracks)
            } label: {
                Label("Play", systemImage: "play")
            }
            Button {
                player.play(item.tracks, shuffled: true)
            } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
            if case let .album(album) = item {
                TrackMenuItems(tracks: album.tracks, album: album) { pendingDelete = $0 }
            } else {
                TrackMenuItems(tracks: item.tracks) { pendingDelete = $0 }
            }
        }
    }

    private func itemSubtitle(_ item: LibraryItem) -> String {
        switch item {
        case let .album(album): return album.artist
        case let .single(track): return "\(track.artist) · Song"
        }
    }

    // MARK: Songs

    private var songsList: some View {
        let sections = makeSections(filteredTracks, title: \.title, artist: \.artist, added: \.addedAt)
        let ordered = sections.flatMap(\.items)
        let letters = sections.map(\.letter).filter { !$0.isEmpty }
        return ScrollViewReader { proxy in
            ScrollView {
                scopePicker
                HStack(spacing: 12) {
                    Button { player.play(ordered) } label: {
                        Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    Button { player.play(ordered, shuffled: true) } label: {
                        Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .disabled(ordered.isEmpty)

                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                    ForEach(sections) { section in
                        if !section.letter.isEmpty {
                            sectionHeader(section.letter).padding(.horizontal, 20)
                        }
                        ForEach(section.items) { track in
                            songRow(track, in: ordered)
                            Divider().padding(.leading, 80)
                        }
                    }
                }
                .padding(.bottom, 24)
            }
            .overlay(alignment: .trailing) {
                if sort != .recent, letters.count > 1, query.isEmpty { indexBar(letters, proxy: proxy) }
            }
        }
    }

    private func songRow(_ track: Track, in ordered: [Track]) -> some View {
        let id = "t:" + track.id
        return Button {
            if selecting {
                toggleSelection(id)
            } else if let index = ordered.firstIndex(of: track) {
                player.play(ordered, startAt: index)
            }
        } label: {
            TrackRow(track: track,
                     subtitle: [track.artist, library.album(containing: track)?.title].compactMap { $0 }.joined(separator: " · "),
                     isSelected: selecting ? selection.contains(id) : nil)
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .contextMenu {
            TrackMenuItems(tracks: [track]) { pendingDelete = $0 }
        }
    }

    // MARK: Artists

    private var artistsList: some View {
        let artists = filteredArtists
        let grouped = makeSections(artists, title: \.name, artist: \.name, added: { $0.albums.first?.addedAt ?? .distantPast })
        let letters = grouped.map(\.letter).filter { !$0.isEmpty }
        return ScrollViewReader { proxy in
            ScrollView {
                scopePicker
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(grouped) { section in
                        if !section.letter.isEmpty {
                            sectionHeader(section.letter).padding(.horizontal, 20)
                        }
                        ForEach(section.items) { artist in
                            NavigationLink(value: artist) {
                                HStack(spacing: 14) {
                                    ArtworkView(source: artist.artwork, size: 56, cornerRadius: 28)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(artist.name).lineLimit(1)
                                        Text("\(artist.trackCount) song\(artist.trackCount == 1 ? "" : "s")")
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
                            Divider().padding(.leading, 90)
                        }
                    }
                }
                .padding(.bottom, 24)
            }
            .overlay(alignment: .trailing) {
                if letters.count > 1, query.isEmpty { indexBar(letters, proxy: proxy) }
            }
        }
    }

    // MARK: Selection

    private func toggleSelection(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private var selectedTracks: [Track] {
        switch scope {
        case .albums:
            return filteredItems.filter { selection.contains($0.id) }.flatMap(\.tracks)
        case .songs:
            return filteredTracks.filter { selection.contains("t:" + $0.id) }
        case .artists:
            return []
        }
    }

    private var selectionBar: some View {
        let tracks = selectedTracks
        return HStack {
            Button { player.play(tracks); endSelection() } label: { Label("Play", systemImage: "play.fill") }
            Spacer()
            Button { player.playNext(tracks); endSelection() } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
            Spacer()
            Button { toggleFavorites(); endSelection() } label: { Label("Favorite", systemImage: "star") }
            Spacer()
            Button(role: .destructive) { pendingDelete = tracks } label: { Label("Delete", systemImage: "trash") }
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .disabled(tracks.isEmpty)
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(.bar)
    }

    private func toggleFavorites() {
        switch scope {
        case .albums:
            let items = filteredItems.filter { selection.contains($0.id) }
            let allFavorite = items.allSatisfy { favorites.isFavorite($0) }
            favorites.set(items, favorite: !allFavorite)
        case .songs:
            let tracks = selectedTracks
            let allFavorite = tracks.allSatisfy { favorites.isFavorite($0) }
            for track in tracks { favorites.set(track, favorite: !allFavorite) }
        case .artists:
            break
        }
    }

    private func endSelection() {
        selection.removeAll()
        selecting = false
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if scope != .artists {
                Button(selecting ? "Done" : "Select") {
                    if selecting { endSelection() } else { selecting = true }
                }
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Toggle(isOn: $favoritesOnly) {
                    Label("Favorites Only", systemImage: "star")
                }
                Picker("Sort By", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                }
            } label: {
                Image(systemName: favoritesOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            Menu {
                Button {
                    showImporter = true
                } label: {
                    Label("Import Files or Folders…", systemImage: "square.and.arrow.down")
                }
                Button {
                    library.rescan()
                } label: {
                    Label("Rescan Library", systemImage: "arrow.clockwise")
                }
            } label: {
                if library.isImporting || library.isScanning {
                    ProgressView()
                } else {
                    Image(systemName: "plus")
                }
            }
        }
    }
}
