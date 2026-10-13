import AVFoundation
import Foundation

/// Tags we care about, cached per file so rescans don't reopen every track.
struct TrackInfo: Codable, Equatable {
    var title: String?
    var artist: String?
    var albumArtist: String?
    var album: String?
    var trackNumber: Int?
    var discNumber: Int?
    var year: Int?
    var duration: Double = 0
    var isSpatial = false
    var hasEmbeddedArt = false
    /// MusicBrainz release ID, written by Picard and most taggers (FLAC only for now).
    var musicBrainzAlbumID: String?
}

enum MetadataReader {
    static func read(url: URL) async -> TrackInfo {
        var info: TrackInfo
        if url.pathExtension.lowercased() == "flac", let flac = FLACReader.read(url: url, wantPicture: false) {
            info = TrackInfo()
            info.title = flac.tags["TITLE"]
            info.artist = flac.tags["ARTIST"]
            info.albumArtist = flac.tags["ALBUMARTIST"] ?? flac.tags["ALBUM ARTIST"]
            info.album = flac.tags["ALBUM"]
            info.trackNumber = leadingNumber(flac.tags["TRACKNUMBER"])
            info.discNumber = leadingNumber(flac.tags["DISCNUMBER"])
            info.year = leadingNumber(flac.tags["DATE"] ?? flac.tags["YEAR"])
            info.duration = flac.duration
            info.isSpatial = flac.channels > 2
            info.hasEmbeddedArt = flac.hasPicture
            info.musicBrainzAlbumID = flac.tags["MUSICBRAINZ_ALBUMID"]
        } else {
            info = await readWithAVFoundation(url: url)
        }

        // Filename fallbacks: "01 - Title.mp3", "1-03 Title.flac", "03. Title.m4a"
        let parsed = parseFilename(url.deletingPathExtension().lastPathComponent)
        if info.title?.isEmpty ?? true { info.title = parsed.title }
        if info.trackNumber == nil { info.trackNumber = parsed.number }
        return info
    }

    private static func readWithAVFoundation(url: URL) async -> TrackInfo {
        var info = TrackInfo()
        let asset = AVURLAsset(url: url)
        if let duration = try? await asset.load(.duration), duration.isNumeric {
            info.duration = duration.seconds
        }

        let formatItems = (try? await asset.load(.metadata)) ?? []
        let commonItems = (try? await asset.load(.commonMetadata)) ?? []
        let items = formatItems + commonItems

        func string(_ identifiers: [AVMetadataIdentifier]) async -> String? {
            for item in items {
                guard let identifier = item.identifier, identifiers.contains(identifier) else { continue }
                if let value = try? await item.load(.stringValue), !value.trimmingCharacters(in: .whitespaces).isEmpty {
                    return value.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            return nil
        }

        /// ID3 stores "3/12" as text; iTunes "trkn"/"disk" are 8 bytes with the number at offset 2.
        func number(_ identifiers: [AVMetadataIdentifier]) async -> Int? {
            for item in items {
                guard let identifier = item.identifier, identifiers.contains(identifier) else { continue }
                if let text = try? await item.load(.stringValue), let value = leadingNumber(text) { return value }
                if let value = try? await item.load(.numberValue), value.intValue > 0 { return value.intValue }
                if let data = try? await item.load(.dataValue), data.count >= 4 {
                    let bytes = [UInt8](data)
                    let value = Int(bytes[2]) << 8 | Int(bytes[3])
                    if value > 0 { return value }
                }
            }
            return nil
        }

        info.title = await string([.commonIdentifierTitle, .id3MetadataTitleDescription, .iTunesMetadataSongName])
        info.artist = await string([.commonIdentifierArtist, .id3MetadataLeadPerformer, .iTunesMetadataArtist])
        info.album = await string([.commonIdentifierAlbumName, .id3MetadataAlbumTitle, .iTunesMetadataAlbum])
        info.albumArtist = await string([.iTunesMetadataAlbumArtist, .id3MetadataBand])
        info.trackNumber = await number([.id3MetadataTrackNumber, .iTunesMetadataTrackNumber])
        info.discNumber = await number([.id3MetadataPartOfASet, .iTunesMetadataDiscNumber])
        let yearText = await string([.id3MetadataYear, .id3MetadataRecordingTime,
                                     .iTunesMetadataReleaseDate, .commonIdentifierCreationDate])
        info.year = leadingNumber(yearText)

        let artworkIDs: [AVMetadataIdentifier] = [.commonIdentifierArtwork, .id3MetadataAttachedPicture, .iTunesMetadataCoverArt]
        info.hasEmbeddedArt = items.contains { item in
            guard let identifier = item.identifier else { return false }
            return artworkIDs.contains(identifier)
        }

        if let tracks = try? await asset.loadTracks(withMediaType: .audio) {
            for track in tracks {
                let descriptions = (try? await track.load(.formatDescriptions)) ?? []
                for description in descriptions {
                    guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { continue }
                    if asbd.mFormatID == kAudioFormatEnhancedAC3 || asbd.mChannelsPerFrame > 2 {
                        info.isSpatial = true
                    }
                }
            }
        }
        return info
    }

    static func embeddedArtwork(url: URL) async -> Data? {
        if url.pathExtension.lowercased() == "flac" {
            return FLACReader.read(url: url, wantPicture: true)?.picture
        }
        let asset = AVURLAsset(url: url)
        let formatItems = (try? await asset.load(.metadata)) ?? []
        let commonItems = (try? await asset.load(.commonMetadata)) ?? []
        let items = formatItems + commonItems
        let artworkIDs: [AVMetadataIdentifier] = [.commonIdentifierArtwork, .id3MetadataAttachedPicture, .iTunesMetadataCoverArt]
        for item in items {
            guard let identifier = item.identifier, artworkIDs.contains(identifier) else { continue }
            if let data = try? await item.load(.dataValue), !data.isEmpty { return data }
        }
        return nil
    }

    static func leadingNumber(_ text: String?) -> Int? {
        guard let text else { return nil }
        let digits = text.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber }
        guard let value = Int(digits), value > 0 else { return nil }
        return value
    }

    static func parseFilename(_ name: String) -> (number: Int?, title: String) {
        var rest = Substring(name)
        var number: Int?
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            var after = rest.dropFirst(digits.count)
            // "1-03 Title": disc-track
            let trackDigits = after.first == "-" ? after.dropFirst().prefix(while: { $0.isNumber }) : Substring()
            if !trackDigits.isEmpty {
                number = Int(trackDigits)
                after = after.dropFirst(1 + trackDigits.count)
            } else {
                number = Int(digits)
            }
            let separators: Set<Character> = [" ", ".", "-", "_", ")"]
            let trimmed = after.drop { separators.contains($0) }
            let startsWithSeparator = after.first.map { separators.contains($0) } ?? false
            if !trimmed.isEmpty, startsWithSeparator {
                rest = trimmed
            } else {
                number = nil
            }
        }
        let title = rest.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        return (number, title.isEmpty ? name : title)
    }
}

