import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var soulseek: SoulseekModel
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var lastfm: LastFM

    @AppStorage(AppSettings.artworkLookupKey) private var artworkLookup = true
    @AppStorage(AppSettings.lyricsLookupKey) private var lyricsLookup = true
    @AppStorage(AppSettings.scrobblingKey) private var scrobbling = true
    @AppStorage(AppSettings.backgroundTransfersKey) private var backgroundTransfers = true
    @AppStorage(AppSettings.transferActivityKey) private var transferActivity = true
    @AppStorage(AppSettings.showMissingKey) private var showMissing = true
    @AppStorage(AppSettings.musicBrainzKey) private var musicBrainz = true

    @State private var username = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                soulseekSection

                Section("Accent Colour") {
                    AccentPicker()
                }

                Section("Playback") {
                    NavigationLink {
                        EqualizerView(equalizer: player.equalizer)
                    } label: {
                        LabeledContent("Equalizer", value: player.equalizer.isEnabled ? player.equalizer.presetName : "Off")
                    }
                }

                Section {
                    Toggle("Look Up Missing Artwork", isOn: $artworkLookup)
                    Toggle("Fetch Lyrics", isOn: $lyricsLookup)
                    Toggle("Show Missing Album Songs", isOn: $showMissing)
                    Toggle("Look Up Tracklists on MusicBrainz", isOn: $musicBrainz)
                        .disabled(!showMissing)
                } header: {
                    Text("Online")
                } footer: {
                    Text("Artwork comes from the iTunes Search API when a song has none of its own; lyrics come from LRCLIB. Missing songs come from the Soulseek folder an album was downloaded from, or from MusicBrainz otherwise.")
                }

                Section {
                    Toggle("Keep Transfers Running in Background", isOn: $backgroundTransfers)
                    Toggle("Show Transfers in Dynamic Island", isOn: $transferActivity)
                } header: {
                    Text("Transfers")
                } footer: {
                    Text("When nothing is playing, colon3 plays silence (mixed under other audio) so iOS doesn't freeze transfers in the background, like iTorrent does. It costs some battery and stops when transfers finish.")
                }

                LastFMSection(scrobbling: $scrobbling)

                Section {
                    LabeledContent("Songs", value: "\(library.tracks.count)")
                    LabeledContent("Albums", value: "\(library.albums.count)")
                    Button("Rescan Library") { library.rescan() }
                    Button("Clear Artwork Cache") {
                        Task {
                            await ArtworkStore.shared.clearDisk()
                            library.bumpArtwork()
                        }
                    }
                } header: {
                    Text("Library")
                } footer: {
                    Text("Your music is also shared back on Soulseek while the app runs, so peers don't treat you as a leecher.")
                }

                Section {
                    NavigationLink("Connection Log") { LogView() }
                }
            }
            .navigationTitle("Settings")
            .onAppear { username = soulseek.username }
        }
    }

    private var soulseekSection: some View {
        Section {
            if soulseek.isLoggedIn {
                Label("Logged in as \(soulseek.username)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                ConnectionBanner()
            }
            TextField("Username", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Password", text: $password)
            Button(soulseek.isLoggedIn ? "Reconnect" : "Log In") {
                soulseek.logIn(username: username, password: password)
                password = ""
            }
            .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
            if soulseek.isLoggedIn {
                Button("Disconnect", role: .destructive) { soulseek.logOut() }
            }
        } header: {
            Text("Soulseek")
        } footer: {
            Text("Logging in with an unused username registers it. There's no password reset, so pick something you'll remember.")
        }
    }
}

struct LastFMSection: View {
    @Binding var scrobbling: Bool
    @EnvironmentObject private var lastfm: LastFM

    @State private var apiKey = ""
    @State private var apiSecret = ""
    @State private var username = ""
    @State private var password = ""
    @State private var connecting = false
    @State private var error: String?

    var body: some View {
        Section {
            if lastfm.isConnected {
                Label("Connected as \(lastfm.username ?? "?")", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Toggle("Scrobble", isOn: $scrobbling)
                if lastfm.pendingCount > 0 {
                    LabeledContent("Waiting to Send", value: "\(lastfm.pendingCount)")
                    Button("Send Now") { lastfm.flush() }
                }
                if let lastError = lastfm.lastError {
                    Text(lastError).font(.footnote).foregroundStyle(.orange)
                }
                Button("Disconnect", role: .destructive) { lastfm.disconnect() }
            } else {
                TextField("API Key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                SecureField("Shared Secret", text: $apiSecret)
                TextField("Last.fm Username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                Button {
                    connect()
                } label: {
                    if connecting { ProgressView() } else { Text("Connect") }
                }
                .disabled(connecting || [apiKey, apiSecret, username, password].contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                Link("Create an API account", destination: URL(string: "https://www.last.fm/api/account/create")!)
            }
        } header: {
            Text("Last.fm")
        } footer: {
            Text(lastfm.isConnected
                 ? "Tracks scrobble after half their length or 4 minutes. Offline scrobbles are sent later."
                 : "Last.fm needs your own API key and shared secret. Create an API account (any name and description), then paste both here. Your password is only used once to get a session.")
        }
    }

    private func connect() {
        connecting = true
        error = nil
        Task {
            do {
                try await lastfm.connect(apiKey: apiKey, apiSecret: apiSecret, username: username, password: password)
                password = ""
            } catch {
                self.error = error.localizedDescription
            }
            connecting = false
        }
    }
}

struct LogView: View {
    @EnvironmentObject private var soulseek: SoulseekModel

    var body: some View {
        List(Array(soulseek.logLines.indices.reversed()), id: \.self) { index in
            Text(soulseek.logLines[index])
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
        .navigationTitle("Log")
        .navigationBarTitleDisplayMode(.inline)
    }
}
