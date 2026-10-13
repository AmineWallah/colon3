import SoulseekKit
import SwiftUI

struct AlbumDetailView: View {
    let album: Album

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var completeness: AlbumCompletenessStore
    @EnvironmentObject private var soulseek: SoulseekModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.showMissingKey) private var showMissingSetting = true
    @State private var pendingDelete: [Track]?
    @State private var findingTrack: MissingTrack?

    /// Re-read after rescans so edits and deletions show up.
    private var current: Album { library.album(id: album.id) ?? album }

    private enum Row: Identifiable {
        case track(Track, number: Int)
        case missing(MissingTrack)

        var id: String {
            switch self {
            case let .track(track, _): return "t:" + track.id
            case let .missing(missing): return "m:" + missing.id
            }
        }

        var sortNumber: Int {
            switch self {
            case let .track(_, number): return number
            case let .missing(missing): return missing.number ?? 10_000
            }
        }
    }

    private struct Disc: Identifiable {
        let number: Int
        let rows: [Row]
        var id: Int { number }
    }

    private var missing: [MissingTrack] {
        guard showMissingSetting, !completeness.isHidden(current) else { return [] }
        return completeness.results[current.id]?.missing ?? []
    }

    private func discs(_ album: Album) -> [Disc] {
        var rows: [Int: [Row]] = [:]
        for disc in Set(album.tracks.map { $0.discNumber ?? 1 }) {
            let tracks = album.tracks.filter { ($0.discNumber ?? 1) == disc }
            rows[disc] = tracks.enumerated().map { offset, track in Row.track(track, number: track.trackNumber ?? offset + 1) }
        }
        for entry in missing { rows[entry.disc, default: []].append(.missing(entry)) }
        return rows.keys.sorted().map { number in
            Disc(number: number, rows: (rows[number] ?? []).enumerated().sorted { lhs, rhs in
                if lhs.element.sortNumber != rhs.element.sortNumber { return lhs.element.sortNumber < rhs.element.sortNumber }
                return lhs.offset < rhs.offset
            }.map(\.element))
        }
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
                        Text(album.artist).font(.title3).foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(album.artist).font(.title3).foregroundStyle(.tint)
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
                let allDiscs = discs(album)
                let showDiscs = allDiscs.count > 1
                ForEach(allDiscs) { disc in
                    if showDiscs {
                        Text("Disc \(disc.number)")
                            .font(.headline)
                            .padding(.horizontal, 20)
                            .padding(.top, 18)
                            .padding(.bottom, 4)
                    }
                    ForEach(disc.rows) { row in
                        switch row {
                        case let .track(track, number):
                            Button {
                                if let index = album.tracks.firstIndex(of: track) { player.play(album.tracks, startAt: index) }
                            } label: {
                                TrackRow(track: track, number: number, showArtwork: false,
                                         subtitle: track.artist != album.artist ? track.artist : nil)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 10)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                TrackMenuItems(tracks: [track]) { pendingDelete = $0 }
                            }
                        case let .missing(entry):
                            MissingTrackRow(track: entry, album: album) { findingTrack = entry }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                        }
                        Divider().padding(.leading, 56)
                    }
                }
            }
            .padding(.top, 16)
            .task(id: "\(album.id)#\(album.tracks.count)") { completeness.refresh(album) }

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
                    missingSongsMenu(album)
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
        .sheet(item: $findingTrack) { track in
            FindTrackSheet(track: track, album: current)
                .presentationDetents([.medium, .large])
        }
        .confirmDelete($pendingDelete) { deleted in
            // Leave the page once the whole album is gone.
            let remaining = Set(album.tracks.map(\.id)).subtracting(deleted.map(\.id))
            if remaining.isEmpty { dismiss() }
        }
    }

    @ViewBuilder
    private func missingSongsMenu(_ album: Album) -> some View {
        if showMissingSetting {
            Divider()
            let hidden = completeness.isHidden(album)
            Button {
                completeness.setHidden(album, !hidden)
            } label: {
                Label(hidden ? "Show Missing Songs" : "Hide Missing Songs", systemImage: hidden ? "eye" : "eye.slash")
            }
            let downloadable = missing.compactMap { entry -> (String, SharedFile)? in
                if case let .soulseek(username, file) = entry.source { return (username, file) }
                return nil
            }
            if !downloadable.isEmpty {
                Button {
                    for (username, file) in downloadable { soulseek.downloadMissing(file, from: username, into: album) }
                } label: {
                    Label("Download \(downloadable.count) Missing", systemImage: "arrow.down.circle")
                }
            }
            Button {
                completeness.refresh(album, force: true)
            } label: {
                Label("Check Tracklist Again", systemImage: "arrow.clockwise")
            }
        }
    }

    private func details(_ album: Album) -> String {
        let missingCount = missing.count
        let songs = missingCount > 0
            ? "\(album.tracks.count) of \(album.tracks.count + missingCount) songs"
            : "\(album.tracks.count) songs"
        return [album.year.map(String.init), songs].compactMap { $0 }.joined(separator: " · ")
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

/// A song the album should have but doesn't: greyed out, with a way to get it.
struct MissingTrackRow: View {
    let track: MissingTrack
    let album: Album
    let onFind: () -> Void

    @EnvironmentObject private var soulseek: SoulseekModel

    var body: some View {
        HStack(spacing: 12) {
            Text(track.number.map(String.init) ?? "–")
                .font(.body.monospacedDigit())
                .frame(minWidth: 24, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).lineLimit(1)
                Text("Not in your library").font(.caption)
            }
            Spacer(minLength: 8)
            if let duration = track.duration {
                Text(Formatting.duration(duration)).font(.subheadline.monospacedDigit())
            }
            action
        }
        .foregroundStyle(.secondary)
        .opacity(0.75)
    }

    @ViewBuilder
    private var action: some View {
        switch track.source {
        case let .soulseek(username, file):
            switch soulseek.state(of: file, from: username) {
            case .none, .some(.failed):
                Button {
                    soulseek.downloadMissing(file, from: username, into: album)
                } label: {
                    Image(systemName: "arrow.down.circle").font(.title3).foregroundStyle(.tint)
                }
                .buttonStyle(.borderless)
                .disabled(!soulseek.isLoggedIn)
            case .some(.completed):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            default:
                ProgressView()
            }
        case .musicBrainz:
            Button(action: onFind) {
                Image(systemName: "magnifyingglass.circle").font(.title3).foregroundStyle(.tint)
            }
            .buttonStyle(.borderless)
            .disabled(!soulseek.isLoggedIn)
        }
    }
}

