import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingPlayer = false

    var body: some View {
        TabView {
            SearchView()
                .miniPlayer(showingPlayer: $showingPlayer)
                .tabItem { Label("Search", systemImage: "magnifyingglass") }

            DownloadsView()
                .miniPlayer(showingPlayer: $showingPlayer)
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
                .badge(model.activeDownloadCount)

            LibraryView()
                .miniPlayer(showingPlayer: $showingPlayer)
                .tabItem { Label("Library", systemImage: "music.note.list") }

            SettingsView()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
        }
        .sheet(isPresented: $showingPlayer) {
            NowPlayingView()
        }
    }
}

/// Banner shown on screens that need a server connection.
struct ConnectionBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        switch model.connection {
        case .loggedIn:
            EmptyView()
        case .connecting:
            Label("Connecting…", systemImage: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.secondary)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case .disconnected:
            Label(model.hasCredentials ? "Disconnected" : "Log in on the Account tab to start",
                  systemImage: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(.secondary)
        }
    }
}
