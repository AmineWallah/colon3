import Foundation
import SoulseekKit
import UniformTypeIdentifiers

/// Everything under Documents/Music. The folder is visible in the Files app, so music can also
/// be dropped in by hand; downloads and imports land there too.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var albums: [Album] = []
    @Published private(set) var items: [LibraryItem] = []
    @Published private(set) var artists: [ArtistEntry] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isImporting = false
    /// Bumped when cover art may have changed, so artwork views reload.
    @Published private(set) var artworkRevision = 0

    let root: URL
    var onSharesChanged: (([LocalShare]) -> Void)?

    private var cache: [String: CachedEntry] = [:]
    private var rescanQueued = false
    private var albumByTrack: [String: Album] = [:]
    private var tracksByID: [String: Track] = [:]
    private var albumsByID: [String: Album] = [:]

    nonisolated private static var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("library-cache.json")
    }

    nonisolated static let audioExtensions: Set<String> = ["mp3", "m4a", "m4b", "mp4", "aac", "alac", "flac", "wav", "aif", "aiff", "caf"]
    nonisolated static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "heic"]

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = documents.appendingPathComponent("Music", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: Self.cacheURL),
           let decoded = try? JSONDecoder().decode([String: CachedEntry].self, from: data) {
            cache = decoded
        }
    }

    func bumpArtwork() { artworkRevision += 1 }

    // MARK: Lookup

    func track(id: String) -> Track? { tracksByID[id] }
    func album(id: String) -> Album? { albumsByID[id] }
    func album(containing track: Track) -> Album? { albumByTrack[track.id] }

    func artist(named name: String) -> ArtistEntry? { artists.first { $0.name == name } }

    /// Best artwork for a track: its album's when it has one, so covers stay consistent.
    func artwork(for track: Track) -> ArtworkSource {
        albumByTrack[track.id].map { .album($0) } ?? .track(track)
    }

    // MARK: Scanning

    func rescan() {
        guard !isScanning else {
            rescanQueued = true
            return
        }
        isScanning = true
        let root = self.root
        let known = cache

        Task.detached(priority: .utility) {
            let result = await Self.scan(root: root, cache: known)
            await MainActor.run { self.apply(result) }
        }
    }

    private func apply(_ result: ScanResult) {
        cache = result.cache
        let grouped = Self.group(result.tracks, root: root)
        tracks = result.tracks
        albums = grouped.albums
        items = grouped.items
        artists = grouped.artists
        tracksByID = Dictionary(result.tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        albumsByID = Dictionary(grouped.albums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var byTrack: [String: Album] = [:]
        for album in grouped.albums {
            for track in album.tracks { byTrack[track.id] = album }
        }
        albumByTrack = byTrack
        isScanning = false
        onSharesChanged?(result.shares)
        // New folders may have brought cover files; let artwork views look again.
        Task {
            await ArtworkStore.shared.forgetFolderListings()
            self.artworkRevision += 1
        }

        let snapshot = result.cache
        Task.detached(priority: .background) {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: Self.cacheURL, options: .atomic)
            }
        }

        if rescanQueued {
            rescanQueued = false
            rescan()
        }
    }

    private struct ScanResult: Sendable {
        let tracks: [Track]
        let shares: [LocalShare]
        let cache: [String: CachedEntry]
    }

    private nonisolated static func scan(root: URL, cache: [String: CachedEntry]) async -> ScanResult {
        let files = audioFiles(in: root)
        var newCache: [String: CachedEntry] = [:]
        var tracks: [Track] = []
        var shares: [LocalShare] = []

        // Read new files a few at a time; cached ones are free.
        var pending: [(FileEntry, Int)] = []
        var infos = [TrackInfo?](repeating: nil, count: files.count)
        for (index, file) in files.enumerated() {
            if let cached = cache[file.relativePath], cached.size == file.size, cached.modified == file.modified {
                infos[index] = cached.info
            } else {
                pending.append((file, index))
            }
        }
        for chunkStart in stride(from: 0, to: pending.count, by: 4) {
            let chunk = pending[chunkStart..<min(chunkStart + 4, pending.count)]
            await withTaskGroup(of: (Int, TrackInfo).self) { group in
                for (file, index) in chunk {
                    group.addTask {
                        let info = await MetadataReader.read(url: file.url)
                        return (index, info)
                    }
                }
                for await (index, info) in group { infos[index] = info }
            }
        }

        for (index, file) in files.enumerated() {
            let info = infos[index] ?? TrackInfo()
            newCache[file.relativePath] = CachedEntry(size: file.size, modified: file.modified, info: info)
            let fallbackTitle = file.url.deletingPathExtension().lastPathComponent
            tracks.append(Track(
                id: file.relativePath,
                url: file.url,
                title: info.title ?? fallbackTitle,
                artist: info.artist ?? info.albumArtist ?? "Unknown Artist",
                albumArtist: info.albumArtist,
                album: info.album,
                trackNumber: info.trackNumber,
                discNumber: info.discNumber,
                year: info.year,
                duration: info.duration,
                addedAt: Date(timeIntervalSince1970: file.modified),
                isSpatial: info.isSpatial,
                hasEmbeddedArt: info.hasEmbeddedArt))
            let virtualPath = (["colon3"] + file.relativePath.split(separator: "/").map(String.init)).joined(separator: "\\")
            shares.append(LocalShare(virtualPath: virtualPath, url: file.url, size: UInt64(max(file.size, 0))))
        }
        return ScanResult(tracks: tracks, shares: shares, cache: newCache)
    }

    private struct FileEntry: Sendable {
        let url: URL
        let relativePath: String
        let size: Int64
        let modified: Double
    }

    private nonisolated static func audioFiles(in root: URL) -> [FileEntry] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles]) else { return [] }
        let rootPath = root.standardizedFileURL.path
        var found: [FileEntry] = []
        for case let url as URL in enumerator {
            guard audioExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            let fullPath = url.standardizedFileURL.path
            var relative = fullPath.hasPrefix(rootPath) ? String(fullPath.dropFirst(rootPath.count)) : url.lastPathComponent
            if relative.hasPrefix("/") { relative.removeFirst() }
            found.append(FileEntry(url: url, relativePath: relative, size: Int64(values.fileSize ?? 0),
                                   modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0))
        }
        return found
    }

    // MARK: Grouping

    private nonisolated static func group(_ tracks: [Track], root: URL) -> (albums: [Album], items: [LibraryItem], artists: [ArtistEntry]) {
        let rootPath = root.standardizedFileURL.path
        let audioPerFolder = Dictionary(grouping: tracks, by: { $0.folder.standardizedFileURL.path }).mapValues(\.count)

        var albumTracks: [String: [Track]] = [:]
        var albumTitles: [String: String] = [:]
        var singles: [Track] = []

        for track in tracks {
            let folderPath = track.folder.standardizedFileURL.path
            if let album = track.album?.trimmingCharacters(in: .whitespaces), !album.isEmpty {
                let owner = (track.albumArtist?.lowercased()).map { "artist:" + $0 } ?? "folder:" + folderPath
                let key = owner + "|" + album.lowercased()
                albumTracks[key, default: []].append(track)
                albumTitles[key] = album
            } else if folderPath != rootPath, (audioPerFolder[folderPath] ?? 0) >= 2 {
                let key = "folder:" + folderPath
                albumTracks[key, default: []].append(track)
                albumTitles[key] = track.folder.lastPathComponent
            } else {
                singles.append(track)
            }
        }

        var albums: [Album] = []
        for (key, members) in albumTracks {
            let sorted = members.sorted { lhs, rhs in
                if (lhs.discNumber ?? 1) != (rhs.discNumber ?? 1) { return (lhs.discNumber ?? 1) < (rhs.discNumber ?? 1) }
                if let left = lhs.trackNumber, let right = rhs.trackNumber, left != right { return left < right }
                return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
            }
            let artists = Set(sorted.map(\.artist))
            let artist = sorted.compactMap(\.albumArtist).first
                ?? (artists.count == 1 ? sorted[0].artist : "Various Artists")
            albums.append(Album(
                id: MD5.hex(key),
                title: albumTitles[key] ?? "Unknown Album",
                artist: artist,
                year: sorted.compactMap(\.year).first,
                tracks: sorted,
                folder: sorted[0].folder,
                addedAt: sorted.map(\.addedAt).max() ?? .distantPast))
        }
        albums.sort { SortKey.less($0.title, $1.title) }

        let items = albums.map(LibraryItem.album) + singles.map(LibraryItem.single)

        var artistAlbums: [String: [Album]] = [:]
        var artistSingles: [String: [Track]] = [:]
        for album in albums { artistAlbums[album.artist, default: []].append(album) }
        for single in singles { artistSingles[single.artist, default: []].append(single) }
        let names = Set(artistAlbums.keys).union(artistSingles.keys)
        let artists = names.sorted(by: SortKey.less).map { name in
            ArtistEntry(name: name,
                        albums: (artistAlbums[name] ?? []).sorted { ($0.year ?? 0, $0.title) > ($1.year ?? 0, $1.title) },
                        singles: (artistSingles[name] ?? []).sorted { SortKey.less($0.title, $1.title) })
        }
        return (albums, items, artists)
    }

    // MARK: Changes

    func delete(_ doomed: [Track]) {
        let fileManager = FileManager.default
        var folders = Set<URL>()
        for track in doomed {
            try? fileManager.removeItem(at: track.url)
            folders.insert(track.folder)
        }
        // Drop folders that no longer hold any audio (leftover covers included).
        for folder in folders where folder.standardizedFileURL != root.standardizedFileURL {
            let contents = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            let hasAudio = contents.contains { Self.audioExtensions.contains($0.pathExtension.lowercased()) }
            let hasSubfolders = contents.contains { $0.hasDirectoryPath }
            if !hasAudio, !hasSubfolders { try? fileManager.removeItem(at: folder) }
        }
        rescan()
    }

    /// Copies audio files (or whole folders, covers included) into the library. Returns how many
    /// audio files were added.
    func importItems(_ urls: [URL]) async -> Int {
        isImporting = true
        defer { isImporting = false }
        let root = self.root
        let added = await Task.detached(priority: .userInitiated) { () -> Int in
            var count = 0
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                count += Self.copyIntoLibrary(url, root: root)
            }
            return count
        }.value
        rescan()
        return added
    }

    private nonisolated static func copyIntoLibrary(_ url: URL, root: URL) -> Int {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }

        if isDirectory.boolValue {
            let destinationFolder = uniqueURL(root.appendingPathComponent(url.lastPathComponent, isDirectory: true))
            var count = 0
            guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles]) else { return 0 }
            let sourcePath = url.resolvingSymlinksInPath().path
            for case let file as URL in enumerator {
                let ext = file.pathExtension.lowercased()
                let isAudio = audioExtensions.contains(ext)
                guard isAudio || imageExtensions.contains(ext) else { continue }
                let filePath = file.resolvingSymlinksInPath().path
                guard filePath.hasPrefix(sourcePath) else { continue }
                let relative = String(filePath.dropFirst(sourcePath.count))
                let destination = destinationFolder.appendingPathComponent(relative)
                try? fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if (try? fileManager.copyItem(at: file, to: destination)) != nil, isAudio { count += 1 }
            }
            return count
        }

        guard audioExtensions.contains(url.pathExtension.lowercased()) else { return 0 }
        let folder = root.appendingPathComponent("Imported", isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = uniqueURL(folder.appendingPathComponent(url.lastPathComponent))
        return (try? fileManager.copyItem(at: url, to: destination)) != nil ? 1 : 0
    }

    private nonisolated static func uniqueURL(_ url: URL) -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let folder = url.deletingLastPathComponent()
        var counter = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            let candidate = folder.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }

    static let importableTypes: [UTType] = [.audio, .mp3, .mpeg4Audio, .wav, .aiff, .folder]
        + [UTType(filenameExtension: "flac")].compactMap { $0 }
}

struct CachedEntry: Codable, Sendable {
    let size: Int64
    let modified: Double
    let info: TrackInfo
}
