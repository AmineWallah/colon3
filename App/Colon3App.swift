import SwiftUI

@main
struct Colon3App: App {
    @StateObject private var library: LibraryStore
    @StateObject private var soulseek: SoulseekModel
    @StateObject private var player: Player
    @StateObject private var favorites = FavoritesStore()
    @StateObject private var playlists = PlaylistStore()
    @StateObject private var lastfm: LastFM
    @StateObject private var completeness: AlbumCompletenessStore
    @StateObject private var stats: StatsStore
    @StateObject private var router = AppRouter()
    @StateObject private var discord: DiscordPresence
    @StateObject private var wifi: WiFiTransferServer
    @StateObject private var updates = UpdateChecker()
    @Environment(\.scenePhase) private var scenePhase
    private let transferMonitor: TransferMonitor

    init() {
        Diagnostics.shared.start()
        let library = LibraryStore()
        let player = Player(equalizer: Equalizer())
        let lastfm = LastFM()
        let stats = StatsStore()
        player.library = library
        player.scrobbler = lastfm
        player.stats = stats
        let soulseek = SoulseekModel(library: library)
        let completeness = AlbumCompletenessStore()
        soulseek.completeness = completeness
        soulseek.stats = stats
        let discord = DiscordPresence()
        discord.attach(player)
        let wifi = WiFiTransferServer(root: library.root)
        wifi.onFilesChanged = { [weak library] in library?.rescan() }
        _completeness = StateObject(wrappedValue: completeness)
        transferMonitor = TransferMonitor(soulseek: soulseek, player: player, stats: stats)
        _library = StateObject(wrappedValue: library)
        _soulseek = StateObject(wrappedValue: soulseek)
        _player = StateObject(wrappedValue: player)
        _lastfm = StateObject(wrappedValue: lastfm)
        _stats = StateObject(wrappedValue: stats)
        _discord = StateObject(wrappedValue: discord)
        _wifi = StateObject(wrappedValue: wifi)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(soulseek)
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(player.clock)
                .environmentObject(favorites)
                .environmentObject(playlists)
                .environmentObject(lastfm)
                .environmentObject(completeness)
                .environmentObject(stats)
                .environmentObject(router)
                .environmentObject(discord)
                .environmentObject(wifi)
                .environmentObject(updates)
                .onAppear {
                    soulseek.start()
                    lastfm.flush()
                    updates.checkIfDue()
                }
                .onOpenURL { url in
                    // colon3:// links (Dynamic Island, Shortcuts, Back Tap) navigate.
                    if url.scheme?.lowercased() == "colon3" {
                        router.handle(url)
                        return
                    }
                    // "Open in colon3" / "Copy to colon3" from Files or another app.
                    Task {
                        _ = await library.importItems([url])
                        if url.path.contains("/Documents/Inbox/") { try? FileManager.default.removeItem(at: url) }
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                soulseek.reconnectIfNeeded()
                library.rescan()
                lastfm.flush()
                discord.resumeIfNeeded()
                updates.checkIfDue()
            case .background:
                stats.save()
            default:
                break
            }
        }
    }
}
