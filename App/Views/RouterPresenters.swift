import PhotosUI
import SwiftUI

/// The pickers and sheets AppRouter can ask for. Attached twice: to the tab view, and to the
/// Now Playing sheet (a sheet can't be presented from under another one). `active` makes sure
/// only the frontmost copy reacts.
struct RouterPresenters: ViewModifier {
    let active: Bool

    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playlists: PlaylistStore
    @State private var photoItem: PhotosPickerItem?

    func body(content: Content) -> some View {
        content
            .sheet(item: active ? $router.playlistRequest : .constant(nil)) { request in
                AddToPlaylistSheet(request: request)
            }
            .sheet(item: active ? $router.playlistImport : .constant(nil)) { route in
                PlaylistImportSheet(route: route)
            }
            .fileImporter(isPresented: active ? $router.showImporter : .constant(false),
                          allowedContentTypes: router.importKind.types,
                          allowsMultipleSelection: router.importKind.allowsMultiple) { result in
                guard case let .success(urls) = result, !urls.isEmpty else { return }
                handleImport(urls, kind: router.importKind)
            }
            .photosPicker(isPresented: active ? $router.showPhotoPicker : .constant(false),
                          selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { _, item in
                guard active, let item, let target = router.photoTarget else { return }
                photoItem = nil
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self) else {
                        router.message = "Couldn't read that photo."
                        return
                    }
                    if !(await library.setCustomArtwork(data, for: target)) {
                        router.message = "That image couldn't be used."
                    }
                }
            }
            .alert(router.message ?? "",
                   isPresented: Binding(get: { active && router.message != nil },
                                        set: { if !$0 { router.message = nil } })) {
                Button("OK", role: .cancel) {}
            }
    }

    private func handleImport(_ urls: [URL], kind: ImportKind) {
        switch kind {
        case .music:
            let lyricsOnly = urls.allSatisfy { $0.pathExtension.lowercased() == "lrc" }
            Task {
                let count = await library.importItems(urls)
                if lyricsOnly {
                    router.lyricsChanged()
                    router.message = "Lyrics files were matched to songs with the same file name."
                } else {
                    router.message = count == 0 ? "No audio files found." : "Imported \(count) song\(count == 1 ? "" : "s")."
                }
            }

        case .playlist:
            if let playlist = playlists.importM3U(urls[0], library: library) {
                router.message = "Imported “\(playlist.name)” with \(playlist.trackIDs.count) songs."
            } else {
                router.message = "None of the playlist's songs are in your library."
            }

        case let .lyrics(track):
            if library.importLyrics(from: urls[0], for: track) {
                Task { await LyricsService.shared.forget(cacheKey: track.id) }
                router.lyricsChanged()
            } else {
                router.message = "Couldn't read that lyrics file."
            }

        case let .artwork(target):
            let url = urls[0]
            Task {
                let scoped = url.startAccessingSecurityScopedResource()
                let data = try? Data(contentsOf: url)
                if scoped { url.stopAccessingSecurityScopedResource() }
                guard let data, await library.setCustomArtwork(data, for: target) else {
                    router.message = "That image couldn't be used."
                    return
                }
            }
        }
    }
}
