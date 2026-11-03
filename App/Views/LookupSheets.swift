import SwiftUI

/// "Find Lyrics…": search LRCLIB by hand when the automatic match is missing or wrong, preview
/// a result, and save it as the song's .lrc (which then wins over any lookup).
struct LyricsSearchSheet: View {
    let track: Track

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var router: AppRouter
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [LyricsService.SearchResult] = []
    @State private var isSearching = false
    @State private var error: String?
    @State private var searched = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Song and artist", text: $query)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                            .onSubmit { Task { await search() } }
                        if isSearching { ProgressView() }
                    }
                } footer: {
                    Text("Lyrics come from LRCLIB. Synced ones scroll with the song; the one you pick is saved next to the song and used from then on.")
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                } else if searched, results.isEmpty, !isSearching {
                    Section { Text("Nothing found. Try fewer words, or just the song title.").foregroundStyle(.secondary) }
                }

                if !results.isEmpty {
                    Section("Results") {
                        ForEach(results) { result in
                            NavigationLink {
                                LyricsPreview(result: result, track: track) { save(result) }
                            } label: {
                                LyricsResultRow(result: result, songDuration: track.duration)
                            }
                            .disabled(!result.hasLyrics)
                        }
                    }
                }

                Section {
                    Button("Import .lrc File\u{2026}") {
                        dismiss()
                        router.importLyrics(for: track)
                    }
                }
            }
            .navigationTitle("Find Lyrics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task {
                guard query.isEmpty else { return }
                query = "\(track.artist) \(track.title)"
                await search()
            }
        }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isSearching = true
        error = nil
        defer {
            isSearching = false
            searched = true
        }
        do {
            let found = try await LyricsService.shared.search(text)
            // Synced first, then the closest length.
            results = found.sorted { lhs, rhs in
                if lhs.isSynced != rhs.isSynced { return lhs.isSynced }
                return distance(lhs) < distance(rhs)
            }
        } catch {
            self.error = "LRCLIB didn't answer. Check your connection and try again."
        }
    }

    private func distance(_ result: LyricsService.SearchResult) -> Double {
        guard let duration = result.duration, track.duration > 0 else { return .infinity }
        return abs(duration - track.duration)
    }

    private func save(_ result: LyricsService.SearchResult) {
        guard let text = result.fileText, library.saveLyrics(text, for: track) else {
            error = "Couldn't save the lyrics."
            return
        }
        Task {
            await LyricsService.shared.forget(cacheKey: track.id)
            router.lyricsChanged()
        }
        dismiss()
    }
}

private struct LyricsResultRow: View {
    let result: LyricsService.SearchResult
    let songDuration: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(result.trackName ?? "Untitled")
                .lineLimit(1)
            Text([result.artistName, result.albumName].compactMap { $0 }.joined(separator: " \u{00B7} "))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 6) {
                if result.isSynced {
                    BadgeLabel(text: "Synced", systemImage: "clock")
                } else if result.hasLyrics {
                    BadgeLabel(text: "Plain")
                } else if result.instrumental == true {
                    BadgeLabel(text: "Instrumental")
                }
                if let duration = result.duration {
                    Text(Self.time(duration))
                        .font(.caption)
                        .foregroundStyle(lengthMatches(duration) ? Color.green : Color.secondary)
                }
            }
        }
    }

    private func lengthMatches(_ duration: Double) -> Bool {
        songDuration > 0 && abs(duration - songDuration) <= 3
    }

    static func time(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct LyricsPreview: View {
    let result: LyricsService.SearchResult
    let track: Track
    let onUse: () -> Void

    var body: some View {
        List {
            Section {
                switch result.preview {
                case let .synced(lines):
                    ForEach(lines) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(LyricsResultRow.time(line.time))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(line.text)
                        }
                    }
                case let .plain(lines):
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                    }
                case .instrumental:
                    Text("Instrumental").foregroundStyle(.secondary)
                case .notFound:
                    Text("No lyrics in this result.").foregroundStyle(.secondary)
                }
            } header: {
                Text([result.trackName, result.artistName].compactMap { $0 }.joined(separator: " \u{2013} "))
            }
        }
        .navigationTitle("Preview")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button(action: onUse) {
                Text("Use These Lyrics")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding()
            .background(.bar)
        }
    }
}

/// "Find Cover Online…": the five best covers from Apple Music, Deezer and MusicBrainz for an
/// album or song; the one you tap becomes its cover (the files aren't changed).
struct CoverSearchSheet: View {
    let target: ArtworkTarget

    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var artist = ""
    @State private var title = ""
    @State private var results: [CoverCandidate] = []
    @State private var isSearching = false
    @State private var searched = false
    @State private var saving: String?
    @State private var error: String?

    private var kind: CoverSearch.Kind {
        if case .album = target { return .album }
        return .song
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Artist", text: $artist)
                        .autocorrectionDisabled()
                    TextField(kind == .album ? "Album" : "Song", text: $title)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { Task { await search() } }
                    Button {
                        Task { await search() }
                    } label: {
                        if isSearching { ProgressView() } else { Text("Search") }
                    }
                    .disabled(isSearching || (artist + title).trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }

                if !results.isEmpty {
                    Section {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 16) {
                            ForEach(results) { candidate in
                                Button {
                                    Task { await use(candidate) }
                                } label: {
                                    CoverCandidateTile(candidate: candidate, isSaving: saving == candidate.id)
                                }
                                .buttonStyle(.plain)
                                .disabled(saving != nil)
                            }
                        }
                        .padding(.vertical, 6)
                    } footer: {
                        Text("Tap a cover to use it. \u{201C}Use Original Artwork\u{201D} in the same menu undoes it.")
                    }
                } else if searched, !isSearching {
                    Section { Text("No covers found. Check the spelling, or try fewer words.").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Find Cover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task {
                guard artist.isEmpty, title.isEmpty else { return }
                switch target {
                case let .album(album):
                    artist = album.artist
                    title = album.title
                case let .track(track):
                    artist = track.artist
                    title = track.title
                }
                await search()
            }
        }
    }

    private func search() async {
        isSearching = true
        error = nil
        results = await CoverSearch.search(artist: artist.trimmingCharacters(in: .whitespaces),
                                           title: title.trimmingCharacters(in: .whitespaces),
                                           kind: kind)
        isSearching = false
        searched = true
    }

    private func use(_ candidate: CoverCandidate) async {
        saving = candidate.id
        defer { saving = nil }
        guard let data = await CoverSearch.download(candidate.fullURL) else {
            error = "Couldn't download that cover. Try another one."
            return
        }
        if await library.setCustomArtwork(data, for: target) {
            dismiss()
        } else {
            error = "That image couldn't be used."
        }
    }
}

private struct CoverCandidateTile: View {
    let candidate: CoverCandidate
    let isSaving: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            AsyncImage(url: candidate.thumbnailURL) { phase in
                switch phase {
                case let .success(image):
                    image.resizable().scaledToFill()
                case .failure:
                    Image(systemName: "photo").font(.title).foregroundStyle(.secondary)
                default:
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .background(Color.secondary.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                if isSaving {
                    ProgressView()
                        .padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
            Text(candidate.title)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
            Text(candidate.artist)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(candidate.source)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
