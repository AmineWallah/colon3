import AppIntents
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var soulseek: SoulseekModel
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var lastfm: LastFM
    @EnvironmentObject private var spotify: SpotifyService
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var server: WiFiTransferServer
    @EnvironmentObject private var drive: GoogleDrive
    @EnvironmentObject private var backup: BackupService
    @EnvironmentObject private var updates: UpdateChecker
    @EnvironmentObject private var discord: DiscordPresence

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink { StatsView() } label: { StatsPreview() }
                }

                if updateAvailable {
                    Section {
                        NavigationLink { SoftwareUpdateSettings() } label: {
                            SettingsRow("Update Available", icon: "arrow.down.app.fill", color: .blue)
                        }
                    }
                }

                Section {
                    NavigationLink { SoulseekSettings() } label: {
                        SettingsRow("Soulseek", icon: "network", color: .teal,
                                    value: soulseek.isLoggedIn ? soulseek.username : "Offline")
                    }
                    NavigationLink { TransfersSettings() } label: {
                        SettingsRow("Transfers", icon: "arrow.up.arrow.down", color: .green,
                                    value: server.isRunning ? "Wi-Fi On" : nil)
                    }
                    NavigationLink { LibrarySettings() } label: {
                        SettingsRow("Library", icon: "music.note.house.fill", color: .pink,
                                    value: "\(library.tracks.count) songs")
                    }
                }

                Section {
                    NavigationLink { PlaybackSettings() } label: {
                        SettingsRow("Playback", icon: "play.fill", color: .red,
                                    value: player.bitPerfect ? "Bit-Perfect" : nil)
                    }
                    NavigationLink { AppearanceSettings() } label: {
                        SettingsRow("Appearance", icon: "paintbrush.fill", color: .indigo)
                    }
                    NavigationLink { SiriSettings() } label: {
                        SettingsRow("Siri & Shortcuts", icon: "mic.fill", color: .purple)
                    }
                }

                Section {
                    NavigationLink { LastFMSettings() } label: {
                        SettingsRow("Last.fm", icon: "dot.radiowaves.left.and.right", color: .red,
                                    value: lastfm.isConnected ? (lastfm.username ?? "On") : "Off")
                    }
                    NavigationLink { DiscordSettings() } label: {
                        SettingsRow("Discord", icon: "bubble.left.and.bubble.right.fill",
                                    color: Color(red: 0.345, green: 0.396, blue: 0.949),
                                    value: discord.isLinked && discord.enabled ? "On" : "Off")
                    }
                    NavigationLink { SpotifySettings() } label: {
                        SettingsRow("Spotify", icon: "music.note.list", color: .green,
                                    value: spotify.isLoggedIn ? (spotify.displayName ?? "On") : "Off")
                    }
                    NavigationLink { BackupView() } label: {
                        SettingsRow("Backup", icon: "icloud.and.arrow.up.fill", color: .blue, value: backupStatus)
                    }
                }

                Section {
                    NavigationLink { SoftwareUpdateSettings() } label: {
                        SettingsRow("Software Update", icon: "arrow.triangle.2.circlepath", color: .gray,
                                    value: updates.currentVersion)
                    }
                    NavigationLink { DiagnosticsView() } label: {
                        SettingsRow("Diagnostics & Logs", icon: "stethoscope", color: .gray)
                    }
                    NavigationLink { LogView() } label: {
                        SettingsRow("Connection Log", icon: "list.bullet.rectangle", color: .gray)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(isPresented: $router.showWiFiTransfer) { WiFiTransferView() }
        }
    }

    private var updateAvailable: Bool {
        if case .available = updates.state { return true }
        return false
    }

    private var backupStatus: String {
        if backup.isWorking { return "Working\u{2026}" }
        guard drive.isConnected else { return backup.pending.songs.isEmpty ? "Off" : "\(backup.pending.songs.count) missing" }
        return backup.lastBackup.map { $0.formatted(.relative(presentation: .named)) } ?? "Not Yet"
    }
}

/// A Settings row: coloured icon, title, and an optional value on the right.
struct SettingsRow: View {
    let title: String
    let icon: String
    let color: Color
    var value: String?

    init(_ title: String, icon: String, color: Color, value: String? = nil) {
        self.title = title
        self.icon = icon
        self.color = color
        self.value = value
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(title)
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: Pages

struct SoulseekSettings: View {
    @EnvironmentObject private var soulseek: SoulseekModel
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        Form {
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
            } footer: {
                Text("Logging in with an unused username registers it. There's no password reset, so pick something you'll remember.")
            }
        }
        .navigationTitle("Soulseek")
        .onAppear { username = soulseek.username }
    }
}

struct TransfersSettings: View {
    @EnvironmentObject private var server: WiFiTransferServer
    @AppStorage(AppSettings.backgroundTransfersKey) private var backgroundTransfers = true
    @AppStorage(AppSettings.transferActivityKey) private var transferActivity = true
    @AppStorage(AppSettings.seedingKey) private var seeding = false

