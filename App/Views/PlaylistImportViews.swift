import MediaPlayer
import SwiftUI
import UIKit

enum ImportSheetRoute: Identifiable, Equatable {
    case pick(ImportSource)
    case progress

    var id: String {
        switch self {
        case let .pick(source): return "pick-" + source.rawValue
        case .progress: return "progress"
        }
    }
}

/// Import from Spotify or Apple Music: choose a playlist, then follow the import.
struct PlaylistImportSheet: View {
    let route: ImportSheetRoute

    @EnvironmentObject private var importer: PlaylistImporter
    @Environment(\.dismiss) private var dismiss
    @State private var showingProgress: Bool

    init(route: ImportSheetRoute) {
        self.route = route
        _showingProgress = State(initialValue: route == .progress)
    }

    private var source: ImportSource {
        if case let .pick(source) = route { return source }
        return importer.job?.source ?? .spotify
    }

    var body: some View {
        NavigationStack {
            Group {
                if showingProgress, importer.job != nil {
                    ImportProgressView()
                } else {
                    switch source {
                    case .spotify: SpotifyImportPicker { showingProgress = true }
                    case .appleMusic: AppleMusicImportPicker { showingProgress = true }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Shown above a picker while another import is still running.
private struct RunningImportBanner: View {
    let onShow: () -> Void
    @EnvironmentObject private var importer: PlaylistImporter

    var body: some View {
        if let job = importer.job, job.isRunning {
            Section {
                Button(action: onShow) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Importing “\(job.name)”").foregroundStyle(.primary)
                            Text("\(job.doneCount) of \(job.songs.count) done. Wait for it to finish to start another.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}

// MARK: - Spotify

private struct PendingSpotifyImport: Identifiable {
    /// nil = Liked Songs.
    let playlistID: String?
    let name: String
    let count: Int?
    var id: String { playlistID ?? "liked" }
}

struct SpotifyImportPicker: View {
    let onStart: () -> Void

    @EnvironmentObject private var spotify: SpotifyService
    @EnvironmentObject private var importer: PlaylistImporter
    @State private var playlists: [SpotifyPlaylist] = []
    @State private var likedCount: Int?
    @State private var loading = false
    @State private var fetched: Int?
    @State private var fetchTotal = 0
    @State private var error: String?
    @State private var pending: PendingSpotifyImport?

    var body: some View {
        List {
            if !spotify.isLoggedIn {
                SpotifyAccountSection()
            } else {
                RunningImportBanner(onShow: onStart)
                Section {
                    row(name: "Liked Songs", subtitle: likedCount.map { "\($0) songs" } ?? "Your saved songs",
                        imageURL: nil, symbol: "heart.fill", enabled: true) {
                        pending = PendingSpotifyImport(playlistID: nil, name: "Liked Songs", count: likedCount)
                    }
                }
                Section {
                    ForEach(playlists) { playlist in
                        row(name: playlist.name, subtitle: subtitle(playlist), imageURL: playlist.imageURL,
                            symbol: "music.note.list", enabled: playlist.isReadable) {
                            pending = PendingSpotifyImport(playlistID: playlist.id, name: playlist.name,
                                                           count: playlist.trackCount)
                        }
                    }
                } header: {
                    Text("Your Playlists")
                } footer: {
                    Text("Spotify only lets developer apps read playlists you own or collaborate on, so playlists you just follow are greyed out. Songs already in your library are added right away; the rest are searched on Soulseek and downloaded.")
                }
            }
            if let error {
                Section {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Import from Spotify")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if let fetched {
                let label = fetchTotal > 0 ? "Reading songs… \(fetched) of \(fetchTotal)" : "Reading songs… \(fetched)"
                ProgressView(label)
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else if loading, playlists.isEmpty {
                ProgressView()
            }
        }
        .task(id: spotify.isLoggedIn) {
            if spotify.isLoggedIn { await load() }
        }
        .refreshable { await load() }
        .confirmationDialog(pending.map { "Import “\($0.name)”?" } ?? "",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible, presenting: pending) { item in
            Button(item.count.map { "Import \($0) Songs" } ?? "Import") {
                Task { await run(item) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Songs not in your library are downloaded from Soulseek into a new playlist. Large playlists take a while; you can close this and check back from Library › Playlists.")
        }
    }

    private func subtitle(_ playlist: SpotifyPlaylist) -> String {
        var parts: [String] = []
        if let count = playlist.trackCount { parts.append("\(count) songs") }
        if !playlist.owner.isEmpty, !playlist.isReadable { parts.append("by \(playlist.owner)") }
        return parts.joined(separator: " · ")
    }

    private func row(name: String, subtitle: String, imageURL: URL?, symbol: String, enabled: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.secondary.opacity(0.15))
                    if let imageURL {
                        AsyncImage(url: imageURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Image(systemName: symbol).foregroundStyle(.secondary)
                        }
                    } else {
                        Image(systemName: symbol).foregroundStyle(.tint)
                    }
                }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).foregroundStyle(.primary).lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled || importer.isRunning || fetched != nil)
        .opacity(enabled ? 1 : 0.45)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            playlists = try await spotify.playlists()
            likedCount = try? await spotify.likedSongsCount()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func run(_ item: PendingSpotifyImport) async {
        fetched = 0
        fetchTotal = item.count ?? 0
        defer { fetched = nil }
        do {
            let songs = try await spotify.songs(inPlaylist: item.playlistID) { loaded, total in
                fetched = loaded
                fetchTotal = total
            }
            guard !songs.isEmpty else {
                error = "Spotify didn't return any songs for “\(item.name)”."
                return
            }
            error = nil
            importer.start(name: item.name, source: .spotify, sourceKey: "spotify:" + item.id, songs: songs)
            onStart()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Client ID, redirect URI and login. Used in Settings and the import screen.
struct SpotifyAccountSection: View {
    @EnvironmentObject private var spotify: SpotifyService
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        Section {
            if spotify.isLoggedIn {
                Label("Logged in as \(spotify.displayName ?? "Spotify user")", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                LabeledContent("Client ID", value: spotify.clientID)
                    .font(.footnote.monospaced())
                    .lineLimit(1)
                Button("Log Out", role: .destructive) { spotify.logOut() }
            } else {
                TextField("Client ID", text: $spotify.clientID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                Button {
                    UIPasteboard.general.string = SpotifyService.redirectURI
                    copied = true
                } label: {
                    LabeledContent("Redirect URI") {
                        Label(copied ? "Copied" : SpotifyService.redirectURI,
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.footnote.monospaced())
                    }
                }
                Button {
                    logIn()
                } label: {
                    if spotify.isLoggingIn { ProgressView() } else { Text("Log In with Spotify") }
                }
                .disabled(spotify.isLoggingIn || spotify.clientID.trimmingCharacters(in: .whitespaces).isEmpty)
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                Link("Open the Spotify Developer Dashboard", destination: URL(string: "https://developer.spotify.com/dashboard")!)
            }
        } header: {
            Text("Spotify")
        } footer: {
            Text(spotify.isLoggedIn
                 ? "Used only to read your playlists and Liked Songs for importing. The login is kept in the Keychain."
                 : "Uses your own Spotify developer app. Create one in the dashboard (the owner needs Premium), add the redirect URI above exactly, tick Web API, then paste its Client ID here. No client secret is needed.")
        }
    }

    private func logIn() {
        error = nil
        Task {
            do {
                try await spotify.logIn()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Apple Music

struct AppleMusicImportPicker: View {
    let onStart: () -> Void

    @EnvironmentObject private var appleMusic: AppleMusicLibrary
    @EnvironmentObject private var importer: PlaylistImporter
    @Environment(\.openURL) private var openURL
    @State private var playlists: [AppleMusicPlaylist] = []
    @State private var pending: AppleMusicPlaylist?
    @State private var error: String?

    var body: some View {
        List {
            switch appleMusic.status {
            case .authorized:
                RunningImportBanner(onShow: onStart)
                Section {
                    if playlists.isEmpty {
                        Text("No playlists in your Music library.").foregroundStyle(.secondary)
                    }
                    ForEach(playlists) { playlist in
                        Button {
                            pending = playlist
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: playlist.isSmart ? "gearshape" : "music.note.list")
                                    .foregroundStyle(.tint)
                                    .frame(width: 48, height: 48)
                                    .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(playlist.name).foregroundStyle(.primary).lineLimit(1)
                                    Text("\(playlist.songCount) song\(playlist.songCount == 1 ? "" : "s")")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(playlist.songCount == 0 || importer.isRunning)
                    }
                } footer: {
                    Text("Playlists in the Music app on this iPhone. Songs are matched by title, artist and length: ones already in colon3 are added right away, the rest are downloaded from Soulseek.")
                }
            case .notDetermined:
                Section {
                    Button("Allow Access to Your Music Library") {
                        Task {
                            await appleMusic.requestAccess()
                            playlists = appleMusic.playlists()
                        }
                    }
                } footer: {
                    Text("colon3 reads your playlists' song names to find the songs. It doesn't change anything in Apple Music.")
                }
            case .denied, .restricted:
                Section {
                    Text("colon3 isn't allowed to read your Music library.")
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                } footer: {
                    Text("Turn on Media & Apple Music for colon3 in the Settings app.")
                }
            @unknown default:
                EmptyView()
            }
            if let error {
                Section {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Import from Apple Music")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await appleMusic.requestAccess()
            playlists = appleMusic.playlists()
        }
        .confirmationDialog(pending.map { "Import “\($0.name)”?" } ?? "",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible, presenting: pending) { playlist in
            Button("Import \(playlist.songCount) Songs") { run(playlist) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Songs not in your library are downloaded from Soulseek into a new playlist. Large playlists take a while; you can close this and check back from Library › Playlists.")
        }
    }

    private func run(_ playlist: AppleMusicPlaylist) {
        let songs = appleMusic.songs(inPlaylist: playlist.id)
        guard !songs.isEmpty else {
            error = "Couldn't read the songs in “\(playlist.name)”."
            return
        }
        error = nil
        importer.start(name: playlist.name, source: .appleMusic, sourceKey: "applemusic:\(playlist.id)", songs: songs)
        onStart()
    }
}

// MARK: - Progress

struct ImportProgressView: View {
    @EnvironmentObject private var importer: PlaylistImporter
    @EnvironmentObject private var soulseek: SoulseekModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let job = importer.job {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(job.name).font(.title3.weight(.bold))
                        Label("From \(job.source.title)", systemImage: job.source.systemImage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        ProgressView(value: Double(job.doneCount), total: Double(max(job.songs.count, 1)))
                        Text(ImportProgressView.summary(job))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    if job.isRunning, !soulseek.isLoggedIn {
                        Label("Waiting for Soulseek. Log in under Settings if you haven't.", systemImage: "antenna.radiowaves.left.and.right")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                    if job.isRunning {
                        Button("Cancel Import", role: .destructive) { importer.cancel() }
                    } else {
                        if job.notFoundCount > 0 {
                            Button("Retry Not Found (\(job.notFoundCount))") { importer.retryNotFound() }
                        }
                        Button("Clear from Playlists") {
                            importer.dismiss()
                            dismiss()
                        }
                    }
                } footer: {
                    if job.isRunning {
                        Text("Songs are searched one at a time, spaced out so the Soulseek server isn't flooded. You can close this; the import keeps going while colon3 is open.")
                    }
                }

                Section("Songs") {
                    ForEach(job.songs) { song in
                        ImportSongRow(song: song)
                    }
                }
            }
            .navigationTitle(job.isRunning ? "Importing" : "Import Finished")
            .navigationBarTitleDisplayMode(.inline)
        } else {
            EmptyStateView(title: "No Import", message: "Start one from Library › Playlists.", systemImage: "square.and.arrow.down")
        }
    }

    static func summary(_ job: ImportJob) -> String {
        var parts = ["\(job.addedCount) downloaded", "\(job.inLibraryCount) already in library"]
        if job.notFoundCount > 0 { parts.append("\(job.notFoundCount) not found") }
        if job.pendingCount > 0 { parts.append("\(job.pendingCount) to go") }
        return parts.joined(separator: " · ")
    }
}

struct ImportSongRow: View {
    let song: ImportSong

    var body: some View {
        HStack(spacing: 12) {
            Text("\(song.id + 1)")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 26, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.song.title).lineLimit(1)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            status
                .font(.caption.weight(.medium))
                .labelStyle(.titleAndIcon)
        }
    }

    private var subtitle: String {
        let artists = song.song.artists.joined(separator: ", ")
        switch song.status {
        case let .notFound(reason):
            return reason
        case .downloading, .added:
            return song.detail.map { artists + " · " + $0 } ?? artists
        default:
            return artists
        }
    }

    @ViewBuilder
    private var status: some View {
        switch song.status {
        case .waiting:
            Label("Waiting", systemImage: "clock")
                .foregroundStyle(.secondary)
        case .inLibrary:
            Label("In Library", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .searching:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Searching")
            }
            .foregroundStyle(.secondary)
        case let .downloading(fraction):
            Label(fraction >= 1 ? "Adding" : "\(Int(fraction * 100))%", systemImage: "arrow.down.circle")
                .foregroundStyle(.tint)
        case .added:
            Label("Added", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.tint)
        case .notFound:
            Label("Not Found", systemImage: "xmark.circle")
                .foregroundStyle(.orange)
        }
    }
}