/// Searches Soulseek for one missing song and drops the chosen file into the album's folder.
struct FindTrackSheet: View {
    let track: MissingTrack
    let album: Album

    @EnvironmentObject private var soulseek: SoulseekModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if soulseek.trackCandidates.isEmpty {
                        HStack(spacing: 10) {
                            if soulseek.isFindingTrack { ProgressView() }
                            Text(soulseek.isFindingTrack ? "Searching…" : "No matching files found.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(soulseek.trackCandidates) { candidate in
                        Button {
                            soulseek.downloadMissing(candidate.file, from: candidate.username, into: album)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(candidate.file.filename).lineLimit(2)
                                HStack(spacing: 8) {
                                    Text(quality(candidate.file))
                                    Text(Formatting.bytes(candidate.file.size))
                                    Label(candidate.username, systemImage: "person").lineLimit(1)
                                    if candidate.slotFree {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                    } else {
                                        Text("Queue \(candidate.queueLength)").foregroundStyle(.orange)
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("Tap a file to download it into \(album.title).")
                }
            }
            .navigationTitle(track.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task { soulseek.findTrack(artist: album.artist, title: track.title) }
        }
    }

    private func quality(_ file: SharedFile) -> String {
        if let depth = file.attributes.bitDepth, let rate = file.attributes.sampleRate {
            return "\(file.fileExtension.uppercased()) \(depth)/\(Formatting.kilohertz(rate))"
        }
        if let bitrate = file.attributes.bitrate { return "\(file.fileExtension.uppercased()) \(bitrate)k" }
        return file.fileExtension.uppercased()
    }
}
