import Foundation
import SoulseekKit

/// Search result filters, saved between launches.
struct ResultFilters: Codable, Equatable {
    enum Format: String, Codable, CaseIterable, Identifiable {
        case any = "Any", lossless = "Lossless", lossy = "Lossy", flac = "FLAC", mp3 = "MP3"
        var id: String { rawValue }
    }

    enum Sort: String, Codable, CaseIterable, Identifiable {
        case best = "Best Match", speed = "Fastest", queue = "Shortest Queue", quality = "Highest Quality", files = "Most Files"
        var id: String { rawValue }
    }

    var format: Format = .any
    /// Minimum kbps for lossy files; lossless files always pass.
    var minBitrate = 0
    var freeSlotOnly = false
    var minFiles = 1
    /// Comma- or space-separated words; folders whose path contains any of them are hidden.
    var excludeWords = ""
    var sort: Sort = .best

    static let bitrateChoices = [0, 128, 192, 256, 320]

    var isDefault: Bool { self == ResultFilters() }

    /// How many filters differ from the defaults (sort doesn't count).
    var activeCount: Int {
        [format != .any, minBitrate > 0, freeSlotOnly, minFiles > 1,
         !excludedTerms.isEmpty].filter { $0 }.count
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

        switch format {
        case .any: break
        case .lossless: if !folder.isLossless { return false }
        case .lossy: if folder.isLossless { return false }
        case .flac: if !folder.files.allSatisfy({ $0.fileExtension == "flac" }) { return false }
        case .mp3: if !folder.files.allSatisfy({ $0.fileExtension == "mp3" }) { return false }
        }

        if minBitrate > 0, !folder.isLossless {
            let bitrates = folder.files.compactMap(\.attributes.bitrate)
            // Folders that don't report a bitrate can't be judged; keep them.
            if let lowest = bitrates.min(), Int(lowest) < minBitrate { return false }
        }
        return true
    }

    func ordered(_ folders: [FolderResult]) -> [FolderResult] {
        folders.sorted { lhs, rhs in
            switch sort {
            case .best:
                if lhs.slotFree != rhs.slotFree { return lhs.slotFree }
                if lhs.queueLength != rhs.queueLength { return lhs.queueLength < rhs.queueLength }
                return lhs.speed > rhs.speed
            case .speed:
                return lhs.speed > rhs.speed
            case .queue:
                if lhs.slotFree != rhs.slotFree { return lhs.slotFree }
                return lhs.queueLength < rhs.queueLength
            case .quality:
                if lhs.qualityScore != rhs.qualityScore { return lhs.qualityScore > rhs.qualityScore }
                return lhs.speed > rhs.speed
            case .files:
                if lhs.files.count != rhs.files.count { return lhs.files.count > rhs.files.count }
                return lhs.speed > rhs.speed
            }
        }
    }

    static func load() -> ResultFilters {
        guard let data = UserDefaults.standard.data(forKey: "search.filters"),
              let filters = try? JSONDecoder().decode(ResultFilters.self, from: data) else { return ResultFilters() }
        return filters
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "search.filters")
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
