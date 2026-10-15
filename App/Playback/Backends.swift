import AVFoundation
import Foundation

@MainActor
protocol PlaybackBackend: AnyObject {
    /// Called when the current file plays to the end.
    var onFinish: (() -> Void)? { get set }
    var duration: Double { get }
    var currentTime: Double { get }
    var isPlaying: Bool { get }
    /// Playback speed, 0.5–2. Pitch stays natural.
    var rate: Float { get set }
    func load(_ url: URL) throws
    func play()
    func pause()
    func seek(to seconds: Double)
    func stop()
}

/// A file whose format EngineBackend won't put through its graph (it plays through AVPlayer).
struct UnsupportedFormat: LocalizedError {
    let channels: UInt32
    let sampleRate: Double
    let frames: Int64
    var errorDescription: String? {
        "the engine can't take \(channels) ch at \(Int(sampleRate)) Hz (\(frames) frames)"
    }
}

/// Stereo playback through AVAudioEngine so the EQ can sit in the signal path.
///
/// Bit-perfect mode: the EQ is bypassed, every gain stays at unity, and before each song the
/// audio session asks the output for the file's own sample rate. With a USB DAC that accepts the
/// rate, iOS switches the hardware and nothing gets resampled; the only conversions left are
/// integer ↔ float, which are lossless for 16- and 24-bit audio.
@MainActor
final class EngineBackend: PlaybackBackend {
    var onFinish: (() -> Void)?
    /// Called after the output's sample rate or route changed, so the UI can update.
    var onOutputChange: (() -> Void)?
    private(set) var isPlaying = false
    var bitPerfect = false {
        didSet {
            guard bitPerfect != oldValue else { return }
            if bitPerfect, let rate = file?.processingFormat.sampleRate {
                matchHardwareRate(rate)
            } else if !bitPerfect {
                // Back to the usual 48 kHz so other apps' audio isn't resampled oddly.
                restoreDefaultRate()
            }
        }
    }

    private var engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    /// Speed change without pitch change. Bypassed at 1×, so normal (and bit-perfect) playback
    /// never goes through it.
    private let timePitch = AVAudioUnitTimePitch()
    let eq = AVAudioUnitEQ(numberOfBands: Equalizer.maxBands)

    var rate: Float = 1 {
        didSet {
            timePitch.rate = rate
            timePitch.bypass = abs(rate - 1) < 0.001
        }
    }

    private var file: AVAudioFile?
    private var connectedFormat: AVAudioFormat?
    private var segmentStart: AVAudioFramePosition = 0
    private var generation = 0
    private var lastTime: Double = 0
    private var configObserver: NSObjectProtocol?

    init() {
        attachGraph()
    }

