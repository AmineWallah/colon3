import Foundation
import SoulseekKit

/// Search result filters and ordering, saved between launches.
struct ResultFilters: Codable, Equatable {
    enum FileType: String, Codable, CaseIterable, Identifiable {
        case any = "Any Type", lossless = "Lossless", lossy = "Lossy", flac = "FLAC", mp3 = "MP3",
             aac = "AAC / M4A", wav = "WAV / AIFF"
        var id: String { rawValue }

        var shortLabel: String {
            switch self {
            case .any: return "Type"
            case .aac: return "AAC"
            case .wav: return "WAV"
            default: return rawValue
            }
        }
    }

    enum Sort: String, Codable, CaseIterable, Identifiable {
        case relevance = "Relevance", bandwidth = "Highest Bandwidth", freeQueue = "Most Free Queue",
             quality = "Highest Quality", files = "Most Files"
        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .relevance: return "text.magnifyingglass"
            case .bandwidth: return "speedometer"
            case .freeQueue: return "person.line.dotted.person"
            case .quality: return "waveform"
            case .files: return "number"
            }
        }
    }

    var fileType: FileType = .any
    /// Minimum kbps for lossy files; lossless files always pass.
    var minBitrate = 0
    var freeSlotOnly = false
    var minFiles = 1
    /// Comma- or space-separated words; folders whose path contains any of them are hidden.
    var excludeWords = ""
    var sort: Sort = .relevance

    static let bitrateChoices = [0, 128, 192, 256, 320]

    var isDefault: Bool { self == ResultFilters() }

    /// How many filters differ from the defaults (sort doesn't count).
    var activeCount: Int {
        [fileType != .any, minBitrate > 0, freeSlotOnly, minFiles > 1, !excludedTerms.isEmpty].filter { $0 }.count
    }

    var excludedTerms: [String] {
        excludeWords
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    func accepts(_ folder: FolderResult) -> Bool {
        if freeSlotOnly, !folder.slotFree { return false }
        if folder.files.count < minFiles { return false }
        let path = folder.folder.lowercased()
        if excludedTerms.contains(where: { path.contains($0) }) { return false }

        let extensions = Set(folder.files.map(\.fileExtension))
        switch fileType {
        case .any: break
        case .lossless: if !folder.isLossless { return false }
        case .lossy: if folder.isLossless { return false }
        case .flac: if !extensions.isSubset(of: ["flac"]) { return false }
        case .mp3: if !extensions.isSubset(of: ["mp3"]) { return false }
        case .aac: if !extensions.isSubset(of: ["m4a", "aac", "mp4", "m4b"]) { return false }
        case .wav: if !extensions.isSubset(of: ["wav", "aif", "aiff"]) { return false }
        }

        if minBitrate > 0, !folder.isLossless {
            let bitrates = folder.files.compactMap(\.attributes.bitrate)
            // Folders that don't report a bitrate can't be judged; keep them.
            if let lowest = bitrates.min(), Int(lowest) < minBitrate { return false }
        }
        return true
    }

    func ordered(_ folders: [FolderResult], query: String) -> [FolderResult] {
        let terms = Self.terms(query)
        let scores = Dictionary(folders.map { ($0.id, sort == .relevance ? Self.relevance($0, terms: terms, query: query) : 0) },
                                uniquingKeysWith: { first, _ in first })

        return folders.sorted { lhs, rhs in
            switch sort {
            case .relevance:
                let left = scores[lhs.id] ?? 0, right = scores[rhs.id] ?? 0
                if left != right { return left > right }
                return Self.availability(lhs, rhs)
            case .bandwidth:
                if lhs.speed != rhs.speed { return lhs.speed > rhs.speed }
                return Self.availability(lhs, rhs)
            case .freeQueue:
                return Self.availability(lhs, rhs)
            case .quality:
                if lhs.qualityScore != rhs.qualityScore { return lhs.qualityScore > rhs.qualityScore }
                return Self.availability(lhs, rhs)
            case .files:
                if lhs.files.count != rhs.files.count { return lhs.files.count > rhs.files.count }
                return Self.availability(lhs, rhs)
            }
        }
    }

    /// Free slot first, then the shortest queue, then the fastest connection.
    private static func availability(_ lhs: FolderResult, _ rhs: FolderResult) -> Bool {
        if lhs.slotFree != rhs.slotFree { return lhs.slotFree }
        if lhs.queueLength != rhs.queueLength { return lhs.queueLength < rhs.queueLength }
        return lhs.speed > rhs.speed
    }

    static func terms(_ query: String) -> [String] {
        query.lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
            .map(String.init)
            .filter { $0.count > 1 || $0.first?.isNumber == true }
    }

    /// Higher when the search words sit in the folder's own name rather than deep in the path or
    /// only in a filename, with a bonus for the exact phrase.
    static func relevance(_ folder: FolderResult, terms: [String], query: String) -> Int {
        guard !terms.isEmpty else { return 0 }
        let name = normalize(folder.name)
        let parents = normalize(folder.parentPath)
        let filenames = folder.files.map { normalize($0.filename) }
        let phrase = normalize(query)

        var score = 0
        var covered = 0
        for term in terms {
            var found = false
            if name.contains(term) { score += 6; found = true }
            if parents.contains(term) { score += 3; found = true }
            let fileHits = filenames.filter { $0.contains(term) }.count
            if fileHits > 0 {
                score += 1 + min(fileHits, 5)
                found = true
            }
            if found { covered += 1 }
        }
        if covered == terms.count { score += 10 }
        if !phrase.isEmpty, name.contains(phrase) || (parents + " " + name).contains(phrase) { score += 8 }
        // Extra matching songs suggest an album rather than a stray single.
        score += min(folder.files.count, 12) / 4
        return score
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .folding(options: [.diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
    }

    static func load() -> ResultFilters {
        guard let data = UserDefaults.standard.data(forKey: "search.filters.v2"),
              let filters = try? JSONDecoder().decode(ResultFilters.self, from: data) else { return ResultFilters() }
        return filters
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "search.filters.v2")
        }
    }
}

extension FolderResult {
    var isLossless: Bool {
        !files.isEmpty && files.allSatisfy { file in
            ["flac", "wav", "aif", "aiff", "alac"].contains(file.fileExtension) || file.attributes.bitDepth != nil
        }
    }

    /// Rough ordering: hi-res lossless > lossless > high-bitrate lossy.
    var qualityScore: Int {
        if isLossless {
            let depth = files.compactMap(\.attributes.bitDepth).max() ?? 16
            let rate = files.compactMap(\.attributes.sampleRate).max() ?? 44_100
            return 10_000 + Int(depth) * 100 + Int(rate / 1000)
        }
        return Int(files.compactMap(\.attributes.bitrate).min() ?? 0)
    }
}
