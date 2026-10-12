import SwiftUI

struct ContentView: View {
    enum AppTab: String, Hashable {
        case library, search, downloads, settings
    }

    @EnvironmentObject private var soulseek: SoulseekModel
    @AppStorage("selectedTab") private var tab: AppTab = .library
    @AppStorage(AccentPalette.storageKey) private var accentHex = AccentPalette.defaultHex
    @State private var showPlayer = false

    var body: some View {
        TabView(selection: $tab) {
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
        }
        .modifier(TabAccessoryMiniPlayer(open: openPlayer))
        .sheet(isPresented: $showPlayer) {
            NowPlayingView()
                .tint(Color(hex: accentHex))
        }
        .tint(Color(hex: accentHex))
    }

    private func openPlayer() {
        showPlayer = true
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