    var duration: Double {
        guard let file else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    var fileSampleRate: Double { file?.processingFormat.sampleRate ?? 0 }

    var currentTime: Double {
        guard let file else { return 0 }
        guard isPlaying, let nodeTime = node.lastRenderTime, nodeTime.isSampleTimeValid,
              let playerTime = node.playerTime(forNodeTime: nodeTime) else { return lastTime }
        let seconds = Double(segmentStart + playerTime.sampleTime) / file.processingFormat.sampleRate
        lastTime = min(max(seconds, 0), duration)
        return lastTime
    }

    /// Formats the engine graph (time-pitch, EQ) is known to take. AVAudioEngine reports a bad
    /// format by raising an Objective-C exception, which Swift can't catch and which kills the
    /// app, so anything else is refused here and the player falls back to AVPlayer.
    private static func engineCanPlay(_ format: AVAudioFormat) -> Bool {
        (1...2).contains(format.channelCount) && (8_000...192_000).contains(format.sampleRate)
    }

    func load(_ url: URL) throws {
        let newFile = try AVAudioFile(forReading: url)
        let format = newFile.processingFormat
        guard newFile.length > 0, Self.engineCanPlay(format) else {
            throw UnsupportedFormat(channels: format.channelCount, sampleRate: format.sampleRate, frames: newFile.length)
        }
        stopNode()
        file = newFile
        if bitPerfect { matchHardwareRate(format.sampleRate) }
        if connectedFormat == nil {
            connect(format)
        } else if connectedFormat?.sampleRate != format.sampleRate || connectedFormat?.channelCount != format.channelCount {
            // Re-linking a graph that's already wired at another rate makes AVAudioEngine raise
            // (the time-pitch unit's input and output rates would disagree mid-way), which kills
            // the app. A fresh engine wired for the new format avoids that.
            rebuildEngine()
        }
        lastTime = 0
        schedule(fromFrame: 0)
    }

    func play() {
        guard file != nil else { return }
        do {
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
            node.play()
            isPlaying = true
        } catch {
            isPlaying = false
        }
    }

    func pause() {
        lastTime = currentTime
        node.pause()
        isPlaying = false
    }

    func seek(to seconds: Double) {
        guard let file else { return }
        let wasPlaying = isPlaying
        let clamped = min(max(seconds, 0), duration)
        stopNode()
        lastTime = clamped
        schedule(fromFrame: AVAudioFramePosition(clamped * file.processingFormat.sampleRate))
        if wasPlaying { play() }
    }

    func stop() {
        stopNode()
        file = nil
        lastTime = 0
        engine.pause()
    }

    // MARK: Graph

    private func attachGraph() {
        engine.attach(node)
        engine.attach(timePitch)
        engine.attach(eq)
        timePitch.rate = rate
        timePitch.bypass = abs(rate - 1) < 0.001
        node.volume = 1
        engine.mainMixerNode.outputVolume = 1
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.recoverFromConfigurationChange() }
        }
    }

    /// Wires player → time-pitch → EQ → mixer on an engine with nothing connected yet. Linked
    /// from the mixer backwards, so every link's far end already runs at `format`.
    private func connect(_ format: AVAudioFormat) {
        engine.connect(eq, to: engine.mainMixerNode, format: format)
        engine.connect(timePitch, to: eq, format: format)
        engine.connect(node, to: timePitch, format: format)
        connectedFormat = format
    }

    /// A fresh engine picks up the hardware's current format for its mixer → output link,
    /// which is the reliable way to follow a sample-rate switch.
    private func rebuildEngine() {
        engine.stop()
        engine.detach(node)
        engine.detach(timePitch)
        engine.detach(eq)
        engine = AVAudioEngine()
        connectedFormat = nil
        attachGraph()
        if let format = file?.processingFormat { connect(format) }
    }

    /// Asks the output for `rate`. Returns whether the engine had to be rebuilt.
    @discardableResult
    private func matchHardwareRate(_ rate: Double) -> Bool {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(true)
        guard abs(session.sampleRate - rate) > 1 else { return false }
        try? session.setPreferredSampleRate(rate)
        // The switch is usually immediate; rebuild so the mixer runs at the new rate too.
        let wasPlaying = isPlaying
        let position = lastTime
        stopNode()
        rebuildEngine()
        if file != nil, wasPlaying {
            lastTime = position
            seek(to: position)
            play()
        }
        onOutputChange?()
        return true
    }

    private func restoreDefaultRate() {
        let session = AVAudioSession.sharedInstance()
        guard abs(session.sampleRate - 48_000) > 1 else { return }
        try? session.setPreferredSampleRate(48_000)
        // The configuration-change notification handles the rest.
    }

    private func stopNode() {
        generation += 1
        node.stop()
        isPlaying = false
    }

    private func schedule(fromFrame frame: AVAudioFramePosition) {
        guard let file else { return }
        generation += 1
        let token = generation
        segmentStart = frame
        let remaining = file.length - frame
        guard remaining > 0 else {
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.isPlaying = false
                self.onFinish?()
            }
            return
        }
        node.scheduleSegment(file, startingFrame: frame, frameCount: AVAudioFrameCount(remaining), at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                // Stopping the node (seek, new track) also fires this; the generation check ignores those.
                guard let self, self.generation == token else { return }
                self.isPlaying = false
                self.onFinish?()
            }
        }
    }

    /// Route or sample-rate changes (headphones, DACs, AirPlay, Bluetooth) stop the engine;
    /// rebuild it for the new output and pick up where we were.
    private func recoverFromConfigurationChange() {
        defer { onOutputChange?() }
        guard file != nil else {
            rebuildEngine()
            return
        }
        let wasPlaying = isPlaying
        let position = lastTime
        stopNode()
        if bitPerfect, let rate = file?.processingFormat.sampleRate {
            try? AVAudioSession.sharedInstance().setPreferredSampleRate(rate)
        }
        rebuildEngine()
        isPlaying = wasPlaying
        seek(to: position)  // reschedules, and restarts playback if we were playing
    }
}

/// AVPlayer for multichannel / Dolby Atmos files, so iOS can render them spatially
/// (with head tracking on AirPods). No EQ here.
@MainActor
final class AVPlayerBackend: PlaybackBackend {
    var onFinish: (() -> Void)?
    private let player = AVPlayer()
    private var endObserver: NSObjectProtocol?

    var isPlaying: Bool { player.rate > 0 }

    var rate: Float = 1 {
        didSet {
            player.defaultRate = rate
            if player.rate > 0 { player.rate = rate }
        }
    }

    var duration: Double {
        guard let duration = player.currentItem?.duration, duration.isNumeric else { return 0 }
        return duration.seconds
    }

    var currentTime: Double {
        let time = player.currentTime()
        return time.isNumeric ? time.seconds : 0
    }

    func load(_ url: URL) throws {
        let item = AVPlayerItem(url: url)
        item.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        item.audioTimePitchAlgorithm = .spectral  // keeps voices natural when sped up or slowed
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onFinish?() }
        }
        player.replaceCurrentItem(with: item)
    }

    func play() {
        player.defaultRate = rate
        player.play()
    }
    func pause() { player.pause() }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        player.pause()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.replaceCurrentItem(with: nil)
    }
}
