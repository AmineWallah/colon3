import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

@MainActor
protocol Scrobbler: AnyObject {
    func nowPlaying(_ track: Track)
    func scrobble(_ track: Track, startedAt: Date)
}

enum RepeatMode: CaseIterable {
    case off, all, one
}

/// Playback position, split out of Player so its 5-per-second updates only redraw the views
/// that show it (progress bar, lyrics) instead of everything observing the player.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var position: Double = 0
}

@MainActor
final class Player: ObservableObject {
    @Published private(set) var queue: [Track] = []
    @Published private(set) var index = 0
    @Published private(set) var isPlaying = false
    let clock: PlaybackClock
    var position: Double { clock.position }
    @Published private(set) var duration: Double = 0
    @Published private(set) var artwork: UIImage?
    @Published private(set) var isSpatialPlayback = false
    @Published private(set) var shuffle = false
    @Published var repeatMode: RepeatMode = .off

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }
    var upNext: ArraySlice<Track> { queue.indices.contains(index) ? queue[(index + 1)...] : [] }

    let equalizer: Equalizer
    weak var library: LibraryStore?
    weak var scrobbler: Scrobbler?

    private let engine: EngineBackend
    private let avPlayer: AVPlayerBackend
    private var backend: PlaybackBackend?
    private var unshuffledQueue: [Track] = []
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    // Scrobbling: count real listening time, not position, so seeking doesn't cheat.
    private var listened: Double = 0
    private var startedAt = Date()
    private var scrobbled = false

    init(equalizer: Equalizer) {
        self.equalizer = equalizer
        clock = PlaybackClock()
        engine = EngineBackend()
        avPlayer = AVPlayerBackend()
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        try? session.setSupportsMultichannelContent(true)

        equalizer.onChange = { [weak self] in
            guard let self else { return }
            self.equalizer.configure(self.engine.eq)
        }
        equalizer.configure(engine.eq)

        for backend in [engine, avPlayer] as [PlaybackBackend] {
            backend.onFinish = { [weak self] in self?.trackFinished() }
        }
        configureRemoteCommands()

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let info = note.userInfo
            MainActor.assumeIsolated { self?.handleInterruption(info) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                // Headphones unplugged: pause, like every music app.
                if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self?.pause() }
            }
        })
    }

    // MARK: Queue

    func play(_ tracks: [Track], startAt startIndex: Int = 0, shuffled: Bool = false) {
        guard tracks.indices.contains(startIndex) else { return }
        if shuffled {
            var rest = tracks
            let first = rest.remove(at: Int.random(in: 0..<rest.count))
            unshuffledQueue = tracks
            queue = [first] + rest.shuffled()
            shuffle = true
        } else {
            unshuffledQueue = tracks
            queue = tracks
            shuffle = false
        }
        index = shuffled ? 0 : startIndex
        loadCurrent(autoplay: true)
    }

    func playNext(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        if queue.isEmpty { return play(tracks) }
        queue.insert(contentsOf: tracks, at: index + 1)
        unshuffledQueue += tracks
    }

    func addToQueue(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        if queue.isEmpty { return play(tracks) }
        queue += tracks
        unshuffledQueue += tracks
    }

    func jump(to queueIndex: Int) {
        guard queue.indices.contains(queueIndex) else { return }
        index = queueIndex
        loadCurrent(autoplay: true)
    }

    func removeFromQueue(at offsets: IndexSet) {
        // Offsets are relative to `upNext`.
        let absolute = IndexSet(offsets.map { $0 + index + 1 })
        let removed = absolute.compactMap { queue.indices.contains($0) ? queue[$0] : nil }
        queue.remove(atOffsets: absolute)
        for track in removed {
            if let position = unshuffledQueue.firstIndex(of: track) { unshuffledQueue.remove(at: position) }
        }
    }

    func moveInQueue(from offsets: IndexSet, to destination: Int) {
        var upcoming = Array(upNext)
        upcoming.move(fromOffsets: offsets, toOffset: destination)
        queue = Array(queue[...index]) + upcoming
    }

    func toggleShuffle() {
        guard let current else {
            shuffle.toggle()
            return
        }
        if shuffle {
            queue = unshuffledQueue
            index = queue.firstIndex(of: current) ?? 0
            shuffle = false
        } else {
            unshuffledQueue = queue
            var rest = queue
            rest.remove(at: index)
            queue = [current] + rest.shuffled()
            index = 0
            shuffle = true
        }
    }

    func cycleRepeat() {
        let all = RepeatMode.allCases
        repeatMode = all[(all.firstIndex(of: repeatMode)! + 1) % all.count]
    }

    /// Deleted files must leave the queue so playback never hits a missing URL.
    func remove(_ tracks: [Track]) {
        let doomed = Set(tracks.map(\.id))
        let wasCurrent = current.map { doomed.contains($0.id) } ?? false
        let before = queue[..<min(index, queue.count)].filter { doomed.contains($0.id) }.count
        queue.removeAll { doomed.contains($0.id) }
        unshuffledQueue.removeAll { doomed.contains($0.id) }
        index = max(0, index - before)
        if queue.isEmpty {
            stop()
        } else if wasCurrent {
            index = min(index, queue.count - 1)
            loadCurrent(autoplay: isPlaying)
        }
    }

    // MARK: Transport

    func togglePlayPause() {
        if isPlaying { pause() } else { resume() }
    }

    func resume() {
        guard let backend, current != nil else { return }
        let session = AVAudioSession.sharedInstance()
        // The background keeper may have switched the session to mix-with-others; take it back.
        try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        try? session.setActive(true)
        backend.play()
        isPlaying = backend.isPlaying || backend === avPlayer
        startTimer()
        updateNowPlaying()
    }

    func pause() {
        backend?.pause()
        isPlaying = false
        clock.position = backend?.currentTime ?? position
        updateNowPlaying()
    }

    func next() {
        if index + 1 < queue.count {
            index += 1
            loadCurrent(autoplay: true)
        } else if repeatMode == .all, !queue.isEmpty {
            index = 0
            loadCurrent(autoplay: true)
        } else {
            pause()
            seek(to: 0)
        }
    }

    func previous() {
        if position > 3 || index == 0 {
            seek(to: 0)
        } else {
            index -= 1
            loadCurrent(autoplay: isPlaying)
        }
    }

    func seek(to seconds: Double) {
        backend?.seek(to: seconds)
        clock.position = seconds
        updateNowPlaying()
    }

    func stop() {
        backend?.stop()
        backend = nil
        queue = []
        unshuffledQueue = []
        index = 0
        isPlaying = false
        clock.position = 0
        duration = 0
        artwork = nil
        timer?.invalidate()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    var artworkSource: ArtworkSource? {
        guard let current else { return nil }
        return library?.artwork(for: current) ?? .track(current)
    }

    // MARK: Internals

    private func loadCurrent(autoplay: Bool) {
        guard let track = current else { return }
        backend?.stop()

        var chosen: PlaybackBackend = track.isSpatial ? avPlayer : engine
        do {
            try chosen.load(track.url)
        } catch {
            // AVAudioFile can't open everything AVPlayer can; fall back rather than fail.
            chosen = avPlayer
            try? chosen.load(track.url)
        }
        backend = chosen
        isSpatialPlayback = chosen === avPlayer
        clock.position = 0
        duration = chosen.duration > 0 ? chosen.duration : track.duration
        listened = 0
        startedAt = Date()
        scrobbled = false
        artwork = nil

        if autoplay {
            resume()
        } else {
            isPlaying = false
            updateNowPlaying()
        }
        scrobbler?.nowPlaying(track)

        let id = track.id
        if let source = artworkSource {
            Task {
                let image = await ArtworkStore.shared.image(for: source, maxPixel: 1200)
                guard self.current?.id == id else { return }
                self.artwork = image
                self.updateNowPlaying()
            }
        }
    }

    private func trackFinished() {
        maybeScrobble(force: true)
        if repeatMode == .one {
            seek(to: 0)
            resume()
        } else {
            next()
        }
    }

    private func startTimer() {
        guard timer == nil || timer?.isValid == false else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard let backend else { return }
        if isPlaying {
            clock.position = backend.currentTime
            listened += 0.2
            maybeScrobble(force: false)
            if duration <= 0, backend.duration > 0 { duration = backend.duration }
        } else if timer != nil {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Last.fm rules: tracks over 30 s count after half their length or 4 minutes.
    private func maybeScrobble(force: Bool) {
        guard !scrobbled, let track = current, duration > 30 else { return }
        let threshold = min(duration / 2, 240)
        if listened >= threshold || (force && listened >= threshold * 0.9) {
            scrobbled = true
            scrobbler?.scrobble(track, startedAt: startedAt)
        }
    }

    private func handleInterruption(_ info: [AnyHashable: Any]?) {
        guard let raw = info?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            backend?.pause()
            isPlaying = false
            updateNowPlaying()
        case .ended:
            let optionsRaw = info?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            if AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume) { resume() }
        @unknown default:
            break
        }
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let target = event.positionTime
            Task { @MainActor in self?.seek(to: target) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let track = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let album = library?.album(containing: track)?.title ?? track.album {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        if let image = artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
