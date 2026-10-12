import AVFoundation
import Foundation
import SoulseekKit

struct Album: Identifiable {
    var id: String { name }
    let name: String
    let tracks: [Track]
}

struct Track: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let relativePath: String
    var title: String
    var artist: String
    var album: String
    var duration: Double
}

/// Everything under Documents/Music. The folder is visible in the Files app, so you can also
/// drop music in by hand.
final class Library: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var isScanning = false

    let root: URL
    var onSharesChanged: (([LocalShare]) -> Void)?

    private var cache: [URL: Track] = [:]
    private var rescanQueued = false

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = documents.appendingPathComponent("Music", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Albums in display order, tracks sorted by filename (which usually starts with the track number).
    var albums: [Album] {
        let grouped = Dictionary(grouping: tracks, by: \.album)
        return grouped.keys
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { key in
                Album(name: key, tracks: (grouped[key] ?? []).sorted {
                    $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
                })
            }
    }

    func rescan() {
        guard !isScanning else {
            rescanQueued = true
            return
        }
        isScanning = true
        let root = self.root
        let known = cache

        Task.detached(priority: .utility) {
            let scan = await Library.scan(root: root, known: known)
            await MainActor.run { self.apply(tracks: scan.tracks, shares: scan.shares) }
        }
    }

    private func apply(tracks: [Track], shares: [LocalShare]) {
        self.tracks = tracks
        cache = Dictionary(tracks.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        isScanning = false
        onSharesChanged?(shares)
        if rescanQueued {
            rescanQueued = false
            rescan()
        }
    }

    private static func scan(root: URL, known: [URL: Track]) async -> (tracks: [Track], shares: [LocalShare]) {
        var tracks: [Track] = []
        var shares: [LocalShare] = []
        for (url, relative, size) in audioFiles(in: root) {
            if let cached = known[url] {
                tracks.append(cached)
            } else {
                let track = await loadTrack(url: url, relativePath: relative)
                tracks.append(track)
            }
            let virtualPath = (["colon3"] + relative.split(separator: "/").map(String.init)).joined(separator: "\\")
            shares.append(LocalShare(virtualPath: virtualPath, url: url, size: size))
        }
        return (tracks, shares)
    }

    func delete(_ track: Track) {
        try? FileManager.default.removeItem(at: track.url)
        let folder = track.url.deletingLastPathComponent()
        if folder != root,
           let contents = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
           contents.filter({ !$0.hasPrefix(".") }).isEmpty {
            try? FileManager.default.removeItem(at: folder)
        }
        rescan()
    }

    private static func audioFiles(in root: URL) -> [(URL, String, UInt64)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles]) else { return [] }
        let rootPath = root.standardizedFileURL.path
        var found: [(URL, String, UInt64)] = []
        for case let url as URL in enumerator {
            guard AppModel.playableExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            let fullPath = url.standardizedFileURL.path
            var relative = fullPath.hasPrefix(rootPath) ? String(fullPath.dropFirst(rootPath.count)) : url.lastPathComponent
            if relative.hasPrefix("/") { relative.removeFirst() }
            found.append((url, relative, UInt64(values.fileSize ?? 0)))
        }
        return found
    }

    private static func loadTrack(url: URL, relativePath: String) async -> Track {
        let folderName = url.deletingLastPathComponent().lastPathComponent
        var track = Track(url: url, relativePath: relativePath,
                          title: url.deletingPathExtension().lastPathComponent,
                          artist: "Unknown Artist",
                          album: folderName == "Music" ? "Singles" : folderName,
                          duration: 0)

        let asset = AVURLAsset(url: url)
        if let duration = try? await asset.load(.duration), duration.isNumeric {
            track.duration = duration.seconds
        }
        guard let metadata = try? await asset.load(.commonMetadata) else { return track }
        for item in metadata {
            guard let key = item.commonKey, let value = try? await item.load(.stringValue), !value.isEmpty else { continue }
            switch key {
            case .commonKeyTitle: track.title = value
            case .commonKeyArtist: track.artist = value
            case .commonKeyAlbumName: track.album = value
            default: break
            }
        }
        return track
    }

    static func artwork(for url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.commonMetadata) else { return nil }
        for item in metadata where item.commonKey == .commonKeyArtwork {
            if let data = try? await item.load(.dataValue) { return data }
        }
        return nil
    }
}
