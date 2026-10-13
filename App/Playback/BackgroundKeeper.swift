import AVFoundation
import Foundation

/// Keeps the app alive in the background while transfers run and no music is playing, by playing
/// silence that mixes with other apps' audio — the same trick iTorrent uses. Without it iOS
/// suspends the app a few seconds after you leave it and Soulseek transfers freeze.
/// App Store review would reject this; it's fine for a sideloaded app. Costs some battery.
@MainActor
final class BackgroundKeeper {
    private var silence: AVAudioPlayer?
    private(set) var isRunning = false

    func start() {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        if silence == nil {
            silence = try? AVAudioPlayer(data: Self.silentWAV())
            silence?.numberOfLoops = -1
            silence?.volume = 0
        }
        isRunning = silence?.play() ?? false
    }

    func stop() {
        guard isRunning else { return }
        silence?.stop()
        isRunning = false
    }

    /// One second of 8 kHz, 16-bit mono silence as an in-memory WAV file.
    private static func silentWAV() -> Data {
        let sampleRate: UInt32 = 8000
        let dataSize: UInt32 = sampleRate * 2
        var data = Data()
        func append(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        append("RIFF"); append32(36 + dataSize); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(1)
        append32(sampleRate); append32(sampleRate * 2); append16(2); append16(16)
        append("data"); append32(dataSize)
        data.append(Data(count: Int(dataSize)))
        return data
    }
}
