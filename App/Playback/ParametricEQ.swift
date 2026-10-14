import AVFoundation
import Foundation

/// Filter shapes a parametric EQ band can take (the ones AutoEQ / Equalizer APO profiles use).
enum PEQFilter: String, Codable, CaseIterable, Identifiable {
    case peak, lowShelf, highShelf, lowPass, highPass

    var id: String { rawValue }

    var label: String {
        switch self {
        case .peak: return "Peak"
        case .lowShelf: return "Low Shelf"
        case .highShelf: return "High Shelf"
        case .lowPass: return "Low Pass"
        case .highPass: return "High Pass"
        }
    }

    var short: String {
        switch self {
        case .peak: return "PK"
        case .lowShelf: return "LSC"
        case .highShelf: return "HSC"
        case .lowPass: return "LPQ"
        case .highPass: return "HPQ"
        }
    }

    var usesGain: Bool { self != .lowPass && self != .highPass }

    var unitType: AVAudioUnitEQFilterType {
        switch self {
        case .peak: return .parametric
        case .lowShelf: return .lowShelf
        case .highShelf: return .highShelf
        case .lowPass: return .lowPass
        case .highPass: return .highPass
        }
    }
}

struct PEQBand: Codable, Identifiable, Hashable {
    var id = UUID()
    var isOn = true
    var filter: PEQFilter = .peak
    var frequency: Float = 1000
    var gain: Float = 0
    var q: Float = 1

    /// AVAudioUnitEQ wants bandwidth in octaves rather than Q.
    var bandwidthOctaves: Float {
        let octaves = 2 / log(2) * asinh(1 / (2 * Double(max(q, 0.01))))
        return Float(min(max(octaves, 0.05), 5))
    }
}

struct PEQProfile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var preamp: Float
    var bands: [PEQBand]
}

enum PEQMath {
    static let sampleRate = 48_000.0

    /// Gain in dB of one band at `frequency`, from the RBJ Audio EQ Cookbook biquads.
    static func response(of band: PEQBand, at frequency: Double) -> Double {
        guard band.isOn else { return 0 }
        let w0 = 2 * Double.pi * Double(band.frequency) / sampleRate
        let cosW0 = cos(w0), sinW0 = sin(w0)
        let q = Double(max(band.q, 0.05))
        let alpha = sinW0 / (2 * q)
        let a = pow(10, Double(band.gain) / 40)
        let shelfAlpha = sinW0 / 2 * sqrt(2)  // iOS shelves have a fixed slope (Q ≈ 0.707)
        let root = 2 * sqrt(a) * shelfAlpha

        let b0, b1, b2, a0, a1, a2: Double
        switch band.filter {
        case .peak:
            b0 = 1 + alpha * a; b1 = -2 * cosW0; b2 = 1 - alpha * a
            a0 = 1 + alpha / a; a1 = -2 * cosW0; a2 = 1 - alpha / a
        case .lowShelf:
            b0 = a * ((a + 1) - (a - 1) * cosW0 + root)
            b1 = 2 * a * ((a - 1) - (a + 1) * cosW0)
            b2 = a * ((a + 1) - (a - 1) * cosW0 - root)
            a0 = (a + 1) + (a - 1) * cosW0 + root
            a1 = -2 * ((a - 1) + (a + 1) * cosW0)
            a2 = (a + 1) + (a - 1) * cosW0 - root
        case .highShelf:
            b0 = a * ((a + 1) + (a - 1) * cosW0 + root)
            b1 = -2 * a * ((a - 1) + (a + 1) * cosW0)
            b2 = a * ((a + 1) + (a - 1) * cosW0 - root)
            a0 = (a + 1) - (a - 1) * cosW0 + root
            a1 = 2 * ((a - 1) - (a + 1) * cosW0)
            a2 = (a + 1) - (a - 1) * cosW0 - root
        case .lowPass:
            let pass = sinW0 / 2 * sqrt(2)
            b0 = (1 - cosW0) / 2; b1 = 1 - cosW0; b2 = (1 - cosW0) / 2
            a0 = 1 + pass; a1 = -2 * cosW0; a2 = 1 - pass
        case .highPass:
            let pass = sinW0 / 2 * sqrt(2)
            b0 = (1 + cosW0) / 2; b1 = -(1 + cosW0); b2 = (1 + cosW0) / 2
            a0 = 1 + pass; a1 = -2 * cosW0; a2 = 1 - pass
        }

        let w = 2 * Double.pi * frequency / sampleRate
        let numRe = b0 + b1 * cos(w) + b2 * cos(2 * w)
        let numIm = -(b1 * sin(w) + b2 * sin(2 * w))
        let denRe = a0 + a1 * cos(w) + a2 * cos(2 * w)
        let denIm = -(a1 * sin(w) + a2 * sin(2 * w))
        let ratio = (numRe * numRe + numIm * numIm) / max(denRe * denRe + denIm * denIm, 1e-12)
        return 10 * log10(max(ratio, 1e-12))
    }