    var body: some View {
        Form {
            Section {
                Toggle("Keep Transfers Running in Background", isOn: $backgroundTransfers)
                Toggle("Show Transfers in Dynamic Island", isOn: $transferActivity)
                Toggle("Seeding Mode", isOn: $seeding)
            } footer: {
                Text("When nothing is playing, colon3 plays silence (mixed under other audio) so iOS doesn't freeze transfers in the background, like iTorrent does. It costs some battery and stops when transfers finish. Seeding Mode keeps it running all the time so people can keep downloading from you, and reconnects if Soulseek drops.")
            }
            Section {
                NavigationLink { WiFiTransferView() } label: {
                    HStack {
                        Label("Wi-Fi Transfer", systemImage: "wifi")
                        Spacer()
                        if server.isRunning {
                            Text("On").foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("Add or download music from a computer's browser on the same Wi-Fi.")
            }
        }
        .navigationTitle("Transfers")
    }
}

struct LibrarySettings: View {
    @EnvironmentObject private var library: LibraryStore
    @AppStorage(AppSettings.artworkLookupKey) private var artworkLookup = true
    @AppStorage(AppSettings.lyricsLookupKey) private var lyricsLookup = true
    @AppStorage(AppSettings.showMissingKey) private var showMissing = true
    @AppStorage(AppSettings.musicBrainzKey) private var musicBrainz = true

    var body: some View {
        Form {
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
            } footer: {
                Text("Your music is also shared back on Soulseek while the app runs, so peers don't treat you as a leecher.")
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
        }
        .navigationTitle("Library")
    }
}

struct PlaybackSettings: View {
    @EnvironmentObject private var player: Player

    var body: some View {
        Form {
            Section {
                Toggle("Autoplay", isOn: $player.autoplay)
                Toggle("Autoplay Only from Library", isOn: $player.autoplayLibraryOnly)
                    .disabled(!player.autoplay)
                Toggle("Download Suggestions Automatically", isOn: $player.autoplayAutoDownload)
                    .disabled(!player.autoplay || player.autoplayLibraryOnly)
            } header: {
                Text("Autoplay")
            } footer: {
                Text("Autoplay keeps the music going when the queue ends. With a Last.fm API key (Settings › Last.fm) it picks songs similar to what you played: ones in your library play straight away; ones you don't have show under Up Next with a Download button, and play once downloaded (into the \u{201C}Found by Autoplay\u{201D} playlist). Turn on Download Suggestions Automatically to skip the button, or Only from Library to never suggest downloads. Recently played songs are skipped.")
            }

            Section {
                NavigationLink {
                    EqualizerView(equalizer: player.equalizer)
                } label: {
                    LabeledContent("Equalizer", value: player.bitPerfect ? "Bypassed"
                                   : (player.equalizer.isEnabled ? player.equalizer.displayName : "Off"))
                }
                Toggle("Bit-Perfect Mode", isOn: $player.bitPerfect)
                if player.bitPerfect {
                    BitPerfectStatus()
                }
            } header: {
                Text("Sound")
            } footer: {
                Text("Bit-Perfect Mode is for USB DACs: it switches the output to each song's sample rate and skips the EQ and all volume processing, so the DAC gets the file's exact samples. Turn the iPhone volume all the way up and use the DAC's volume. Bluetooth, AirPlay and the speaker can't be bit-perfect.")
            }
        }
        .navigationTitle("Playback")
    }
}

struct AppearanceSettings: View {
    var body: some View {
        Form {
            Section("Accent Colour") {
                AccentPicker()
            }
            Section {
                NavigationLink("Home Sections") { HomeSectionsSettings() }
            } header: {
                Text("Home")
            } footer: {
                Text("Reorder or hide the shelves on the Home tab.")
            }
        }
        .navigationTitle("Appearance")
    }
}

struct SiriSettings: View {
    private static let phrases = [
        "Play music in colon3",
        "Play a song in colon3",
        "Play <playlist> in colon3",
        "Shuffle <playlist> in colon3",
        "Shuffle colon3",
        "Play my favourites in colon3",
        "Pause colon3",
        "Next song in colon3",
        "Previous song in colon3",
        "What's playing in colon3",
    ]

    var body: some View {
        Form {
            Section {
                ForEach(Self.phrases, id: \.self) { phrase in
                    Text("\u{201C}\(phrase)\u{201D}")
                }
            } header: {
                Text("Try Saying")
            } footer: {
                Text("These work without any setup. \u{201C}Play a song\u{201D} asks what you want to hear: name a song, an album or an artist from your library, or say \u{201C}<song> by <artist>\u{201D}. Siri learns your playlist names as you make them. Pause, next and previous also work with plain \u{201C}Pause\u{201D} while colon3 is playing.")
            }
            Section {
                ShortcutsLink()
                    .frame(maxWidth: .infinity)
            } footer: {
                Text("Every action is also in the Shortcuts app, to build your own shortcuts or automations.")
            }
        }
        .navigationTitle("Siri & Shortcuts")
    }
}

struct LastFMSettings: View {
    @AppStorage(AppSettings.scrobblingKey) private var scrobbling = true

    var body: some View {
        Form {
            LastFMSection(scrobbling: $scrobbling)
        }
        .navigationTitle("Last.fm")
    }
}

struct DiscordSettings: View {
    @EnvironmentObject private var discord: DiscordPresence
    @State private var error: String?

    var body: some View {
        Form {
            if !DiscordPresence.isAvailable {
                Section {
                    Label("Not in this build", systemImage: "puzzlepiece.extension")
                } footer: {
                    Text(DiscordPresence.sdkIncluded
                         ? "This build has no Discord application ID. The README explains how to set one up."
                         : "Discord's SDK is closed source, so only builds made with it (like the ones from the install page, once it's set up) can show your music on Discord.")
                }
            } else if !discord.isLinked {
                Section {
                    Button {
                        link()
                    } label: {
                        if discord.isLinking { ProgressView() } else { Text("Connect Discord") }
                    }
                    .disabled(discord.isLinking)
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                } footer: {
                    Text("Shows what you're listening to on your Discord profile: the song, artist, album cover and how far in you are, like Spotify does. Sign in once; no token or developer app needed.")
                }
            } else {
                Section {
                    Toggle("Show What I'm Listening To", isOn: $discord.enabled)
                    if discord.enabled {
                        status
                    }
                } footer: {
                    Text("Shown while a song plays; pausing clears it. Album covers come from Apple's catalogue, since Discord can only show images from the web; songs it can't find show the colon3 icon.")
                }
                if discord.showsAsPlaying {
                    Section {
                        Button("Try \u{201C}Listening to\u{201D} Again") { discord.retryListening() }
                    } footer: {
                        Text("Discord didn't accept \u{201C}Listening to\u{201D} from colon3, so it shows \u{201C}Playing colon3\u{201D} instead, with the song and artist under it.")
                    }
                }
                Section {
                    Button("Disconnect Discord", role: .destructive) { discord.unlink() }
                }
            }
        }
        .navigationTitle("Discord")
    }

    @ViewBuilder
    private var status: some View {
        switch discord.connection {
        case .off:
            Label("Not connected", systemImage: "circle").foregroundStyle(.secondary)
        case .connecting:
            HStack(spacing: 10) {
                ProgressView()
                Text("Connecting\u{2026}").foregroundStyle(.secondary)
            }
        case .connected:
            Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }

    private func link() {
        error = nil
        Task {
            do {
                try await discord.link()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct SpotifySettings: View {
    var body: some View {
        Form {
            SpotifyAccountSection()
        }
        .navigationTitle("Spotify")
    }
}

struct SoftwareUpdateSettings: View {
    var body: some View {
        Form {
            SoftwareUpdateSection()
        }
        .navigationTitle("Software Update")
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

struct SoftwareUpdateSection: View {
    @EnvironmentObject private var updates: UpdateChecker
    @State private var showNotes = false

    var body: some View {
        Section {
            LabeledContent("Installed", value: "\(updates.currentVersion) (\(updates.currentBuild))"
                           + (updates.builtChannel == .beta ? " Beta" : ""))
            Picker("Channel", selection: $updates.channel) {
                ForEach(UpdateChecker.Channel.allCases) { Text($0.label).tag($0) }
            }
            status
            Button {
                Task { await updates.check() }
            } label: {
                Label("Check Now", systemImage: "arrow.clockwise")
            }
            .disabled(updates.state == .checking)
            Toggle("Check Automatically", isOn: $updates.automatic)
        } header: {
            Text("Software Update")
        } footer: {
            Text("Beta follows the beta branch, Stable follows main. Get Update opens \(updates.channel == .stable ? "the latest release" : "the releases list") on GitHub, with the IPA for SideStore or any signer; Install from Install Page uses \(updates.source). Installing keeps your music and settings.")
        }
    }

    @ViewBuilder
    private var status: some View {
        switch updates.state {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 10) {
                ProgressView()
                Text("Checking…").foregroundStyle(.secondary)
            }
        case .upToDate:
            VStack(alignment: .leading, spacing: 2) {
                Label("colon3 is up to date", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                if let checked = updates.lastChecked {
                    Text("Checked \(checked.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case let .available(remote):
            VStack(alignment: .leading, spacing: 6) {
                Label("Update available", systemImage: "arrow.down.app.fill")
                    .font(.headline)
                    .foregroundStyle(.tint)
                Text(details(remote))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                let notes = remote.cleanNotes
                if !notes.isEmpty {
                    Text((try? AttributedString(markdown: notes, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                         ?? AttributedString(notes))
                        .font(.footnote)
                        .lineLimit(showNotes ? nil : 3)
                        .onTapGesture { showNotes.toggle() }
                }
            }
            .padding(.vertical, 4)
            Button {
                updates.openReleases()
            } label: {
                Text("Get Update on GitHub")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .listRowSeparator(.hidden)
            Button("Install from Install Page") { updates.install(remote) }
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }

    private func details(_ remote: UpdateChecker.Remote) -> String {
        var parts = ["Version \(remote.version) (\(remote.build))"]
        if let date = remote.builtDate { parts.append(date.formatted(date: .abbreviated, time: .shortened)) }
        if let size = remote.size { parts.append(Formatting.bytes(UInt64(max(size, 0)))) }
        return parts.joined(separator: " · ")
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
