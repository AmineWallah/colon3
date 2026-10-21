import SwiftUI

/// The Trending tab: today's Apple Music top songs for a country. Songs you have play on tap;
/// the rest have a download button that finds them on Soulseek.
struct TrendingView: View {
    @EnvironmentObject private var trending: TrendingStore
    @EnvironmentObject private var player: Player
    /// Observed so rows update ("in library") when a download or import lands.
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var soulseek: SoulseekModel

    var body: some View {
        NavigationStack {
            List {
                if !trending.entries.isEmpty, !soulseek.isLoggedIn {
                    Label("Log in to Soulseek in Settings to download songs.", systemImage: "person.crop.circle.badge.exclamationmark")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
                if !trending.entries.isEmpty {
                    Section {
                        ForEach(trending.entries) { entry in
                            ChartRow(entry: entry,
                                     track: trending.libraryTrack(for: entry),
                                     fetch: trending.fetches[entry.id],
                                     onPlay: { play(entry) },
                                     onDownload: { trending.download(entry) },
                                     onCancel: { trending.cancel(entry) })
                        }
                    } header: {
                        header
                    } footer: {
                        Text("Apple Music's most played songs, updated daily. Downloads are found on Soulseek and added to your library.")
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Trending")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { countryMenu }
            }
            .overlay {
                if trending.entries.isEmpty {
                    if trending.isLoading {
                        ProgressView()
                    } else if let error = trending.error {
                        ContentUnavailableView {
                            Label("Couldn't Load the Chart", systemImage: "chart.line.downtrend.xyaxis")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("Try Again") { Task { await trending.load(force: true) } }
                        }
                    }
                }
            }
            .refreshable { await trending.load(force: true) }
            .task { await trending.load() }
        }
    }

    private var header: some View {
        HStack {
            Text("Top Songs · \(TrendingStore.countryName(trending.country))")
            Spacer()
            if let updated = trending.updated {
                Text(updated.formatted(.relative(presentation: .named)))
                    .textCase(nil)
            }
        }
        .font(.subheadline.weight(.semibold))
    }

    private var countryMenu: some View {
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

    /// Plays the song, with the chart's other songs you have queued after it.
    private func play(_ entry: ChartEntry) {
        guard let track = trending.libraryTrack(for: entry) else { return }
        let tracks = trending.libraryTracks()
        player.play(tracks, startAt: tracks.firstIndex(of: track) ?? 0)
    }
}

private struct ChartRow: View {
    let entry: ChartEntry
    let track: Track?
    let fetch: TrendingStore.Fetch?
    let onPlay: () -> Void
    let onDownload: () -> Void
    let onCancel: () -> Void

    @EnvironmentObject private var player: Player

    var body: some View {
        HStack(spacing: 12) {
            Text("\(entry.rank)")
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(minWidth: 26, alignment: .trailing)
            AsyncImage(url: entry.artworkURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ArtworkPlaceholder()
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let track, player.current?.id == track.id {
                        Image(systemName: player.isPlaying ? "waveform" : "speaker.fill")
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }
                    Text(entry.title).lineLimit(1)
                }
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing
        }
        .contentShape(Rectangle())
        .onTapGesture { if track != nil { onPlay() } }
        .contextMenu {
            if let url = entry.appleMusicURL {
                Link(destination: url) { Label("Open in Apple Music", systemImage: "arrow.up.forward.app") }
            }
            if fetch?.isFailed == true {
                Button { onDownload() } label: { Label("Try Again", systemImage: "arrow.clockwise") }
            }
        }
    }

    private var subtitle: String {
        guard track == nil, let fetch else { return entry.artist }
        switch fetch {
        case .searching: return entry.artist + " · Searching Soulseek…"
        case let .downloading(fraction): return entry.artist + " · Downloading \(Int(fraction * 100))%"
        case let .failed(reason): return entry.artist + " · " + reason
        case .done: return entry.artist
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if track != nil {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.tint)
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
            .accessibilityLabel("Download \(entry.title)")
        }
    }
}
