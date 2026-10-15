import Foundation
import SoulseekKit

/// A song described by another service (Spotify, Apple Music, Last.fm), to be found in the
/// library or on Soulseek.
struct WantedSong: Hashable {
    let title: String
    let artists: [String]
    var album: String?
    /// Seconds, when the source knows it.
    var duration: Double?

    var primaryArtist: String { artists.first ?? "" }
}

/// Text normalisation and scoring shared by autoplay and the playlist importers.
enum TrackMatcher {
    // MARK: Normalisation

    /// "Song (feat. X) - 2011 Remaster" → "song". Letters and digits only, any script.
    static func normalizeTitle(_ title: String) -> String {
        var text = fold(title)
        for pattern in [#"\([^)]*\)"#, #"\[[^\]]*\]"#, #"\b(feat|ft|featuring)\.?\s.*$"#,
                        #"\s-\s.*\b(remaster|remastered|version|edit|mix|mono|stereo|live|recorded|single|radio|acoustic|demo|bonus|deluxe|explicit|instrumental|from|session|take)\b.*$"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        let result = alphanumerics(text)
        // A title that was all brackets ("(Untitled)") keeps its words.
        return result.isEmpty ? alphanumerics(fold(title)) : result
    }

    /// "The Beatles" → "beatles", "Simon & Garfunkel" → "simonandgarfunkel".
    static func normalizeName(_ name: String) -> String {
        var text = fold(name).replacingOccurrences(of: "&", with: " and ")
        text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("the "), text.count > 4 { text.removeFirst(4) }
        return alphanumerics(text)
    }

    /// The whole credit plus each name in it: "A feat. B & C" → the full credit, "a", "b", "c".
    static func artistKeys(_ credit: String) -> Set<String> {
        var keys = Set<String>()
        let whole = normalizeName(credit)
        if !whole.isEmpty { keys.insert(whole) }
        let separators = #"\s*(,|;|/|&|\+|\bfeat\b\.?|\bft\b\.?|\bfeaturing\b|\bwith\b|\bvs\b\.?|\bx\b|\band\b)\s*"#
        let marked = fold(credit).replacingOccurrences(of: separators, with: "\u{1F}", options: .regularExpression)
        for part in marked.split(separator: "\u{1F}") {
            let key = normalizeName(String(part))
            if key.count >= 2 { keys.insert(key) }
        }
        return keys
    }

    static func artistsOverlap(_ lhs: Set<String>, _ rhs: Set<String>) -> Bool {
        if !lhs.isDisjoint(with: rhs) { return true }
        for left in lhs where left.count >= 4 {
            for right in rhs where right.count >= 4 {
                if left.contains(right) || right.contains(left) { return true }
            }
        }
        return false
    }

    /// Words that mark a different recording of a song than the original.
    static func variantWords(_ text: String) -> Set<String> {
        let folded = " " + fold(text).replacingOccurrences(of: #"[_.]"#, with: " ", options: .regularExpression) + " "
        var found = Set<String>()
        for (word, pattern) in variantPatterns where folded.range(of: pattern, options: .regularExpression) != nil {
            found.insert(word)
        }
        return found
    }

    private static let variantPatterns: [(String, String)] = [
        ("live", #"\blive\b"#),
        ("remix", #"\b(re-?mix(es|ed)?|rmx)\b"#),
        ("karaoke", #"\bkaraoke\b"#),
        ("instrumental", #"\binstrumentals?\b"#),
        ("acapella", #"\ba\s?cap+ell+a\b"#),
        ("cover", #"\bcovers?\b"#),
        ("tribute", #"\btribute\b"#),
        ("nightcore", #"\bnightcore\b"#),
        ("sped up", #"\bsped\s?up\b"#),
        ("slowed", #"\bslowed\b"#),
        ("acoustic", #"\bacoustic\b"#),
        ("unplugged", #"\bunplugged\b"#),
        ("demo", #"\bdemo\b"#),
        ("8bit", #"\b8[\s-]?bit\b"#),
        ("extended", #"\bextended\b"#),
    ]

    private static func fold(_ text: String) -> String {
        text.lowercased().folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private static func alphanumerics(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// Identifies a song across sources: "title|artist", normalised.
    static func songKey(_ song: WantedSong) -> String {
        normalizeTitle(song.title) + "|" + normalizeName(song.primaryArtist)
    }

    // MARK: Soulseek

    /// "Artist Title" with the version noise removed, in the form the Soulseek server matches:
    /// every word has to appear in the path, so words it might spell differently are left out.
    static func searchQuery(for song: WantedSong, includeArtist: Bool = true) -> String {
        let title = song.title
            .replacingOccurrences(of: #"\([^)]*\)|\[[^\]]*\]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s-\s.*$"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\b(feat|ft|featuring)\.?\s.*$"#, with: " ", options: [.regularExpression, .caseInsensitive])
        let text = includeArtist ? song.primaryArtist + " " + title : title
        let words = text
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            // "Don't" may be stored as "Dont" or "Don t"; the title check after the search copes.
            .filter { !$0.contains("'") && !$0.contains("’") }
            .map { $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
            .filter { !$0.isEmpty }
        return ResultFilters.terms(words.joined(separator: " ")).joined(separator: " ")
    }

    struct Prepared {
        let title: String
        let artists: Set<String>
        let variants: Set<String>
        let duration: Double?

        init(_ song: WantedSong) {
            title = TrackMatcher.normalizeTitle(song.title)
            artists = song.artists.reduce(into: Set<String>()) { $0.formUnion(TrackMatcher.artistKeys($1)) }
            variants = TrackMatcher.variantWords(song.title + " " + (song.album ?? ""))
            duration = song.duration.flatMap { $0 > 0 ? $0 : nil }
        }
    }

    /// Higher is better; nil means the file isn't this song (wrong title, a live or remixed
    /// version the original isn't, a very different length, an unplayable format).
    static func score(_ file: SharedFile, slotFree: Bool, queueLength: UInt32, speed: UInt32,
                      for wanted: Prepared, requireArtistInPath: Bool = false) -> Int? {
        guard LibraryStore.audioExtensions.contains(file.fileExtension), file.size > 400_000,
              !wanted.title.isEmpty else { return nil }
        let stem = (file.filename as NSString).deletingPathExtension
        let fileTitle = normalizeTitle(stem)
        guard fileTitle.contains(wanted.title) else { return nil }

        var score = 0

        // What's left of the filename once the artist and the track number are taken out.
        var residual = fileTitle
        for artist in wanted.artists.sorted(by: { $0.count > $1.count }) where artist.count >= 2 {
            if let range = residual.range(of: artist) {
                residual.removeSubrange(range)
                break
            }
        }
        residual = String(residual.drop(while: \.isNumber))
        if residual == wanted.title {
            score += 20
        } else if residual.hasSuffix(wanted.title) || residual.hasPrefix(wanted.title) {
            score += 8
            if residual.count - wanted.title.count > 14 { score -= 10 }
        } else if wanted.title.count < 8 {
            return nil  // "Home" inside "Homecoming": too easy to get wrong.
        }

        let path = normalizeName(file.path)
        if wanted.artists.contains(where: { $0.count >= 2 && path.contains($0) }) {
            score += 10
        } else if requireArtistInPath {
            return nil
        } else {
            score -= 15
        }

        let variants = variantWords(stem + " " + file.folderName)
        guard variants.isSubset(of: wanted.variants) else { return nil }
        if !wanted.variants.isEmpty, wanted.variants.isDisjoint(with: variants) { score -= 10 }

        if let want = wanted.duration {
            if let seconds = file.attributes.duration, seconds > 0 {
                let difference = abs(Double(seconds) - want)
                switch difference {
                case ...2: score += 15
                case ...5: score += 10
                case ...10: score += 3
                case ...20: score -= 10
                default: return nil
                }
            } else {
                score -= 3
            }
        }

        let losslessExtensions: Set<String> = ["flac", "wav", "aif", "aiff", "alac"]
        if let rate = file.attributes.sampleRate, rate > 192_000 {
            return nil  // DXD-style rips: huge, and past what the player's EQ path takes.
        }
        if losslessExtensions.contains(file.fileExtension) || file.attributes.bitDepth != nil {
            // Hi-res plays fine but costs 3–6× the download; CD quality is preferred.
            score += (file.attributes.sampleRate ?? 44_100) > 96_000 ? 22 : 30
        } else if let bitrate = file.attributes.bitrate {
            switch bitrate {
            case 310...: score += 24
            case 250...: score += 18
            case 190...: score += 10
            case 160...: score += 4
            case ..<128: score -= 10
            default: break
            }
        } else {
            score += 6
        }

        if slotFree {
            score += 25
        } else {
            score -= Int(min(queueLength, 50)) / 2
        }
        score += min(Int(speed / 200_000), 10)
        return score
    }
}

/// Library songs looked up by normalised title and by artist.
struct LibraryIndex {
    private var byTitle: [String: [Track]] = [:]
    private var byArtist: [String: [Track]] = [:]

    init(_ tracks: [Track]) {
        for track in tracks {
            let title = TrackMatcher.normalizeTitle(track.title)
            if !title.isEmpty { byTitle[title, default: []].append(track) }
            var artists = TrackMatcher.artistKeys(track.artist)
            if let albumArtist = track.albumArtist { artists.formUnion(TrackMatcher.artistKeys(albumArtist)) }
            for artist in artists { byArtist[artist, default: []].append(track) }
        }
    }

    /// The library copy of a song: same title and artist, same kind of recording (a live take
    /// doesn't stand in for the studio one), and a similar length when both are known.
    func match(_ song: WantedSong) -> Track? {
        let title = TrackMatcher.normalizeTitle(song.title)
        guard !title.isEmpty, let candidates = byTitle[title] else { return nil }
        let artists = song.artists.reduce(into: Set<String>()) { $0.formUnion(TrackMatcher.artistKeys($1)) }
        let variants = TrackMatcher.variantWords(song.title + " " + (song.album ?? ""))
        let fitting = candidates.filter { track in
            var keys = TrackMatcher.artistKeys(track.artist)
            if let albumArtist = track.albumArtist { keys.formUnion(TrackMatcher.artistKeys(albumArtist)) }
            guard TrackMatcher.artistsOverlap(keys, artists) else { return false }
            guard TrackMatcher.variantWords(track.title + " " + (track.album ?? "")) == variants else { return false }
            if let duration = song.duration, duration > 0, track.duration > 0, abs(track.duration - duration) > 30 {
                return false
            }
            return true
        }
        guard let duration = song.duration, duration > 0 else { return fitting.first }
        return fitting.min { abs($0.duration - duration) < abs($1.duration - duration) }
    }

    /// Songs credited to an artist (alone or as one of several).
    func tracks(byArtist name: String) -> [Track] {
        var seen = Set<String>()
        var result: [Track] = []
        for key in TrackMatcher.artistKeys(name) {
            for track in byArtist[key] ?? [] where seen.insert(track.id).inserted {
                result.append(track)
            }
        }
        return result
    }
}