/// Minimal FLAC metadata reader: STREAMINFO, Vorbis comments and the front-cover PICTURE block.
/// AVFoundation plays FLAC fine but doesn't reliably expose its tags.
enum FLACReader {
    struct Result {
        var tags: [String: String] = [:]
        var duration: Double = 0
        var channels = 2
        var hasPicture = false
        var picture: Data?
    }

    static func read(url: URL, wantPicture: Bool) -> Result? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 4), magic == Data("fLaC".utf8) else { return nil }

        var result = Result()
        var bestPictureType: UInt32 = .max
        while true {
            guard let header = try? handle.read(upToCount: 4), header.count == 4 else { break }
            let bytes = [UInt8](header)
            let isLast = bytes[0] & 0x80 != 0
            let type = bytes[0] & 0x7F
            let length = Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])

            switch type {
            case 0, 4:
                guard let block = try? handle.read(upToCount: length), block.count == length else { return result }
                if type == 0 { parseStreamInfo([UInt8](block), into: &result) } else { parseComments([UInt8](block), into: &result) }
            case 6:
                result.hasPicture = true
                if wantPicture {
                    guard let block = try? handle.read(upToCount: length), block.count == length else { return result }
                    if let picture = parsePicture([UInt8](block)) {
                        // Type 3 is "front cover"; otherwise keep the first picture.
                        let rank: UInt32 = picture.type == 3 ? 0 : picture.type + 1
                        if rank < bestPictureType {
                            bestPictureType = rank
                            result.picture = picture.data
                        }
                    }
                } else {
                    guard skip(handle, length) else { return result }
                }
            default:
                guard skip(handle, length) else { return result }
            }
            if isLast { break }
        }
        return result
    }

    private static func skip(_ handle: FileHandle, _ length: Int) -> Bool {
        guard let offset = try? handle.offset() else { return false }
        return (try? handle.seek(toOffset: offset + UInt64(length))) != nil
    }

    private static func parseStreamInfo(_ block: [UInt8], into result: inout Result) {
        guard block.count >= 18 else { return }
        // Bytes 10...17: 20 bits sample rate, 3 bits channels-1, 5 bits bps-1, 36 bits total samples.
        let sampleRate = Int(block[10]) << 12 | Int(block[11]) << 4 | Int(block[12]) >> 4
        result.channels = Int((block[12] >> 1) & 0x07) + 1
        var totalSamples = UInt64(block[13] & 0x0F)
        for index in 14...17 { totalSamples = totalSamples << 8 | UInt64(block[index]) }
        if sampleRate > 0 { result.duration = Double(totalSamples) / Double(sampleRate) }
    }

    private static func parseComments(_ block: [UInt8], into result: inout Result) {
        var offset = 0
        func u32() -> Int? {
            guard offset + 4 <= block.count else { return nil }
            let value = Int(block[offset]) | Int(block[offset + 1]) << 8 | Int(block[offset + 2]) << 16 | Int(block[offset + 3]) << 24
            offset += 4
            return value
        }
        guard let vendorLength = u32(), offset + vendorLength <= block.count else { return }
        offset += vendorLength
        guard let count = u32() else { return }
        for _ in 0..<count {
            guard let length = u32(), length >= 0, offset + length <= block.count else { return }
            let comment = String(decoding: block[offset..<(offset + length)], as: UTF8.self)
            offset += length
            guard let equals = comment.firstIndex(of: "=") else { continue }
            let key = comment[..<equals].uppercased()
            let value = comment[comment.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if result.tags[key] == nil, !value.isEmpty { result.tags[key] = value }
        }
    }

    private static func parsePicture(_ block: [UInt8]) -> (type: UInt32, data: Data)? {
        var offset = 0
        func u32() -> Int? {
            guard offset + 4 <= block.count else { return nil }
            let value = Int(block[offset]) << 24 | Int(block[offset + 1]) << 16 | Int(block[offset + 2]) << 8 | Int(block[offset + 3])
            offset += 4
            return value
        }
        guard let type = u32(), let mimeLength = u32() else { return nil }
        offset += mimeLength
        guard let descriptionLength = u32() else { return nil }
        offset += descriptionLength
        offset += 16  // width, height, depth, colours
        guard let dataLength = u32(), offset + dataLength <= block.count, dataLength > 0 else { return nil }
        return (type: UInt32(truncatingIfNeeded: type), data: Data(block[offset..<(offset + dataLength)]))
    }
}
