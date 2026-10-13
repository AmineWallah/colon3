import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum AppTab: String, Hashable {
    case library, search, downloads, settings
}

/// Whose cover a picked image replaces.
enum ArtworkTarget: Identifiable {
    case album(Album)
    case track(Track)

    var id: String { source.key }

    var source: ArtworkSource {
        switch self {
        case let .album(album): return .album(album)
        case let .track(track): return .track(track)
        }
    }

    var title: String {
        switch self {
        case let .album(album): return album.title
        case let .track(track): return track.title
        }
    }
}

/// What the shared file picker is choosing.
enum ImportKind {
    case music
    case playlist
    case lyrics(Track)
    case artwork(ArtworkTarget)

    var types: [UTType] {
        switch self {
        case .music: return LibraryStore.importableTypes
        case .playlist: return [.m3uPlaylist, UTType(filenameExtension: "m3u8"), UTType(filenameExtension: "m3u")].compactMap { $0 }
        case .lyrics: return [UTType(filenameExtension: "lrc"), .plainText, .text].compactMap { $0 }
        case .artwork: return [.image]
        }
    }

    var allowsMultiple: Bool {
        if case .music = self { return true }
        return false
    }
}

struct PlaylistRequest: Identifiable {
    let id = UUID()
    let tracks: [Track]
}

/// App-wide navigation and the pickers/sheets any screen can ask for (context menus can't
/// present things themselves). Also handles colon3:// links from the Dynamic Island,
/// Shortcuts and Back Tap.
@MainActor
final class AppRouter: ObservableObject {
    @Published var tab: AppTab {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: "selectedTab") }
    }
    @Published var showPlayer = false
    @Published var showWiFiTransfer = false
    @Published var playlistRequest: PlaylistRequest?
    @Published var showImporter = false
    @Published private(set) var importKind: ImportKind = .music
    @Published private(set) var photoTarget: ArtworkTarget?
    @Published var showPhotoPicker = false
    @Published var message: String?
    /// Bumped when local lyrics change so the lyrics view reloads.
    @Published private(set) var lyricsRevision = 0
    @Published var pendingSearch: String?

    init() {
        tab = UserDefaults.standard.string(forKey: "selectedTab").flatMap(AppTab.init(rawValue:)) ?? .library
    }

    func importMusic() { presentImporter(.music) }
    func importPlaylist() { presentImporter(.playlist) }
    func importLyrics(for track: Track) { presentImporter(.lyrics(track)) }
    func importArtworkFile(for target: ArtworkTarget) { presentImporter(.artwork(target)) }
    func pickArtworkPhoto(for target: ArtworkTarget) {
        photoTarget = target
        showPhotoPicker = true
    }
    func addToPlaylist(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        playlistRequest = PlaylistRequest(tracks: tracks)
    }

    func lyricsChanged() { lyricsRevision += 1 }

    private func presentImporter(_ kind: ImportKind) {
        importKind = kind
        showImporter = true
    }

    /// colon3://player, colon3://downloads, colon3://library, colon3://search?q=…, colon3://wifi
    func handle(_ url: URL) {
        switch url.host?.lowercased() {
        case "player", "nowplaying":
            showPlayer = true
        case "downloads", "transfers":
            showPlayer = false
            tab = .downloads
        case "library":
            showPlayer = false
            tab = .library
        case "search":
            showPlayer = false
            tab = .search
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "q" })?.value
            if let query, !query.isEmpty { pendingSearch = query }
        case "settings":
            showPlayer = false
            tab = .settings
        case "wifi", "transfer":
            showPlayer = false
            tab = .settings
            showWiFiTransfer = true
        default:
            break
        }
    }
}
