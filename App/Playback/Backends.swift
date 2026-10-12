import AVFoundation
import Foundation

@MainActor
protocol PlaybackBackend: AnyObject {
    /// Called when the current file plays to the end.
    var onFinish: (() -> Void)? { get set }
    var duration: Double { get }
    var currentTime: Double { get }
    var isPlaying: Bool { get }
    func load(_ url: URL) throws
    func play()
    func pause()
    func seek(to seconds: Double)
    func stop()
}

/// Stereo playback through AVAudioEngine so the EQ can sit in the signal path.
@MainActor
final class EngineBackend: PlaybackBackend {
    var onFinish: (() -> Void)?
    private(set) var isPlaying = false

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    let eq = AVAudioUnitEQ(numberOfBands: Equalizer.frequencies.count)

    private var file: AVAudioFile?
    private var connectedFormat: AVAudioFormat?
    private var segmentStart: AVAudioFramePosition = 0
    private var generation = 0
    private var lastTime: Double = 0
    private var configObserver: NSObjectProtocol?

    init() {
        engine.attach(node)
        engine.attach(eq)
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.recoverFromConfigurationChange() }
        }
    }

    var duration: Double {
        guard let file else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    var currentTime: Double {
        guard let file else { return 0 }
        guard isPlaying, let nodeTime = node.lastRenderTime, nodeTime.isSampleTimeValid,
              let playerTime = node.playerTime(forNodeTime: nodeTime) else { return lastTime }
        let seconds = Double(segmentStart + playerTime.sampleTime) / file.processingFormat.sampleRate
        lastTime = min(max(seconds, 0), duration)
        return lastTime
    }

    func load(_ url: URL) throws {
        let newFile = try AVAudioFile(forReading: url)
        stopNode()
        file = newFile
        let format = newFile.processingFormat
        if connectedFormat?.sampleRate != format.sampleRate || connectedFormat?.channelCount != format.channelCount {
            engine.connect(node, to: eq, format: format)
            engine.connect(eq, to: engine.mainMixerNode, format: format)
            connectedFormat = format
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

    /// Route changes (headphones, AirPlay, Bluetooth) stop the engine; pick up where we were.
    private func recoverFromConfigurationChange() {
        guard file != nil else { return }
        let wasPlaying = isPlaying
        let position = lastTime
        isPlaying = false
        connectedFormat = nil
        if let format = file?.processingFormat {
            engine.connect(node, to: eq, format: format)
            engine.connect(eq, to: engine.mainMixerNode, format: format)
            connectedFormat = format
        }
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
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onFinish?() }
        }
        player.replaceCurrentItem(with: item)
    }

    func play() { player.play() }
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
