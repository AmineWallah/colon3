import Foundation
import ImageIO
import SoulseekKit
import UIKit

/// Finds and caches cover art. Order for library items:
/// 0. a cover the user picked in the app (kept in Application Support, files untouched)
/// 1. an image file next to the music (cover.jpg, folder.jpg, …)
/// 2. art embedded in the audio file (extracted once into the cache folder)
/// 3. an iTunes Search lookup, if enabled in Settings
actor ArtworkStore {
    static let shared = ArtworkStore()

    private let memory = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<URL?, Never>] = [:]
    private var folderImages: [String: URL?] = [:]
    private var missingEmbedded = Set<String>()

    nonisolated let directory: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    init() {
        memory.countLimit = 400
    }

    /// `maxPixel` is the longest edge in pixels; images are decoded at (roughly) that size.
    func image(for source: ArtworkSource, maxPixel: Int) async -> UIImage? {
        let bucket = [160, 320, 640, 1200].first { $0 >= maxPixel } ?? 1200
        let cacheKey = "\(source.key)@\(bucket)" as NSString
        if let cached = memory.object(forKey: cacheKey) { return cached }

        guard let file = await file(for: source) else { return nil }
        let image = await Task.detached(priority: .userInitiated) { Self.downsample(file, maxPixel: bucket) }.value
        if let image { memory.setObject(image, forKey: cacheKey) }
        return image
    }

    /// Raw image data at full size (Now Playing info, sharing).
    func file(for source: ArtworkSource) async -> URL? {
        let key = source.key
        if let task = inFlight[key] { return await task.value }
        let task = Task { await self.resolve(source) }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    /// Forget everything about this source (e.g. after a new cover was downloaded).
    func invalidate(_ source: ArtworkSource) {
        // NSCache can't enumerate keys; clear it wholesale, it refills quickly.
        memory.removeAllObjects()
        folderImages.removeAll()
        missingEmbedded.removeAll()
        let hash = MD5.hex(source.key)
        for prefix in ["emb-", "web-"] {
            for ext in ["img", "none"] {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(prefix)\(hash).\(ext)"))
            }
        }
    }

    /// Deletes extracted and downloaded covers (folder images next to the music are untouched).
    func clearDisk() {
        memory.removeAllObjects()
        folderImages.removeAll()
        missingEmbedded.removeAll()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    /// Re-check folders for cover files next time, without dropping decoded images.
    func forgetFolderListings() {
        folderImages.removeAll()
    }

    func invalidateFolders() {
        folderImages.removeAll()
        memory.removeAllObjects()
    }

    // MARK: Custom covers

    nonisolated static let overridesDirectory: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ArtworkOverrides", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    nonisolated static func overrideURL(for source: ArtworkSource) -> URL {
        overridesDirectory.appendingPathComponent(MD5.hex(source.key) + ".img")
    }

    nonisolated static func hasOverride(for source: ArtworkSource) -> Bool {
        FileManager.default.fileExists(atPath: overrideURL(for: source).path)
    }

    /// Saves picked image data as this album's or song's cover. Rejects anything ImageIO can't read.
    func setOverride(_ data: Data, for source: ArtworkSource) -> Bool {
        guard let image = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(image) > 0 else { return false }
        guard (try? data.write(to: Self.overrideURL(for: source), options: .atomic)) != nil else { return false }
        invalidate(source)
        return true
    }

    func removeOverride(for source: ArtworkSource) {
        try? FileManager.default.removeItem(at: Self.overrideURL(for: source))
        invalidate(source)
    }

    // MARK: Resolution

    private func resolve(_ source: ArtworkSource) async -> URL? {
        if case .remote = source {} else {
            let custom = Self.overrideURL(for: source)
            if FileManager.default.fileExists(atPath: custom.path) { return custom }
        }
        switch source {
        case let .album(album):
            if let local = folderImage(in: album.folder) { return local }
            for track in album.tracks where track.hasEmbeddedArt {
                if let embedded = await embedded(track, cacheKey: source.key) { return embedded }
            }
            return await online(query: "\(album.artist) \(album.title)", entity: "album", cacheKey: source.key)

        case let .track(track):
            if !isLibraryRoot(track.folder), let local = folderImage(in: track.folder) { return local }
            if track.hasEmbeddedArt, let embedded = await embedded(track, cacheKey: source.key) { return embedded }
            return await online(query: "\(track.artist) \(track.title)", entity: "song", cacheKey: source.key)

        case let .remote(query):
            return await online(query: query, entity: "album", cacheKey: source.key)
        }
    }

    private func isLibraryRoot(_ folder: URL) -> Bool {
        folder.lastPathComponent == "Music" && folder.deletingLastPathComponent().lastPathComponent == "Documents"
    }

    private func folderImage(in folder: URL) -> URL? {
        let key = folder.standardizedFileURL.path
        if let known = folderImages[key] { return known }
        let found = Self.findFolderImage(in: folder)
        folderImages[key] = found
        return found
    }

    nonisolated static func findFolderImage(in folder: URL) -> URL? {
        let keys: [URLResourceKey] = [.fileSizeKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                         options: [.skipsHiddenFiles]) else { return nil }
        let images = contents.filter { LibraryStore.imageExtensions.contains($0.pathExtension.lowercased()) }
        guard !images.isEmpty else { return nil }
        let preferred = ["cover", "folder", "front", "album", "artwork", "art"]
        for name in preferred {
            if let match = images.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased() == name }) {
                return match
            }
        }
        for name in preferred {
            if let match = images.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased().contains(name) }) {
                return match
            }
        }
        // Otherwise the biggest image, which is usually the front cover rather than a scan of the disc.
        func size(_ url: URL) -> Int {
            let values = try? url.resourceValues(forKeys: Set(keys))
            return values?.fileSize ?? 0
        }
        return images.max { size($0) < size($1) }
    }

    private func embedded(_ track: Track, cacheKey: String) async -> URL? {
        let file = directory.appendingPathComponent("emb-\(MD5.hex(cacheKey)).img")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        guard !missingEmbedded.contains(track.id) else { return nil }
        guard let data = await MetadataReader.embeddedArtwork(url: track.url),
              (try? data.write(to: file, options: .atomic)) != nil else {
            missingEmbedded.insert(track.id)
            return nil
        }
        return file
    }

    private func online(query: String, entity: String, cacheKey: String) async -> URL? {
        let hash = MD5.hex(cacheKey)
        let file = directory.appendingPathComponent("web-\(hash).img")
        let miss = directory.appendingPathComponent("web-\(hash).none")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        guard AppSettings.artworkLookupEnabled else { return nil }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: miss.path),
           let date = attributes[.modificationDate] as? Date, Date().timeIntervalSince(date) < 7 * 86_400 {
            return nil
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3, trimmed.lowercased() != "unknown artist unknown album" else { return nil }

        switch await CoverLookup.shared.artwork(query: trimmed, entity: entity) {
        case let .found(data):
            return (try? data.write(to: file, options: .atomic)) != nil ? file : nil
        case .notFound:
            FileManager.default.createFile(atPath: miss.path, contents: nil)
            return nil
        case .failed:
            return nil  // Network trouble: try again next time
        }
    }

    nonisolated static func downsample(_ url: URL, maxPixel: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// iTunes Search API lookups, spaced out to stay under its rate limit (~20 requests/minute).
actor CoverLookup {
    static let shared = CoverLookup()

    enum Outcome {
        case found(Data)
        case notFound
        case failed
    }

    private var lastRequest = Date.distantPast
    private let spacing: TimeInterval = 3

    func artwork(query: String, entity: String) async -> Outcome {
        let wait = spacing - Date().timeIntervalSince(lastRequest)
        lastRequest = Date().addingTimeInterval(max(wait, 0))
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }

        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "entity", value: entity),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "limit", value: "3"),
        ]
        guard let url = components.url else { return .failed }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return .failed }
            let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
            guard let small = decoded.results.first(where: { $0.artworkUrl100 != nil })?.artworkUrl100 else {
                return .notFound
            }
            let large = small.replacingOccurrences(of: "100x100bb", with: "1000x1000bb")
            guard let imageURL = URL(string: large) else { return .notFound }
            let (imageData, imageResponse) = try await URLSession.shared.data(from: imageURL)
            guard (imageResponse as? HTTPURLResponse)?.statusCode == 200, !imageData.isEmpty else { return .failed }
            return .found(imageData)
        } catch {
            return .failed
        }
    }

    private struct SearchResponse: Decodable {
        struct Result: Decodable {
            let artworkUrl100: String?
        }
        let results: [Result]
    }

    /// Turns a Soulseek folder path into an "artist album" search: drops format tags, years and
    /// bracketed junk, and uses the parent folder as the artist when the album folder lacks one.
    static func query(forFolderPath path: String) -> String {
        var parts = path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).map(String.init)
        guard !parts.isEmpty else { return "" }
        // "…\Album\CD1" → use the album folder.
        if let last = parts.last, last.range(of: #"^(cd|disc|disk)\s*\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil,
           parts.count > 1 {
            parts.removeLast()
        }
        let album = clean(parts[parts.count - 1])
        if album.contains(" - ") || parts.count < 2 { return album.replacingOccurrences(of: " - ", with: " ") }
        let generic: Set<String> = ["music", "musique", "downloads", "complete", "shared", "soulseek", "albums", "mp3", "flac", "audio"]
        let parent = clean(parts[parts.count - 2])
        if generic.contains(parent.lowercased()) || parent.isEmpty { return album }
        return "\(parent) \(album)"
    }

    static func clean(_ name: String) -> String {
        var text = name.replacingOccurrences(of: "_", with: " ")
        let patterns = [
            #"\[[^\]]*\]"#, #"\([^)]*\)"#, #"\{[^}]*\}"#,
            #"(?i)\b(flac|mp3|aac|alac|ogg|opus|wav|320|256|192|v0|v2|vbr|cbr|web|cd|vinyl|lossless|hi-?res|24bit|16bit|24-\d+|16-44|kbps|remaster(ed)?|deluxe edition)\b"#,
            #"\b(19|20)\d{2}\b"#,
        ]
        for pattern in patterns {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: CharacterSet(charactersIn: " -.–"))
    }
}
