import SwiftUI

/// Where a shelf's header leads.
enum HomeRoute: Hashable {
    case songs(HomeSection)
    case releases
    case recent
    case release(ChartAlbum)
}

/// The Home tab, laid out like Apple Music's: Top Picks tiles, then shelves for trending songs,
/// the top 100, recent releases and what you played lately, in the order set in
/// Settings › Appearance › Home Sections.
struct HomeView: View {
    @EnvironmentObject private var trending: TrendingStore
    @EnvironmentObject private var player: Player
    /// Observed so shelves update ("in library", recently played) after downloads and scans.
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var soulseek: SoulseekModel
    @EnvironmentObject private var stats: StatsStore
    @EnvironmentObject private var favorites: FavoritesStore

    @AppStorage(HomeSection.orderKey) private var orderRaw = ""
    @AppStorage(HomeSection.hiddenKey) private var hiddenRaw = ""
    @State private var picks: [HomePick] = []

    /// Changes when the Top Picks tiles could: the library, plays or favourites changed.
    private var picksKey: String {
        "\(library.tracks.count)|\(library.albums.count)|\(stats.revision)|\(favorites.songs.count)|\(favorites.albums.count)"
    }

    private var sections: [HomeSection] {
        let hidden = HomeSection.hidden(hiddenRaw)
        return HomeSection.ordered(orderRaw).filter { !hidden.contains($0) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 30) {
                    if !soulseek.isLoggedIn {
                        Label("Log in to Soulseek in Settings to download songs.", systemImage: "person.crop.circle.badge.exclamationmark")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 20)
                    }
                    let firstChart = sections.first(where: \.isChart)
                    ForEach(sections) { section in
                        if section == firstChart {
                            if trending.entries.isEmpty {
                                chartStatus
                            } else if let note = trending.staleNote {
                                Label(note, systemImage: "exclamationmark.icloud")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 20)
                            }
                        }
                        shelf(section)
                    }
                }
                .padding(.vertical, 8)
            }
            .navigationTitle("Home")
            // The title on the same line as the country button, not on a line of its own under it.
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { CountryMenu() }
            }
            .refreshable { await trending.load(force: true) }
            .task { await trending.load() }
            .task(id: picksKey) {
                picks = HomePick.make(library: library, stats: stats, favorites: favorites)
            }
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case let .songs(section):
                    ChartSongList(section: section)
                case .releases:
                    ReleasesGrid()
                case .recent:
                    RecentlyPlayedGrid()
                case let .release(album):
                    ReleaseDetailView(album: album)
                }
            }
            .navigationDestination(for: Album.self) { AlbumDetailView(album: $0) }
        }
    }

    @ViewBuilder
    private var chartStatus: some View {
        if trending.isLoading {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
        } else if let error = trending.error {
            ContentUnavailableView {
                Label("Couldn't Load the Charts", systemImage: "chart.line.downtrend.xyaxis")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await trending.load(force: true) } }
            }
        }
    }

    @ViewBuilder
    private func shelf(_ section: HomeSection) -> some View {
        switch section {
        case .continueListening:
            TopPicksShelf(picks: picks)
        case .trending:
            if !trending.trendingSongs.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ShelfHeader(title: section.title, route: .songs(.trending))
                    SongShelf(entries: trending.trendingSongs)
                }
            }
        case .top100:
            if !trending.entries.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ShelfHeader(title: section.title, route: .songs(.top100))
                    SongShelf(entries: trending.entries)
                }
            }
        case .releases:
            if !trending.recentReleases.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ShelfHeader(title: section.title, route: .releases)
                    CardShelf {
                        ForEach(trending.recentReleases) { album in
                            ReleaseCard(album: album, inShelf: true)
                        }
                    }
                }
            }
        case .recent:
            let items = stats.recentlyPlayed(limit: 20, in: library)
            VStack(alignment: .leading, spacing: 10) {
                ShelfHeader(title: section.title, route: items.isEmpty ? nil : .recent)
                if items.isEmpty {
                    Text("Albums and songs you play show up here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                } else {
                    CardShelf {
                        ForEach(items) { item in
                            PlayedCard(item: item, inShelf: true)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Shelves

private struct ShelfHeader: View {
    let title: String
    let route: HomeRoute?

    var body: some View {
        let label = HStack(spacing: 6) {
            Text(title).font(.title2.weight(.bold))
            if route != nil {
                Image(systemName: "chevron.right")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        Group {
            if let route {
                NavigationLink(value: route) { label }
            } else {
                label
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
    }
}

/// Songs in columns of four that page sideways, with the next column peeking in.
private struct SongShelf: View {
    let entries: [ChartEntry]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHGrid(rows: Array(repeating: GridItem(.fixed(64), spacing: 0), count: 4), spacing: 16) {
                ForEach(entries) { entry in
                    ChartSongRow(entry: entry, showRank: false, list: entries)
                        // A column fills an iPhone's width (the next one peeks in); an iPad shows several.
                        .containerRelativeFrame(.horizontal) { width, _ in width > 700 ? 360 : width - 36 }
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, 20, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
    }
}

/// Square cards two to a screen, paging sideways.
private struct CardShelf<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                content()
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, 20, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
    }
}

// MARK: - Songs

/// A chart song: cover, title, artist, and play / download controls.
struct ChartSongRow: View {
    let entry: ChartEntry
    let showRank: Bool
    /// The list it's shown in; playing a song queues the others from it that you have.
    let list: [ChartEntry]

    @EnvironmentObject private var trending: TrendingStore
    @EnvironmentObject private var player: Player
    /// Observed so the row notices when the song lands in the library.
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        let track = trending.libraryTrack(for: entry)
        let fetch = trending.fetches[entry.id]
        HStack(spacing: 12) {
            if showRank {
                Text("\(entry.rank)")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 26, alignment: .trailing)
            }
            RemoteCover(url: entry.artworkURL, cornerRadius: 6)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let track, player.current?.id == track.id {
                        Image(systemName: player.isPlaying ? "waveform" : "speaker.fill")
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }
                    Text(entry.title).lineLimit(1)
                }
                Text(subtitle(track: track, fetch: fetch))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            control(track: track, fetch: fetch)
        }
        .contentShape(Rectangle())
        .onTapGesture { if let track { play(track) } }
        .contextMenu {
            if let track {
                Button { play(track) } label: { Label("Play", systemImage: "play") }
                Button { player.playNext([track]) } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
            } else if fetch?.isActive != true {
                Button { trending.download(entry) } label: { Label("Download", systemImage: "arrow.down.circle") }
            }
            if let url = entry.appleMusicURL {
                Link(destination: url) { Label("Open in Apple Music", systemImage: "arrow.up.forward.app") }
            }
        }
    }

    private func play(_ track: Track) {
        let tracks = trending.libraryTracks(in: list)
        player.play(tracks, startAt: tracks.firstIndex(of: track) ?? 0)
    }

    private func subtitle(track: Track?, fetch: TrendingStore.Fetch?) -> String {
        guard track == nil, let fetch else { return entry.artist }
        switch fetch {
        case .searching: return entry.artist + " · Searching Soulseek…"
        case let .downloading(fraction): return entry.artist + " · Downloading \(Int(fraction * 100))%"
        case let .failed(reason): return entry.artist + " · " + reason
        case .done: return entry.artist
        }
    }

    private func control(track: Track?, fetch: TrendingStore.Fetch?) -> some View {
        FetchControl(inLibrary: track != nil, fetch: fetch, title: entry.title,
                     onDownload: { trending.download(entry) }, onCancel: { trending.cancel(entry) })
    }
}

/// In library (tick), downloading (spinner that cancels), failed (retry) or download.
struct FetchControl: View {
    let inLibrary: Bool
    let fetch: TrendingStore.Fetch?
    let title: String
    let onDownload: () -> Void
    let onCancel: () -> Void

    var body: some View {
        if inLibrary {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
                .accessibilityLabel("In your library")
        } else if let fetch, fetch.isActive {
            Button(action: onCancel) {
                ZStack {
                    ProgressView()
                    Image(systemName: "stop.fill").font(.system(size: 8))
                }
                .frame(width: 32, height: 32)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Cancel download")
        } else if fetch?.isFailed == true {
            Button(action: onDownload) {
                Image(systemName: "arrow.clockwise.circle")
                    .font(.title2)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.orange)
            .accessibilityLabel("Try again")
        } else {
            Button(action: onDownload) {
                Image(systemName: "arrow.down.circle")
                    .font(.title2)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Download \(title)")
        }
    }
}

/// The full Trending Songs or Top 100 list.
private struct ChartSongList: View {
    let section: HomeSection

    @EnvironmentObject private var trending: TrendingStore

    var body: some View {
        let entries = section == .trending ? trending.trendingSongs : trending.entries
        List {
            Section {
                ForEach(entries) { entry in
                    ChartSongRow(entry: entry, showRank: true, list: entries)
                }
            } footer: {
                Text(footer)
            }
        }
        .listStyle(.plain)
        .navigationTitle(section.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { CountryMenu() }
        }
    }

    private var footer: String {
        var text = section == .trending
            ? "Songs on Apple Music's top 100 in \(TrendingStore.countryName(trending.country)) that came out recently. Numbers are chart positions."
            : "Apple Music's most played songs in \(TrendingStore.countryName(trending.country))."
        if let updated = trending.updated {
            text += " Updated \(updated.formatted(.relative(presentation: .named)))."
        }
        return text
    }
}

// MARK: - Albums

/// A recent release. Opens its page: the full tracklist, with what you have and what's missing.
private struct ReleaseCard: View {
    let album: ChartAlbum
    /// In a sideways shelf the card sizes itself to half the screen; in a grid the grid sizes it.
    let inShelf: Bool

    @EnvironmentObject private var trending: TrendingStore
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        let owned = trending.libraryAlbum(for: album)
        let card = VStack(alignment: .leading, spacing: 3) {
            RemoteCover(url: album.artworkURL, cornerRadius: 8)
                .aspectRatio(1, contentMode: .fit)
                .overlay(alignment: .bottomTrailing) {
                    if owned != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .tint)
                            .font(.title3)
                            .padding(6)
                    }
                }
            Text(album.title).font(.subheadline.weight(.medium)).lineLimit(1)
            Text(album.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .modifier(ShelfWidth(active: inShelf))
        .contentShape(Rectangle())

        NavigationLink(value: HomeRoute.release(album)) { card }
        .buttonStyle(.plain)
        .contextMenu {
            Button { searchSoulseekForAlbum(album, router: router) } label: {
                Label("Search on Soulseek", systemImage: "magnifyingglass")
            }
            if let url = album.appleMusicURL {
                Link(destination: url) { Label("Open in Apple Music", systemImage: "arrow.up.forward.app") }
            }
        } preview: {
            RemoteCover(url: album.artworkURL, cornerRadius: 0).frame(width: 300, height: 300)
        }
    }

}

/// Albums come as folders on Soulseek, so the Search tab (with its folder results) is the way
/// to get a whole one at once.
@MainActor
private func searchSoulseekForAlbum(_ album: ChartAlbum, router: AppRouter) {
    let title = album.title.replacingOccurrences(of: #"\s+-\s+(EP|Single)$"#, with: "", options: .regularExpression)
    router.pendingSearch = album.artist + " " + title
    router.tab = .search
}

/// A song on a release and its library copy, if you have it.
private struct ReleaseRow: Identifiable {
    let track: ReleaseTrack
    let libraryTrack: Track?
    var id: String { track.id }
}

/// A release's page: cover, the full tracklist with a tick on songs you have and a download
/// button on the rest, Download Missing, and a Soulseek album search for the whole folder.
private struct ReleaseDetailView: View {
    let album: ChartAlbum

    @EnvironmentObject private var trending: TrendingStore
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var router: AppRouter
    /// Observed so ticks appear as downloads land.
    @EnvironmentObject private var library: LibraryStore
    @State private var tracks: [ReleaseTrack]?
    @State private var error: String?

    var body: some View {
        let owned = trending.libraryAlbum(for: album)
        let rows = (tracks ?? []).map { ReleaseRow(track: $0, libraryTrack: trending.libraryTrack(for: $0)) }
        let missing = rows.filter { $0.libraryTrack == nil }.map { $0.track }
        let discs = Set((tracks ?? []).map(\.disc)).sorted()
        List {
            header(owned: owned, rows: rows, missing: missing)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 12, trailing: 20))

            if tracks != nil {
                ForEach(discs, id: \.self) { disc in
                    Section {
                        ForEach(rows.filter { $0.track.disc == disc }) { item in
                            row(item.track, libraryTrack: item.libraryTrack, rows: rows)
                        }
                    } header: {
                        if discs.count > 1 { Text("Disc \(disc)") }
                    }
                }
            } else if let error {
                VStack(spacing: 10) {
                    Text(error).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Try Again") { Task { await load() } }
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
            } else {
                ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func header(owned: Album?, rows: [ReleaseRow], missing: [ReleaseTrack]) -> some View {
        VStack(spacing: 10) {
            RemoteCover(url: album.artworkURL, cornerRadius: 12)
                .frame(width: 230, height: 230)
                .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
            VStack(spacing: 2) {
                Text(album.title).font(.title3.weight(.bold)).multilineTextAlignment(.center)
                Text(album.artist).font(.title3).foregroundStyle(.tint).multilineTextAlignment(.center)
                Text(details(rows: rows, missing: missing))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                if tracks != nil, missing.isEmpty {
                    Button { play(from: nil, rows: rows) } label: {
                        Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                } else {
                    Button { downloadMissing(missing) } label: {
                        Label(missing.isEmpty ? "Download" : "Download \(missing.count) Missing", systemImage: "arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(tracks == nil || missing.allSatisfy { trending.fetches[$0.id]?.isActive == true })
                }
                Button { searchSoulseekForAlbum(album, router: router) } label: {
                    Label("Find Album", systemImage: "magnifyingglass").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            if let owned {
                NavigationLink(value: owned) {
                    Label("Open in Library", systemImage: "music.note.house")
                        .font(.subheadline)
                }
            }
            Text("Download Missing finds each song on its own; Find Album searches Soulseek for the whole album folder.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func details(rows: [ReleaseRow], missing: [ReleaseTrack]) -> String {
        var parts: [String] = []
        if let date = album.releaseDate { parts.append(date.formatted(.dateTime.day().month(.abbreviated).year())) }
        if let tracks {
            parts.append("\(tracks.count) song\(tracks.count == 1 ? "" : "s")")
            let have = rows.count - missing.count
            parts.append(have == 0 ? "none in your library" : "\(have) in your library")
        }
        return parts.joined(separator: " · ")
    }

    private func row(_ track: ReleaseTrack, libraryTrack: Track?, rows: [ReleaseRow]) -> some View {
        let fetch = trending.fetches[track.id]
        return HStack(spacing: 12) {
            Text("\(track.number)")
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 24, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let libraryTrack, player.current?.id == libraryTrack.id {
                        Image(systemName: player.isPlaying ? "waveform" : "speaker.fill")
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }
                    Text(track.title)
                        .lineLimit(1)
                        .foregroundStyle(libraryTrack == nil ? .secondary : .primary)
                }
                if let line = subtitle(track, fetch: fetch, inLibrary: libraryTrack != nil) {
                    Text(line).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let duration = track.duration, fetch?.isActive != true {
                Text(Formatting.duration(duration))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            FetchControl(inLibrary: libraryTrack != nil, fetch: fetch, title: track.title,
                         onDownload: { trending.download(track) }, onCancel: { trending.cancel(track) })
        }
        .contentShape(Rectangle())
        .onTapGesture { if libraryTrack != nil { play(from: track, rows: rows) } }
    }

    /// Featured artists, or download progress / why it wasn't found.
    private func subtitle(_ track: ReleaseTrack, fetch: TrendingStore.Fetch?, inLibrary: Bool) -> String? {
        if !inLibrary, let fetch {
            switch fetch {
            case .searching: return "Searching Soulseek…"
            case let .downloading(fraction): return "Downloading \(Int(fraction * 100))%"
            case let .failed(reason): return reason
            case .done: break
            }
        }
        return track.artist.caseInsensitiveCompare(album.artist) == .orderedSame ? nil : track.artist
    }

    /// Plays the album's songs you have, in album order, from `track` (or the start).
    private func play(from track: ReleaseTrack?, rows: [ReleaseRow]) {
        let playable = rows.compactMap { $0.libraryTrack }
        guard !playable.isEmpty else { return }
        var startIndex = 0
        if let track, let start = rows.first(where: { $0.track.id == track.id })?.libraryTrack,
           let position = playable.firstIndex(of: start) {
            startIndex = position
        }
        player.play(playable, startAt: startIndex)
    }

    private func downloadMissing(_ missing: [ReleaseTrack]) {
        for track in missing where trending.fetches[track.id]?.isActive != true {
            trending.download(track)
        }
    }

    private func load() async {
        error = nil
        do {
            tracks = try await trending.tracklist(for: album)
        } catch {
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Everything in Recent Releases.
private struct ReleasesGrid: View {
    @EnvironmentObject private var trending: TrendingStore

    var body: some View {
        ScrollView {
            LazyVGrid(columns: AdaptiveGrid.columns, spacing: 20) {
                ForEach(trending.recentReleases) { album in
                    ReleaseCard(album: album, inShelf: false)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .navigationTitle("Recent Releases")
    }
}

// MARK: - Recently played

/// An album or song from your library you played lately.
private struct PlayedCard: View {
    let item: LibraryItem
    let inShelf: Bool

    @EnvironmentObject private var player: Player

    var body: some View {
        let card = VStack(alignment: .leading, spacing: 3) {
            ArtworkView(source: item.artwork, cornerRadius: 8)
            Text(item.title).font(.subheadline.weight(.medium)).lineLimit(1)
            Text(item.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .modifier(ShelfWidth(active: inShelf))
        .contentShape(Rectangle())

        Group {
            switch item {
            case let .album(album):
                NavigationLink(value: album) { card }
            case let .single(track):
                Button { player.play([track]) } label: { card }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { player.play(item.tracks) } label: { Label("Play", systemImage: "play") }
            Button { player.play(item.tracks, shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle") }
            Button { player.playNext(item.tracks) } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
        }
    }
}

/// Everything in Recently Played.
private struct RecentlyPlayedGrid: View {
    @EnvironmentObject private var stats: StatsStore
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        ScrollView {
            LazyVGrid(columns: AdaptiveGrid.columns, spacing: 20) {
                ForEach(stats.recentlyPlayed(limit: 60, in: library)) { item in
                    PlayedCard(item: item, inShelf: false)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .navigationTitle("Recently Played")
    }
}

// MARK: - Shared

/// Two cards per screen width in a sideways shelf; fixed-size cards on an iPad's wide screen.
private struct ShelfWidth: ViewModifier {
    let active: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass

    @ViewBuilder
    func body(content: Content) -> some View {
        if !active {
            content
        } else if sizeClass == .regular {
            content.frame(width: 180)
        } else {
            content.containerRelativeFrame(.horizontal, count: 2, spacing: 14)
        }
    }
}

/// A cover from the web (chart art), square, with the usual placeholder while it loads.
private struct RemoteCover: View {
    let url: URL?
    let cornerRadius: CGFloat

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    ArtworkPlaceholder()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
    }
}

/// The chart's country, as a globe button.
private struct CountryMenu: View {
    @EnvironmentObject private var trending: TrendingStore

    var body: some View {
        Menu {
            Picker("Country", selection: $trending.country) {
                ForEach(TrendingStore.countries, id: \.self) { code in
                    Text(TrendingStore.countryName(code)).tag(code)
                }
            }
        } label: {
            Label(trending.country.uppercased(), systemImage: "globe")
                .labelStyle(.titleAndIcon)
        }
    }
}

/// Settings › Appearance › Home Sections: drag to reorder the Home shelves, switch off the ones you don't want.
struct HomeSectionsSettings: View {
    @AppStorage(HomeSection.orderKey) private var orderRaw = ""
    @AppStorage(HomeSection.hiddenKey) private var hiddenRaw = ""

    var body: some View {
        let order = HomeSection.ordered(orderRaw)
        List {
            Section {
                ForEach(order) { section in
                    Toggle(section.title, isOn: Binding(
                        get: { !HomeSection.hidden(hiddenRaw).contains(section) },
                        set: { visible in
                            var hidden = HomeSection.hidden(hiddenRaw)
                            if visible { hidden.remove(section) } else { hidden.insert(section) }
                            hiddenRaw = HomeSection.encode(HomeSection.allCases.filter { hidden.contains($0) })
                        }))
                }
                .onMove { offsets, destination in
                    var reordered = order
                    reordered.move(fromOffsets: offsets, toOffset: destination)
                    orderRaw = HomeSection.encode(reordered)
                }
            } footer: {
                Text("Drag to change the order of the shelves on the Home tab. Switched-off shelves are hidden.")
            }
            Section {
                Button("Reset to Default") {
                    orderRaw = ""
                    hiddenRaw = ""
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Home Sections")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Top Picks

/// One tall tile in the Top Picks shelf: a mix to play, or an album to open.
struct HomePick: Identifiable {
    enum Action {
        case play([Track], shuffled: Bool)
        case open(Album)
    }

    let id: String
    let caption: String
    let title: String
    let subtitle: String
    let artwork: ArtworkSource?
    let action: Action

    /// The tiles for this library, from what you favourited, play a lot, haven't played in a
    /// while, added last and played last. The ones that pick songs at random keep their choice
    /// for the day, so the shelf doesn't reshuffle while you look at it.
    @MainActor
    static func make(library: LibraryStore, stats: StatsStore, favorites: FavoritesStore) -> [HomePick] {
        var picks: [HomePick] = []
        let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0

        let favourites = library.tracks.filter { track in
            if favorites.isFavorite(track) { return true }
            if let album = library.album(containing: track) { return favorites.isFavorite(album) }
            return false
        }
        if favourites.count >= 3 {
            let cover = daily(favourites, day: day, limit: 1)
            picks.append(HomePick(id: "favourites", caption: "Made for You", title: "Favourites Mix",
                                  subtitle: artistLine(favourites),
                                  artwork: cover.first.map { library.artwork(for: $0) },
                                  action: .play(favourites, shuffled: true)))
        }

        let most = stats.mostPlayed(limit: 40, in: library)
        if most.count >= 5 {
            picks.append(HomePick(id: "most", caption: "On Repeat", title: "Most Played",
                                  subtitle: artistLine(most),
                                  artwork: library.artwork(for: most[0]),
                                  action: .play(most, shuffled: false)))
        }

        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        let dusty = library.tracks.filter { track in
            if let last = stats.lastPlayed(track.id) { return last < cutoff }
            return track.addedAt < cutoff
        }
        if dusty.count >= 10 {
            let chosen = daily(dusty, day: day, limit: 40)
            picks.append(HomePick(id: "rediscover", caption: "Rediscover", title: "Not Played Lately",
                                  subtitle: artistLine(chosen),
                                  artwork: chosen.first.map { library.artwork(for: $0) },
                                  action: .play(chosen, shuffled: false)))
        }

        var shown = Set<String>()
        if let newest = library.albums.max(by: { $0.addedAt < $1.addedAt }) {
            shown.insert(newest.id)
            picks.append(HomePick(id: "new:" + newest.id, caption: "New in Your Library", title: newest.title,
                                  subtitle: newest.artist, artwork: .album(newest), action: .open(newest)))
        }
        for item in stats.recentlyPlayed(limit: 8, in: library) {
            guard case let .album(album) = item, !shown.contains(album.id) else { continue }
            picks.append(HomePick(id: "back:" + album.id, caption: "Jump Back In", title: album.title,
                                  subtitle: album.artist, artwork: .album(album), action: .open(album)))
            break
        }
        return picks
    }

    /// Up to `limit` of `tracks` in an order that changes once a day.
    private static func daily(_ tracks: [Track], day: Int, limit: Int) -> [Track] {
        let ranked = tracks.map { (order: dailyRank($0.id, day: day), track: $0) }
            .sorted { $0.order < $1.order }
        return ranked.prefix(limit).map { $0.track }
    }

    /// FNV-1a of the song's id and the day: the same all day, different tomorrow.
    private static func dailyRank(_ id: String, day: Int) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        hash ^= UInt64(truncatingIfNeeded: day)
        hash = hash &* 1_099_511_628_211
        return hash
    }

    /// "Artist, Artist, Artist and more": the artists with the most songs in the mix.
    private static func artistLine(_ tracks: [Track]) -> String {
        var counts: [String: Int] = [:]
        for track in tracks { counts[track.artist, default: 0] += 1 }
        let names = counts.keys.sorted { lhs, rhs in
            let left = counts[lhs] ?? 0
            let right = counts[rhs] ?? 0
            if left != right { return left > right }
            return lhs < rhs
        }
        let line = names.prefix(3).joined(separator: ", ")
        return names.count > 3 ? line + " and more" : line
    }
}

/// The top of Home: tall tiles like Apple Music's Top Picks. The first is the song you were
/// on (the paused song, or the queue saved when the app was last closed), there until
/// something plays; the rest come from `HomePick.make`.
struct TopPicksShelf: View {
    let picks: [HomePick]

    @EnvironmentObject private var player: Player
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        let resumable: Track? = player.isPlaying ? nil : (player.current ?? player.savedSessionTrack(in: library))
        if resumable != nil || !picks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Top Picks for You")
                    .font(.title2.weight(.bold))
                    .padding(.horizontal, 20)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        if let resumable {
                            ContinueTile(track: resumable)
                                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        }
                        ForEach(picks) { pick in
                            PickButton(pick: pick)
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, 20, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
            }
            .transition(.opacity)
        }
    }
}

/// Continue Listening: carries on where the song stopped. Starting playback hides the tile;
/// animating that fades it out and lets the other tiles slide over instead of jumping.
private struct ContinueTile: View {
    let track: Track

    @EnvironmentObject private var player: Player
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var clock: PlaybackClock

    var body: some View {
        let position = player.current != nil ? clock.position : (player.savedSession?.position ?? 0)
        let duration = max(track.duration, 1)
        let left = Int(max(duration - position, 0).rounded())
        let remaining = String(format: "%d:%02d left", left / 60, left % 60)
        Button {
            withAnimation(.easeInOut(duration: 0.4)) { carryOn() }
        } label: {
            PickTile(caption: "Continue Listening", title: track.title,
                     subtitle: track.artist + "\n" + remaining,
                     artwork: library.artwork(for: track),
                     progress: min(max(position / duration, 0), 1))
        }
        .buttonStyle(.plain)
    }

    private func carryOn() {
        if player.current != nil {
            player.resume()
        } else {
            player.resumeSavedSession(in: library)
        }
    }
}

private struct PickButton: View {
    let pick: HomePick

    @EnvironmentObject private var player: Player

    var body: some View {
        let tile = PickTile(caption: pick.caption, title: pick.title, subtitle: pick.subtitle,
                            artwork: pick.artwork, progress: nil)
        Group {
            switch pick.action {
            case let .play(tracks, shuffled):
                Button { player.play(tracks, shuffled: shuffled) } label: { tile }
            case let .open(album):
                NavigationLink(value: album) { tile }
            }
        }
        .buttonStyle(.plain)
    }
}

/// A tall card: the cover on top, fading into a blurred copy of itself that carries a
/// caption, a title and up to two lines of detail. `progress` draws a bar along the bottom.
private struct PickTile: View {
    let caption: String
    let title: String
    let subtitle: String
    let artwork: ArtworkSource?
    let progress: Double?

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 18, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ArtworkView(source: artwork, cornerRadius: 0)
                .mask {
                    LinearGradient(stops: [Gradient.Stop(color: .black, location: 0.7),
                                           Gradient.Stop(color: .clear, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(caption)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 14)
            .padding(.top, 2)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background { backdrop }
        .overlay(alignment: .bottom) {
            if let progress {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(.white.opacity(0.25))
                        Rectangle().fill(.white.opacity(0.9))
                            .frame(width: geometry.size.width * CGFloat(progress))
                    }
                }
                .frame(height: 4)
            }
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5) }
        .containerRelativeFrame(.horizontal) { width, _ in min(max(width * 0.62, 200), 270) }
        .contentShape(shape)
    }

    /// The cover again, scaled up to fill the tile and blurred, under a dark wash so white
    /// text reads on any artwork.
    private var backdrop: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let height = geometry.size.height
            ZStack {
                Color(white: 0.2)
                ArtworkView(source: artwork, cornerRadius: 0)
                    .frame(width: width, height: height)
                    .scaleEffect(max(height / width, 1))
                    .blur(radius: 28, opaque: true)
                    .saturation(1.3)
                Color.black.opacity(0.3)
            }
            .frame(width: width, height: height)
            .clipped()
        }
    }
}
