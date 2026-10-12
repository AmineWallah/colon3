import AVFoundation
import MediaPlayer
import UIKit

final class Player: ObservableObject {
    @Published private(set) var queue: [Track] = []
    @Published private(set) var index = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var artwork: UIImage?

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var observers: [NSObjectProtocol] = []

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        configureRemoteCommands()

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                                                      queue: .main) { [weak self] time in
            self?.tick(time)
        }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
            self.next()
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            self?.handleInterruption(note)
        })
    }

    // MARK: Controls

    func play(_ tracks: [Track], startAt startIndex: Int) {
        guard tracks.indices.contains(startIndex) else { return }
        queue = tracks
        index = startIndex
        loadCurrent(autoplay: true)
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    func resume() {
        guard current != nil else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        player.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func next() {
        if index + 1 < queue.count {
            index += 1
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
            loadCurrent(autoplay: true)
        }
    }

    func seek(to seconds: Double) {
        position = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        updateNowPlaying()
    }

    /// Drops a deleted file from the queue so playback doesn't hit a missing URL.
    func remove(_ track: Track) {
        guard let removed = queue.firstIndex(of: track) else { return }
        let wasCurrent = removed == index
        queue.remove(at: removed)
        if removed < index { index -= 1 }
        if wasCurrent {
            if queue.isEmpty {
                player.replaceCurrentItem(with: nil)
                isPlaying = false
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            } else {
                index = min(index, queue.count - 1)
                loadCurrent(autoplay: isPlaying)
            }
        }
    }

    // MARK: Internals

    private func loadCurrent(autoplay: Bool) {
        guard let track = current else { return }
        player.replaceCurrentItem(with: AVPlayerItem(url: track.url))
        position = 0
        duration = track.duration
        artwork = nil
        if autoplay { resume() } else { updateNowPlaying() }

        let url = track.url
        Task {
            let data = await Library.artwork(for: url)
            await MainActor.run {
                guard self.current?.url == url else { return }
                self.artwork = data.flatMap(UIImage.init(data:))
                self.updateNowPlaying()
            }
        }
    }

    private func tick(_ time: CMTime) {
        guard time.isNumeric else { return }
        position = time.seconds
        if let itemDuration = player.currentItem?.duration, itemDuration.isNumeric, itemDuration.seconds > 0 {
            duration = itemDuration.seconds
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            isPlaying = false
            updateNowPlaying()
        case .ended:
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            if AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume) { resume() }
        @unknown default:
            break
        }
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            self?.resume()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.next()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.previous()
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: event.positionTime)
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
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let image = artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
