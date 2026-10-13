import Foundation
import SoulseekKit

struct LyricLine: Identifiable, Hashable {
    let id: Int
    let time: Double
    let text: String
}

enum Lyrics: Equatable {
    case synced([LyricLine])
    case plain([String])
    case instrumental
    case notFound
}

/// Where the lyrics on screen came from.
enum LyricsOrigin {
    case file, lrclib
}

/// Lyrics from a .lrc file next to the song if there is one, otherwise LRCLIB (lrclib.net):
/// free, no API key, mostly time-synced. LRCLIB answers are cached on disk.
actor LyricsService {
    static let shared = LyricsService()

    private struct Entry: Codable {
        var syncedLyrics: String?
        var plainLyrics: String?
        var instrumental: Bool?
        var duration: Double?
    }

    private struct Stored: Codable {
        var entry: Entry?
        var fetched: Date
    }

    private let directory: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// A sidecar .lrc (or plain text saved as .lrc) next to the song.
    nonisolated static func localLyrics(at url: URL) -> Lyrics? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        let synced = parseLRC(text)
        if !synced.isEmpty { return .synced(synced) }
        // No timestamps: show it as plain text, minus LRC tags like [ar:…].
        let lines = text.components(separatedBy: .newlines)
            .filter { !($0.hasPrefix("[") && $0.hasSuffix("]")) }
        let trimmed = lines.drop(while: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
        return trimmed.isEmpty ? nil : .plain(Array(trimmed))
    }

    /// nil means the lookup failed (offline, server error), so the caller can offer a retry.
    func lyrics(title: String, artist: String, album: String?, duration: Double, cacheKey: String) async -> Lyrics? {
        let file = directory.appendingPathComponent(MD5.hex(cacheKey) + ".json")
        if let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            // Misses are retried after a few days in case someone has added the song since.
            if stored.entry != nil || Date().timeIntervalSince(stored.fetched) < 3 * 86_400 {
                return Self.lyrics(from: stored.entry)
            }
        }
        guard AppSettings.lyricsLookupEnabled else { return .notFound }

        let entry: Entry?
        do {
            entry = try await fetch(title: title, artist: artist, album: album, duration: duration)
        } catch {
            return nil
        }
        if let data = try? JSONEncoder().encode(Stored(entry: entry, fetched: Date())) {
            try? data.write(to: file, options: .atomic)
        }
        return Self.lyrics(from: entry)
    }

    func forget(cacheKey: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(MD5.hex(cacheKey) + ".json"))
    }

    private func fetch(title: String, artist: String, album: String?, duration: Double) async throws -> Entry? {
        if let album, duration > 0 {
            var components = URLComponents(string: "https://lrclib.net/api/get")!
            components.queryItems = [
                URLQueryItem(name: "track_name", value: title),
                URLQueryItem(name: "artist_name", value: artist),
                URLQueryItem(name: "album_name", value: album),
                URLQueryItem(name: "duration", value: String(Int(duration.rounded()))),
            ]
            let (data, status) = try await get(components.url!)
            if status == 200, let entry = try? JSONDecoder().decode(Entry.self, from: data) { return entry }
            if status != 404 && status != 400 { throw URLError(.badServerResponse) }
        }

        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        let (data, status) = try await get(components.url!)
        guard status == 200 else { throw URLError(.badServerResponse) }
        let results = (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
        let close = results.filter { entry in
            guard duration > 0, let other = entry.duration else { return true }
            return abs(other - duration) <= 5
        }
        return close.first(where: { $0.syncedLyrics?.isEmpty == false })
            ?? close.first(where: { $0.plainLyrics?.isEmpty == false || $0.instrumental == true })
    }

    private func get(_ url: URL) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.setValue(HTTP.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private static func lyrics(from entry: Entry?) -> Lyrics {
        guard let entry else { return .notFound }
        if let synced = entry.syncedLyrics, !synced.isEmpty {
            let lines = parseLRC(synced)
            if !lines.isEmpty { return .synced(lines) }
        }
        if let plain = entry.plainLyrics, !plain.isEmpty {
            return .plain(plain.components(separatedBy: .newlines))
        }
        return entry.instrumental == true ? .instrumental : .notFound
    }

    /// "[01:23.45] text" lines; a line may carry several timestamps.
    static func parseLRC(_ text: String) -> [LyricLine] {
        let regex = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]"#)
        var lines: [(Double, String)] = []
        for raw in text.components(separatedBy: .newlines) {
            let range = NSRange(raw.startIndex..., in: raw)
            let matches = regex.matches(in: raw, range: range)
            guard let last = matches.last, let textRange = Range(NSRange(location: last.range.upperBound,
                                                                         length: range.upperBound - last.range.upperBound), in: raw)
            else { continue }
            let words = raw[textRange].trimmingCharacters(in: .whitespaces)
            for match in matches {
                guard let minutes = Range(match.range(at: 1), in: raw).flatMap({ Double(raw[$0]) }),
                      let secondsText = Range(match.range(at: 2), in: raw).map({ raw[$0].replacingOccurrences(of: ":", with: ".") }),
                      let seconds = Double(secondsText) else { continue }
                lines.append((minutes * 60 + seconds, words.isEmpty ? "♪" : words))
            }
        }
        return lines.sorted { $0.0 < $1.0 }.enumerated().map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }
}
