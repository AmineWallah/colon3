import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var soulseek: SoulseekModel
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var lastfm: LastFM
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var server: WiFiTransferServer

    @AppStorage(AppSettings.artworkLookupKey) private var artworkLookup = true
    @AppStorage(AppSettings.lyricsLookupKey) private var lyricsLookup = true
    @AppStorage(AppSettings.scrobblingKey) private var scrobbling = true
    @AppStorage(AppSettings.backgroundTransfersKey) private var backgroundTransfers = true
    @AppStorage(AppSettings.transferActivityKey) private var transferActivity = true
    @AppStorage(AppSettings.showMissingKey) private var showMissing = true
    @AppStorage(AppSettings.musicBrainzKey) private var musicBrainz = true
    @AppStorage(AppSettings.seedingKey) private var seeding = false

    @State private var username = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink { StatsView() } label: { StatsPreview() }
                }

                soulseekSection

                Section("Accent Colour") {
                    AccentPicker()
                }

                Section {
                    NavigationLink {
                        EqualizerView(equalizer: player.equalizer)
                    } label: {
                        LabeledContent("Equalizer", value: player.bitPerfect ? "Bypassed"
                                       : (player.equalizer.isEnabled ? player.equalizer.presetName : "Off"))
                    }
                    Toggle("Bit-Perfect Mode", isOn: $player.bitPerfect)
                    if player.bitPerfect {
                        BitPerfectStatus()
                    }
                } header: {
                    Text("Playback")
                } footer: {
                    Text("For USB DACs: switches the output to each song's sample rate and skips the EQ and all volume processing, so the DAC gets the file's exact samples. Turn the iPhone volume all the way up and use the DAC's volume. Bluetooth, AirPlay and the speaker can't be bit-perfect.")
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
                    Toggle("Seeding Mode", isOn: $seeding)
                    Button {
                        router.showWiFiTransfer = true
                    } label: {
                        HStack {
                            Label("Wi-Fi Transfer", systemImage: "wifi")
                            Spacer()
                            if server.isRunning {
                                Text("On").foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("Transfers")
                } footer: {
                    Text("When nothing is playing, colon3 plays silence (mixed under other audio) so iOS doesn't freeze transfers in the background, like iTorrent does. It costs some battery and stops when transfers finish. Seeding Mode keeps it running all the time so people can keep downloading from you, and reconnects if Soulseek drops.")
                }

                LastFMSection(scrobbling: $scrobbling)

                DiscordSection()

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
            .navigationDestination(isPresented: $router.showWiFiTransfer) { WiFiTransferView() }
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
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var server: WiFiTransferServer

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

/// Live output details while bit-perfect mode is on.
struct BitPerfectStatus: View {
    @EnvironmentObject private var player: Player

    var body: some View {
        let output = player.output
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Output", value: output.routeName.isEmpty ? "–" : output.routeName)
            LabeledContent("Hardware Rate", value: Formatting.sampleRate(output.hardwareRate))
            if output.fileRate > 0 {
                LabeledContent("Song Rate", value: Formatting.sampleRate(output.fileRate))
            }
            if player.current != nil {
                if output.isBitPerfect(enabled: true) {
                    Label("Bit-perfect", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else if let reason = output.blocker(enabled: true) {
                    Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
        }
        .font(.subheadline)
        .onAppear { player.refreshOutputInfo() }
    }
}

struct DiscordSection: View {
    @EnvironmentObject private var discord: DiscordPresence
    @State private var token = ""
    @State private var showWarning = false

    var body: some View {
        Section {
            if discord.hasToken {
                Toggle("Show What I'm Listening To", isOn: $discord.enabled)
                statusRow
                Picker("Status", selection: $discord.onlineStatus) {
                    ForEach(DiscordPresence.OnlineStatus.allCases) { Text($0.label).tag($0) }
                }
                TextField("Application ID (for cover art)", text: $discord.applicationID)
                    .keyboardType(.numberPad)
                    .font(.body.monospacedDigit())
                Button("Remove Token", role: .destructive) { discord.forgetToken() }
            } else {
                SecureField("Discord Token", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Connect") { showWarning = true }
                    .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Discord")
        } footer: {
            Text(discord.hasToken
                 ? "Shows “Listening to colon3” with the song and artist while music plays. For cover art, create an application at discord.com/developers (name it colon3) and paste its Application ID."
                 : "Discord has no official way for iPhone apps to set your status, so this uses your account token (Discord in a browser › Developer Tools › Network › any request › Authorization header). It's stored in the Keychain and only sent to Discord.")
        }
        .alert("Use your Discord token?", isPresented: $showWarning) {
            Button("Cancel", role: .cancel) {}
            Button("I Understand") {
                discord.saveToken(token)
                token = ""
            }
        } message: {
            Text("Using a token from a third-party app breaks Discord's Terms of Service and could get your account flagged. Anyone with the token has full access to your account, so never share it.")
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch discord.status {
        case .off:
            Label("Off", systemImage: "circle").foregroundStyle(.secondary)
        case .connecting:
            Label("Connecting…", systemImage: "antenna.radiowaves.left.and.right").foregroundStyle(.secondary)
        case let .connected(name):
            Label("Connected as \(name)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
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