    /// Total response (bands + preamp) at log-spaced points from 20 Hz to 20 kHz.
    static func curve(_ bands: [PEQBand], preamp: Float, points: Int = 160) -> [(frequency: Double, gain: Double)] {
        (0..<points).map { index in
            let frequency = 20 * pow(1000, Double(index) / Double(points - 1))
            let gain = bands.reduce(Double(preamp)) { $0 + response(of: $1, at: frequency) }
            return (frequency, gain)
        }
    }

    /// The preamp that keeps the loudest boost at 0 dB, so nothing clips.
    static func safePreamp(_ bands: [PEQBand]) -> Float {
        let peak = curve(bands, preamp: 0).map { $0.gain }.max() ?? 0
        return Float(-max(peak, 0)).roundedTo(0.1)
    }
}

/// Reads and writes the Equalizer APO / AutoEQ "ParametricEQ.txt" format:
///     Preamp: -6.3 dB
///     Filter 1: ON LSC Fc 105 Hz Gain 6.5 dB Q 0.70
enum PEQText {
    static func parse(_ text: String, name: String) -> PEQProfile? {
        var preamp: Float = 0
        var bands: [PEQBand] = []
        let filterRegex = try! NSRegularExpression(
            pattern: #"Filter\s*\d*\s*:\s*(ON|OFF)\s+([A-Za-z]+)(?:\s+\d+\s*dB)?\s+Fc\s+([\d.]+)\s*Hz(?:\s+Gain\s+([-+\d.]+)\s*dB)?(?:\s+Q\s+([\d.]+))?"#,
            options: [.caseInsensitive])
        let preampRegex = try! NSRegularExpression(pattern: #"Preamp\s*:\s*([-+\d.]+)\s*dB"#, options: [.caseInsensitive])

        for line in text.components(separatedBy: .newlines) {
            let range = NSRange(line.startIndex..., in: line)
            func group(_ match: NSTextCheckingResult, _ index: Int) -> String? {
                Range(match.range(at: index), in: line).map { String(line[$0]) }
            }
            if let match = preampRegex.firstMatch(in: line, range: range), let value = group(match, 1).flatMap(Float.init) {
                preamp = value
                continue
            }
            guard let match = filterRegex.firstMatch(in: line, range: range),
                  let kind = group(match, 2)?.uppercased(),
                  let frequency = group(match, 3).flatMap(Float.init) else { continue }
            let filter: PEQFilter
            switch kind {
            case "PK", "PEQ", "MODAL", "PEAK": filter = .peak
            case "LS", "LSC", "LSQ", "LOWSHELF": filter = .lowShelf
            case "HS", "HSC", "HSQ", "HIGHSHELF": filter = .highShelf
            case "LP", "LPQ", "LOWPASS": filter = .lowPass
            case "HP", "HPQ", "HIGHPASS": filter = .highPass
            default: continue
            }
            let band = PEQBand(isOn: group(match, 1)?.uppercased() == "ON",
                               filter: filter,
                               frequency: min(max(frequency, 10), 22_000),
                               gain: group(match, 4).flatMap(Float.init) ?? 0,
                               q: group(match, 5).flatMap(Float.init) ?? 0.707)
            bands.append(band)
            if bands.count == Equalizer.maxBands { break }
        }
        guard !bands.isEmpty else { return nil }
        return PEQProfile(name: name, preamp: preamp, bands: bands)
    }

    static func export(_ bands: [PEQBand], preamp: Float) -> String {
        var lines = [String(format: "Preamp: %.1f dB", preamp)]
        for (index, band) in bands.enumerated() {
            lines.append(String(format: "Filter %d: %@ %@ Fc %.0f Hz Gain %.1f dB Q %.2f",
                                index + 1, band.isOn ? "ON" : "OFF", band.filter.short,
                                band.frequency, band.gain, band.q))
        }
        return lines.joined(separator: "\n")
    }
}

/// Headphone profiles from the AutoEq project (github.com/jaakkopasanen/AutoEq).
actor AutoEqIndex {
    static let shared = AutoEqIndex()

    struct Entry: Identifiable, Hashable, Sendable {
        let name: String
        /// Path under results/, still percent-encoded as in the index.
        let path: String
        let source: String
        var id: String { path }
    }

    private static let base = "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/"
    private var cached: [Entry]?
    private let cacheFile = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("autoeq-index.md")

    func entries() async throws -> [Entry] {
        if let cached { return cached }
        var text: String?
        if let attributes = try? FileManager.default.attributesOfItem(atPath: cacheFile.path),
           let date = attributes[.modificationDate] as? Date, Date().timeIntervalSince(date) < 7 * 86_400 {
            text = try? String(contentsOf: cacheFile, encoding: .utf8)
        }
        if text == nil {
            let (data, response) = try await URLSession.shared.data(from: URL(string: Self.base + "INDEX.md")!)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            try? data.write(to: cacheFile, options: .atomic)
            text = String(decoding: data, as: UTF8.self)
        }
        let parsed = Self.parseIndex(text ?? "")
        cached = parsed
        return parsed
    }

    /// Lines look like: - [Sennheiser HD 600](./oratory1990/over-ear/Sennheiser%20HD%20600) by oratory1990
    static func parseIndex(_ text: String) -> [Entry] {
        let regex = try! NSRegularExpression(pattern: #"^-\s*\[(.+)\]\(\./(.+)\)\s*(?:by\s+(.*))?$"#)
        var result: [Entry] = []
        for line in text.components(separatedBy: .newlines) {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let name = Range(match.range(at: 1), in: line).map({ String(line[$0]) }),
                  let path = Range(match.range(at: 2), in: line).map({ String(line[$0]) }) else { continue }
            let source = Range(match.range(at: 3), in: line).map { String(line[$0]) } ?? ""
            result.append(Entry(name: name, path: path, source: source))
        }
        return result
    }

    func profile(for entry: Entry) async throws -> PEQProfile {
        // The file is named after the folder: "<folder> ParametricEQ.txt".
        let folder = entry.path.split(separator: "/").last.map(String.init) ?? ""
        let fileName = (folder.removingPercentEncoding ?? folder) + " ParametricEQ.txt"
        guard let encoded = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: Self.base + entry.path + "/" + encoded) else { throw URLError(.badURL) }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.fileDoesNotExist) }
        guard let profile = PEQText.parse(String(decoding: data, as: UTF8.self), name: entry.name) else {
            throw URLError(.cannotParseResponse)
        }
        return profile
    }
}

extension Float {
    func roundedTo(_ step: Float) -> Float { (self / step).rounded() * step }
}
