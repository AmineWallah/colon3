import Foundation

/// Reads a public or unlisted YouTube / YouTube Music playlist from its link, without an API
/// key or sign-in: the youtube.com playlist page carries the first 100 songs, and the rest load
/// through the same internal "browse" call the website makes when you scroll.
///
/// This isn't an official API. YouTube changes the page from time to time (in 2026 the items
/// moved from `playlistVideoRenderer` to `lockupViewModel`), so both shapes are read, every
/// continuation token found is tried, and the error says when nothing could be read.
enum YouTubePlaylistReader {
    struct Playlist {
        let title: String
        let songs: [WantedSong]
    }

    enum ReadError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self {
            case let .message(text): return text
            }
        }
    }

    /// The playlist ID in a youtube.com / music.youtube.com link, or a bare ID.
    static func playlistID(fromLink text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: trimmed), components.host != nil {
            if let list = components.queryItems?.first(where: { $0.name == "list" })?.value, !list.isEmpty {
                return list
            }
            // music.youtube.com/browse/VLPL… is a playlist page.
            let last = components.path.split(separator: "/").last.map(String.init) ?? ""
            if components.path.contains("/browse/"), last.hasPrefix("VL"), last.count > 2 { return String(last.dropFirst(2)) }
            return nil
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard trimmed.count >= 10, trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return trimmed
    }

    /// `progress` gets the number of songs read so far after each page.
    static func read(playlistID id: String, progress: @escaping @MainActor (Int) -> Void) async throws -> Playlist {
        if id == "LM" || id == "LL" || id == "WL" {
            throw ReadError.message("Liked Music and Watch Later are private, so they can't be read from a link. Add the songs to a playlist, set it to Unlisted, and paste that link instead.")
        }
        if id.hasPrefix("RD") && !id.hasPrefix("RDCLAK") {
            throw ReadError.message("That's a mix YouTube makes up as you listen, not a playlist. Save it as a playlist first.")
        }

        var components = URLComponents(string: "https://www.youtube.com/playlist")!
        components.queryItems = [URLQueryItem(name: "list", value: id), URLQueryItem(name: "hl", value: "en")]
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        applyBrowserHeaders(&request)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ReadError.message("YouTube answered \(status).") }
        let html = String(decoding: data, as: UTF8.self)
        guard let initial = embeddedJSON(after: "ytInitialData", in: data) else {
            throw ReadError.message("Couldn't read YouTube's playlist page. YouTube may have changed it; colon3 needs an update.")
        }

        var collector = Collector()
        collector.walk(initial)
        let title = collector.playlistTitle ?? "YouTube Playlist"
        if collector.items.isEmpty {
            throw ReadError.message(collector.alert ?? "No songs found. The playlist may be private (set it to Unlisted or Public), empty, or deleted.")
        }
        await progress(collector.items.count)

        let clientVersion = firstMatch(#""INNERTUBE_CLIENT_VERSION":"([^"]+)""#, in: html) ?? "2.20261001.00.00"
        let apiKey = firstMatch(#""INNERTUBE_API_KEY":"([^"]+)""#, in: html)

        // Page through the rest. Each response carries the next token; when there are several,
        // the one that actually returns new songs wins.
        var tokens = collector.tokens
        var pages = 0
        while !tokens.isEmpty, pages < 100, !Task.isCancelled {
            pages += 1
            var advanced = false
            for token in tokens {
                let page = try await continuation(token: token, clientVersion: clientVersion, apiKey: apiKey)
                var next = Collector(seen: collector.seen)
                next.walk(page)
                guard !next.items.isEmpty else { continue }
                collector.items += next.items
                collector.seen = next.seen
                tokens = next.tokens
                advanced = true
                await progress(collector.items.count)
                break
            }
            if !advanced { break }
        }

        let songs = collector.items.compactMap { item -> WantedSong? in
            let isTopicTrack = item.channel.hasSuffix(" - Topic")
            // Only YouTube Music tracks have the song's own length; videos have intros and outros.
            return song(title: item.title, owner: item.channel, duration: isTopicTrack ? item.duration : nil)
        }
        return Playlist(title: title, songs: songs)
    }

    // MARK: Network

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    private static func applyBrowserHeaders(_ request: inout URLRequest) {
        // Desktop Safari: a phone user agent gets redirected to m.youtube.com, a different page.
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        // Skips the EU cookie-consent page, which would come back instead of the playlist.
        request.setValue("SOCS=CAI; CONSENT=YES+1", forHTTPHeaderField: "Cookie")
    }

    private static func continuation(token: String, clientVersion: String, apiKey: String?) async throws -> Any {
        var address = "https://www.youtube.com/youtubei/v1/browse?prettyPrint=false"
        if let apiKey { address += "&key=" + apiKey }
        var request = URLRequest(url: URL(string: address)!, timeoutInterval: 20)
        request.httpMethod = "POST"
        applyBrowserHeaders(&request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "context": ["client": ["clientName": "WEB", "clientVersion": clientVersion, "hl": "en", "gl": "US"]],
            "continuation": token,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ReadError.message("YouTube answered \(status) while loading more songs.") }
        return try JSONSerialization.jsonObject(with: data)
    }

    // MARK: Parsing

    struct Item {
        let videoID: String
        let title: String
        let channel: String
        let duration: Double?
    }

    /// Walks YouTube's JSON in document order, picking up playlist items in either layout,
    /// continuation tokens, the playlist's title and any "this playlist is private" alert.
    struct Collector {
        var items: [Item] = []
        var tokens: [String] = []
        var playlistTitle: String?
        var alert: String?
        var seen = Set<String>()

        init(seen: Set<String> = []) {
            self.seen = seen
        }

        mutating func walk(_ node: Any) {
            if let array = node as? [Any] {
                for element in array { walk(element) }
                return
            }
            guard let dictionary = node as? [String: Any] else { return }

            if let renderer = dictionary["playlistVideoRenderer"] as? [String: Any] {
                addOld(renderer)
                return
            }
            if let lockup = dictionary["lockupViewModel"] as? [String: Any] {
                addLockup(lockup)
                return
            }
            if let renderer = dictionary["continuationItemRenderer"] as? [String: Any] {
                let command = (renderer["continuationEndpoint"] as? [String: Any])?["continuationCommand"] as? [String: Any]
                if let token = command?["token"] as? String { addToken(token) }
                return
            }
            if let model = dictionary["continuationItemViewModel"] as? [String: Any] {
                let inner = ((model["continuationCommand"] as? [String: Any])?["innertubeCommand"] as? [String: Any])?["continuationCommand"] as? [String: Any]
                let direct = model["continuationCommand"] as? [String: Any]
                if let token = (inner?["token"] as? String) ?? (direct?["token"] as? String) { addToken(token) }
                return
            }
            if playlistTitle == nil, let metadata = dictionary["playlistMetadataRenderer"] as? [String: Any],
               let title = metadata["title"] as? String, !title.isEmpty {
                playlistTitle = title
            }
            if alert == nil, let box = (dictionary["alertRenderer"] ?? dictionary["alertWithButtonRenderer"]) as? [String: Any],
               let text = Self.text(box["text"]), !text.isEmpty {
                alert = text
            }
            // Keys in a stable order, so items come out in playlist order wherever they sit.
            for key in dictionary.keys.sorted() {
                walk(dictionary[key] as Any)
            }
        }

        private mutating func addToken(_ token: String) {
            if !tokens.contains(token) { tokens.append(token) }
        }

        private mutating func add(_ item: Item) {
            guard !item.title.isEmpty, seen.insert(item.videoID).inserted else { return }
            items.append(item)
        }

        /// The layout before 2026.
        private mutating func addOld(_ renderer: [String: Any]) {
            guard let id = renderer["videoId"] as? String, let title = Self.text(renderer["title"]) else { return }
            if renderer["isPlayable"] as? Bool == false { return }
            let channel = Self.text(renderer["shortBylineText"]) ?? ""
            let seconds = (renderer["lengthSeconds"] as? String).flatMap { Double($0) }
            add(Item(videoID: id, title: title, channel: channel, duration: seconds))
        }

        /// `lockupViewModel`: contentId, metadata.lockupMetadataViewModel.title.content, the first
        /// metadata row for the channel, and a thumbnail badge like "3:45" for the length.
        private mutating func addLockup(_ lockup: [String: Any]) {
            if let type = lockup["contentType"] as? String, type != "LOCKUP_CONTENT_TYPE_VIDEO" { return }
            guard let id = lockup["contentId"] as? String else { return }
            let metadata = (lockup["metadata"] as? [String: Any])?["lockupMetadataViewModel"] as? [String: Any]
            guard let title = Self.text(metadata?["title"]) else { return }
            let rows = ((metadata?["metadata"] as? [String: Any])?["contentMetadataViewModel"] as? [String: Any])?["metadataRows"] as? [[String: Any]]
            let firstPart = (rows?.first?["metadataParts"] as? [[String: Any]])?.first
            let channel = Self.text(firstPart?["text"]) ?? ""
            var duration: Double?
            Self.forEachBadgeText(in: lockup["contentImage"] as Any) { text in
                if duration == nil { duration = Self.clockSeconds(text) }
            }
            add(Item(videoID: id, title: title, channel: channel, duration: duration))
        }

        /// Text in any of YouTube's shapes: "simpleText", "runs", "content", or a plain string.
        static func text(_ value: Any?) -> String? {
            if let string = value as? String { return string }
            guard let dictionary = value as? [String: Any] else { return nil }
            if let simple = dictionary["simpleText"] as? String { return simple }
            if let content = dictionary["content"] as? String { return content }
            if let runs = dictionary["runs"] as? [[String: Any]] {
                let joined = runs.compactMap { $0["text"] as? String }.joined()
                return joined.isEmpty ? nil : joined
            }
            return nil
        }

        static func forEachBadgeText(in node: Any, _ body: (String) -> Void) {
            if let array = node as? [Any] {
                for element in array { forEachBadgeText(in: element, body) }
            } else if let dictionary = node as? [String: Any] {
                if let badge = dictionary["thumbnailBadgeViewModel"] as? [String: Any], let text = badge["text"] as? String {
                    body(text)
                }
                for value in dictionary.values { forEachBadgeText(in: value, body) }
            }
        }

        /// "3:45" → 225, "1:02:03" → 3723; anything else (e.g. "LIVE") → nil.
        static func clockSeconds(_ text: String) -> Double? {
            let parts = text.split(separator: ":").map { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard (2...3).contains(parts.count), parts.allSatisfy({ $0 != nil }) else { return nil }
            return Double(parts.reduce(0) { $0 * 60 + ($1 ?? 0) })
        }
    }

    /// The JSON object assigned to `name` in the page's scripts ("var ytInitialData = {…};").
    static func embeddedJSON(after name: String, in data: Data) -> Any? {
        let bytes = [UInt8](data)
        let marker = Array(name.utf8)
        guard let markerEnd = firstIndex(of: marker, in: bytes) else { return nil }
        var index = markerEnd
        while index < bytes.count, bytes[index] != UInt8(ascii: "{") {
            // Only "= " or "\"] = " may sit between the name and the object.
            if bytes[index] == UInt8(ascii: ";") || bytes[index] == UInt8(ascii: "\n") { return nil }
            index += 1
        }
        guard index < bytes.count else { return nil }
        let start = index
        var depth = 0
        var inString = false
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
            } else if byte == UInt8(ascii: "\"") {
                inString = true
            } else if byte == UInt8(ascii: "{") {
                depth += 1
            } else if byte == UInt8(ascii: "}") {
                depth -= 1
                if depth == 0 {
                    let slice = Data(bytes[start...index])
                    return try? JSONSerialization.jsonObject(with: slice)
                }
            }
            index += 1
        }
        return nil
    }

    private static func firstIndex(of marker: [UInt8], in bytes: [UInt8]) -> Int? {
        guard !marker.isEmpty, bytes.count >= marker.count else { return nil }
        var index = 0
        while index <= bytes.count - marker.count {
            if bytes[index] == marker[0], Array(bytes[index..<(index + marker.count)]) == marker {
                return index + marker.count
            }
            index += 1
        }
        return nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// Artist and title from a YouTube video.
    ///
    /// - YouTube Music tracks come from "Artist - Topic" channels with the plain song title.
    /// - Music videos are usually titled "Artist - Song (Official Video)".
    /// - Otherwise the channel is taken as the artist ("ArtistVEVO" → "Artist").
    static func song(title rawTitle: String, owner: String, duration: Double?) -> WantedSong? {
        var title = rawTitle
        // Video decorations the song itself doesn't have.
        let noise = #"\s*[\(\[](official\s*(music\s*)?(video|audio|visualizer|lyric\s*video|mv)|music\s*video|lyrics?(\s*video)?|audio|visualizer|hd|hq|4k|mv|m/v|video\s*oficial|clip\s*officiel)[\)\]]"#
        title = title.replacingOccurrences(of: noise, with: "", options: [.regularExpression, .caseInsensitive])
        title = title.replacingOccurrences(of: #"\s*[|｜].*$"#, with: "", options: .regularExpression)
        title = title.trimmingCharacters(in: .whitespaces)

        var artist: String
        if owner.hasSuffix(" - Topic") {
            artist = String(owner.dropLast(" - Topic".count))
        } else if let range = title.range(of: #"\s+[-–—]\s+"#, options: .regularExpression) {
            artist = String(title[..<range.lowerBound])
            title = String(title[range.upperBound...])
        } else {
            artist = owner
                .replacingOccurrences(of: #"(?i)vevo$"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"(?i)\s*(official|music)\s*$"#, with: "", options: .regularExpression)
        }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”"))
        artist = artist.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        return WantedSong(title: title, artists: artist.isEmpty ? [] : [artist], duration: duration)
    }
}
