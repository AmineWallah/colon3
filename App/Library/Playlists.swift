import Foundation

struct Playlist: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    /// Track ids (paths relative to the Music folder), in playlist order. Duplicates are allowed.
    var trackIDs: [String]
    var created: Date
    var modified: Date
}

/// User playlists, saved as JSON in Application Support.
@MainActor
final class PlaylistStore: ObservableObject {
    @Published private(set) var playlists: [Playlist] = []

    private let fileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("playlists.json")

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Playlist].self, from: data) {
            playlists = decoded
        }
    }

    func playlist(id: UUID) -> Playlist? { playlists.first { $0.id == id } }

    /// Tracks that still exist in the library, in order.
    func tracks(of playlist: Playlist, in library: LibraryStore) -> [Track] {
        playlist.trackIDs.compactMap { library.track(id: $0) }
    }

    @discardableResult
    func create(named name: String, with tracks: [Track] = []) -> Playlist {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        let playlist = Playlist(id: UUID(), name: trimmed.isEmpty ? "New Playlist" : trimmed,
                                trackIDs: tracks.map(\.id), created: now, modified: now)
        playlists.insert(playlist, at: 0)
        save()
        return playlist
    }

    func rename(_ playlist: Playlist, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        edit(playlist) { $0.name = trimmed }
    }

    func delete(_ playlist: Playlist) {
        playlists.removeAll { $0.id == playlist.id }
        save()
    }

    /// Returns how many were added; songs already in the playlist are skipped.
    @discardableResult
    func add(_ tracks: [Track], to playlist: Playlist) -> Int {
        var added = 0
        edit(playlist) { list in
            var present = Set(list.trackIDs)
            for track in tracks where !present.contains(track.id) {
                list.trackIDs.append(track.id)
                present.insert(track.id)
                added += 1
            }
        }
        return added
    }

    /// Replaces the whole song list (the playlist importer fills its playlist this way, in the
    /// source's order). Does nothing if the playlist was deleted.
    func setTrackIDs(_ ids: [String], for playlistID: UUID) {
        guard let playlist = playlist(id: playlistID), playlist.trackIDs != ids else { return }
        edit(playlist) { $0.trackIDs = ids }
    }

    /// Songs autoplay downloaded go into one playlist, so they're easy to find, keep or delete.
    func addToAutoplayDiscoveries(_ track: Track) {
        let key = "autoplay.discoveriesPlaylist"
        let existing = UserDefaults.standard.string(forKey: key).flatMap(UUID.init(uuidString:)).flatMap { playlist(id: $0) }
        let target = existing ?? create(named: "Found by Autoplay")
        if existing == nil { UserDefaults.standard.set(target.id.uuidString, forKey: key) }
        add([track], to: target)
    }

    /// Offsets refer to the resolved (existing) track list shown on screen.
    func remove(at offsets: IndexSet, from playlist: Playlist, library: LibraryStore) {
        let visible = visibleIndices(of: playlist, library: library)
        let doomed = IndexSet(offsets.compactMap { visible.indices.contains($0) ? visible[$0] : nil })
        edit(playlist) { $0.trackIDs.remove(atOffsets: doomed) }
    }

    func move(from offsets: IndexSet, to destination: Int, in playlist: Playlist, library: LibraryStore) {
        // Work on the visible list, then put songs that are missing from the library back at the end.
        let visible = visibleIndices(of: playlist, library: library)
        edit(playlist) { list in
            var shown = visible.map { list.trackIDs[$0] }
            shown.move(fromOffsets: offsets, toOffset: destination)
            let hidden = list.trackIDs.indices.filter { !visible.contains($0) }.map { list.trackIDs[$0] }
            list.trackIDs = shown + hidden
        }
    }

    /// Deleted songs leave every playlist, like they leave favourites.
    func forget(_ tracks: [Track]) {
        let doomed = Set(tracks.map(\.id))
        var changed = false
        for index in playlists.indices where playlists[index].trackIDs.contains(where: doomed.contains) {
            playlists[index].trackIDs.removeAll { doomed.contains($0) }
            changed = true
        }
        if changed { save() }
    }

    /// An .m3u8 file other players can read, with paths relative to the Music folder.
    func exportM3U(_ playlist: Playlist, library: LibraryStore) -> URL? {
        var lines = ["#EXTM3U", "#PLAYLIST:\(playlist.name)"]
        for track in tracks(of: playlist, in: library) {
            lines.append("#EXTINF:\(Int(track.duration.rounded())),\(track.artist) - \(track.title)")
            lines.append(track.id)
        }
        let safeName = playlist.name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safeName + ".m3u8")
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    /// Reads an .m3u/.m3u8 and matches entries to library songs by relative path or file name.
    func importM3U(_ url: URL, library: LibraryStore) -> Playlist? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let text = (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else { return nil }
        var name = url.deletingPathExtension().lastPathComponent
        var byName: [String: Track] = [:]
        for track in library.tracks { byName[track.url.lastPathComponent.lowercased()] = track }
        var found: [Track] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#PLAYLIST:") { name = String(line.dropFirst(10)); continue }
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let path = line.replacingOccurrences(of: "\\", with: "/")
            if let track = library.track(id: path) {
                found.append(track)
            } else if let file = path.split(separator: "/").last, let track = byName[String(file).lowercased()] {
                found.append(track)
            }
        }
        guard !found.isEmpty else { return nil }
        return create(named: name, with: found)
    }

    private func visibleIndices(of playlist: Playlist, library: LibraryStore) -> [Int] {
        guard let current = self.playlist(id: playlist.id) else { return [] }
        return current.trackIDs.indices.filter { library.track(id: current.trackIDs[$0]) != nil }
    }

    private func edit(_ playlist: Playlist, _ change: (inout Playlist) -> Void) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        change(&playlists[index])
        playlists[index].modified = Date()
        save()
    }

    private func save() {
        let snapshot = playlists
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
