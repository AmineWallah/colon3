import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var soulseek: SoulseekModel
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var updates: UpdateChecker
    @AppStorage(AccentPalette.storageKey) private var accentHex = AccentPalette.defaultHex

    var body: some View {
        TabView(selection: $router.tab) {
            Tab("Home", systemImage: "square.grid.2x2", value: AppTab.trending) {
                HomeView().modifier(FallbackMiniPlayer(open: openPlayer))
            }
            Tab("Library", systemImage: "music.note.house", value: AppTab.library) {
                LibraryView().modifier(FallbackMiniPlayer(open: openPlayer))
            }
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search) {
                SearchView().modifier(FallbackMiniPlayer(open: openPlayer))
            }
            Tab("Downloads", systemImage: "arrow.down.circle", value: AppTab.downloads) {
                DownloadsView().modifier(FallbackMiniPlayer(open: openPlayer))
            }
            .badge(soulseek.activeDownloadCount)
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView()
            }
            .badge(updates.isUpdateAvailable ? 1 : 0)
        }
        .modifier(TabAccessoryMiniPlayer(isVisible: player.current != nil, open: openPlayer))
        .modifier(RouterPresenters(active: !router.showPlayer))
        .sheet(isPresented: $router.showPlayer) {
            NowPlayingView()
                .modifier(RouterPresenters(active: true))
                .tint(Color(hex: accentHex))
        }
        .onChange(of: library.artworkRevision) { _, _ in player.reloadArtwork() }
        .tint(Color(hex: accentHex))
    }

    private func openPlayer() {
        router.showPlayer = true
    }
}

/// Banner shown on screens that need the Soulseek connection.
struct ConnectionBanner: View {
    @EnvironmentObject private var soulseek: SoulseekModel

    var body: some View {
        switch soulseek.connection {
        case .loggedIn:
            EmptyView()
        case .connecting:
            Label("Connecting…", systemImage: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.secondary)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case .disconnected:
            Label(soulseek.hasCredentials ? "Disconnected" : "Log in under Settings to search Soulseek",
                  systemImage: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(.secondary)
        }
    }
}
