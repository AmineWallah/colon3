import SwiftUI

@main
struct Colon3App: App {
    @StateObject private var library: LibraryStore
    @StateObject private var soulseek: SoulseekModel
    @StateObject private var player: Player
    @StateObject private var favorites = FavoritesStore()
    @StateObject private var lastfm: LastFM
    @StateObject private var completeness: AlbumCompletenessStore
    @Environment(\.scenePhase) private var scenePhase
    private let transferMonitor: TransferMonitor

    init() {
        let library = LibraryStore()
        let player = Player(equalizer: Equalizer())
        let lastfm = LastFM()
        player.library = library
        player.scrobbler = lastfm
        let soulseek = SoulseekModel(library: library)
        let completeness = AlbumCompletenessStore()
        soulseek.completeness = completeness
        _completeness = StateObject(wrappedValue: completeness)
        transferMonitor = TransferMonitor(soulseek: soulseek, player: player)
        _library = StateObject(wrappedValue: library)
        _soulseek = StateObject(wrappedValue: soulseek)
        _player = StateObject(wrappedValue: player)
        _lastfm = StateObject(wrappedValue: lastfm)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(soulseek)
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(player.clock)
                .environmentObject(favorites)
                .environmentObject(lastfm)
                .environmentObject(completeness)
                .onAppear {
                    soulseek.start()
                    lastfm.flush()
                }
                .onOpenURL { url in
                    // "Open in colon3" / "Copy to colon3" from Files or another app.
                    Task {
                        _ = await library.importItems([url])
                        if url.path.contains("/Documents/Inbox/") { try? FileManager.default.removeItem(at: url) }
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                soulseek.reconnectIfNeeded()
                library.rescan()
                lastfm.flush()
            }
        }
    }
}
