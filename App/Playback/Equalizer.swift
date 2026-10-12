import AVFoundation
import Foundation

struct EQPreset: Identifiable, Codable, Hashable {
    var id: String { name }
    let name: String
    let gains: [Float]
}

/// 10-band graphic EQ settings. Applied to AVAudioUnitEQ by the engine backend; spatial (AVPlayer)
/// playback bypasses it.
@MainActor
final class Equalizer: ObservableObject {
    nonisolated static let frequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    nonisolated static let gainRange: ClosedRange<Float> = -12...12

    nonisolated static let builtIn: [EQPreset] = [
        EQPreset(name: "Flat", gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        EQPreset(name: "Bass Boost", gains: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        EQPreset(name: "Bass Reducer", gains: [-6, -5, -4, -2, 0, 0, 0, 0, 0, 0]),
        EQPreset(name: "Treble Boost", gains: [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]),
        EQPreset(name: "Treble Reducer", gains: [0, 0, 0, 0, 0, -1, -2, -4, -5, -6]),
        EQPreset(name: "Vocal Booster", gains: [-2, -2, -1, 1, 3, 4, 3, 1, 0, -1]),
        EQPreset(name: "Rock", gains: [5, 4, 2, -1, -2, -1, 2, 3, 4, 4]),
        EQPreset(name: "Electronic", gains: [5, 4, 1, 0, -2, 1, 1, 2, 4, 5]),
        EQPreset(name: "Hip-Hop", gains: [5, 4, 1, 2, -1, -1, 1, -1, 2, 3]),
        EQPreset(name: "Acoustic", gains: [4, 4, 3, 1, 2, 2, 3, 3, 3, 2]),
        EQPreset(name: "Piano", gains: [2, 1, 0, 2, 3, 1, 3, 4, 3, 3]),
        EQPreset(name: "Late Night", gains: [3, 2, 1, 0, -1, -1, 0, 1, 2, 2]),
    ]

    @Published var isEnabled: Bool {
        didSet { changed() }
    }
    @Published var gains: [Float] {
        didSet {
            if !isApplyingPreset { presetName = matchingPresetName() }
            changed()
        }
    }
    /// dB applied before the bands. Presets set it to leave headroom for boosts, which would clip otherwise.
    @Published var preamp: Float {
        didSet { changed() }
    }
    @Published private(set) var presetName: String
    @Published private(set) var customPresets: [EQPreset]

    /// Called whenever the sound should change.
    var onChange: (() -> Void)?

    private var isApplyingPreset = false
    private let defaults = UserDefaults.standard

    init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: "eq.enabled") as? Bool ?? false
        let stored = defaults.array(forKey: "eq.gains") as? [Float]
        gains = stored?.count == Self.frequencies.count ? stored! : Array(repeating: 0, count: Self.frequencies.count)
        preamp = defaults.object(forKey: "eq.preamp") as? Float ?? 0
        presetName = defaults.string(forKey: "eq.preset") ?? "Flat"
        if let data = defaults.data(forKey: "eq.custom"), let decoded = try? JSONDecoder().decode([EQPreset].self, from: data) {
            customPresets = decoded
        } else {
            customPresets = []
        }
    }

    var allPresets: [EQPreset] { Self.builtIn + customPresets }

    func apply(_ preset: EQPreset) {
        isApplyingPreset = true
        gains = preset.gains
        isApplyingPreset = false
        presetName = preset.name
        let boost = max(preset.gains.max() ?? 0, 0)
        preamp = -(boost / 2).rounded()
        if !isEnabled, preset.name != "Flat" { isEnabled = true }
        changed()
    }

    func reset() {
        apply(Self.builtIn[0])
    }

    func saveCurrent(as name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !Self.builtIn.contains(where: { $0.name == trimmed }) else { return }
        customPresets.removeAll { $0.name == trimmed }
        customPresets.append(EQPreset(name: trimmed, gains: gains))
        presetName = trimmed
        persist()
    }

    func deletePreset(_ preset: EQPreset) {
        customPresets.removeAll { $0.name == preset.name }
        if presetName == preset.name { presetName = matchingPresetName() }
        persist()
    }

    func configure(_ unit: AVAudioUnitEQ) {
        unit.bypass = !isEnabled
        unit.globalGain = isEnabled ? preamp : 0
        for (index, band) in unit.bands.enumerated() where index < Self.frequencies.count {
            band.filterType = index == 0 ? .lowShelf : (index == Self.frequencies.count - 1 ? .highShelf : .parametric)
            band.frequency = Self.frequencies[index]
            band.bandwidth = 1.0
            band.gain = gains[index]
            band.bypass = false
        }
    }

    private func matchingPresetName() -> String {
        allPresets.first(where: { $0.gains == gains })?.name ?? "Custom"
    }

    private func changed() {
        persist()
        onChange?()
    }

    private func persist() {
        defaults.set(isEnabled, forKey: "eq.enabled")
        defaults.set(gains, forKey: "eq.gains")
        defaults.set(preamp, forKey: "eq.preamp")
        defaults.set(presetName, forKey: "eq.preset")
        if let data = try? JSONEncoder().encode(customPresets) {
            defaults.set(data, forKey: "eq.custom")
        }
    }

    nonisolated static func label(for frequency: Float) -> String {
        frequency >= 1000 ? "\(Int(frequency / 1000))k" : "\(Int(frequency))"
    }
}
