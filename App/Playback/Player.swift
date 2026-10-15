import AVFoundation
import Combine
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
    @Published var repeatMode: RepeatMode = .off {
        didSet { if repeatMode != oldValue { refreshAutoplay() } }
    }
    /// Keep playing similar songs from the library when the queue runs out. Saved in Settings.
    @Published var autoplay: Bool {
        didSet {
            UserDefaults.standard.set(autoplay, forKey: AppSettings.autoplayKey)
            if autoplay != oldValue { refreshAutoplay() }
        }
    }
    /// Only pick songs already in the library (no Soulseek downloads). Saved in Settings.
    @Published var autoplayLibraryOnly: Bool {
        didSet {
            UserDefaults.standard.set(autoplayLibraryOnly, forKey: AppSettings.autoplayLibraryOnlyKey)
            if autoplayLibraryOnly != oldValue {
                autoplaySeedID = nil  // Rebuild the list under the new rule.
                refreshAutoplay()
            }
        }
    }
    /// What autoplay will play after the queue, shown under Up Next. Not part of `queue` until
    /// each song's turn comes, so editing the queue never mixes the two up.
    @Published private(set) var autoplayUpcoming: [AutoplayItem] = []
    @Published private(set) var isFindingAutoplay = false
    /// Why autoplay isn't finding songs outside the library right now (shown under Up Next).
    @Published private(set) var autoplayNote: String?
    /// Bit-perfect mode for USB DACs (see EngineBackend). Saved in Settings.
    @Published var bitPerfect: Bool {
        didSet {
            UserDefaults.standard.set(bitPerfect, forKey: AppSettings.bitPerfectKey)
            engine.bitPerfect = bitPerfect
            applyEqualizer()
            refreshOutputInfo()
        }
    }
    @Published private(set) var output = OutputInfo()
    /// Playback speed (0.5–2×), kept across launches.
    @Published var playbackRate: Float {
        didSet {
            // Assigning inside didSet doesn't re-trigger it, so clamp and carry on.
            let clamped = min(max(playbackRate, Self.rateRange.lowerBound), Self.rateRange.upperBound)
            if clamped != playbackRate { playbackRate = clamped }
            UserDefaults.standard.set(playbackRate, forKey: "playback.rate")
            engine.rate = playbackRate
            avPlayer.rate = playbackRate
            updateNowPlaying()
            refreshOutputInfo()
        }
    }
    nonisolated static let rateRange: ClosedRange<Float> = 0.5...2
    nonisolated static let ratePresets: [Float] = [0.5, 0.75, 1, 1.5, 2]
    /// Fires whenever what's playing, play/pause or the position jumps (widgets, observers).
    let stateChanged = PassthroughSubject<Void, Never>()

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }
    var upNext: ArraySlice<Track> { queue.indices.contains(index) ? queue[(index + 1)...] : [] }

    let equalizer: Equalizer
    weak var library: LibraryStore? {
        didSet { recommender.library = library }
    }
    weak var scrobbler: Scrobbler?
    weak var stats: StatsStore? {
        didSet { recommender.stats = stats }
    }
    /// Downloads autoplay discoveries from Soulseek. Without it autoplay stays in the library.
    var fetcher: SongFetcher?
    /// Called with each song autoplay downloaded (the app adds it to a playlist).
    var onAutoplayDownload: ((Track) -> Void)?

    private let engine: EngineBackend
    private let avPlayer: AVPlayerBackend
    private var backend: PlaybackBackend?
    private var unshuffledQueue: [Track] = []
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    private let recommender = AutoplayRecommender()
    /// The song autoplay's current list follows on from (the end of the queue when it was made).
    private var autoplaySeedID: String?
    private var autoplayTask: Task<Void, Never>?
    /// The queue ended before autoplay had anything ready; start as soon as it does.
    private var advanceWhenAutoplayReady = false
    /// Recently played ids, oldest first, kept across launches so autoplay doesn't repeat them.
    private var recentlyPlayed: [String]
    private static let recentLimit = 200
    /// Discoveries being fetched, by item id.
    private var discoveryTasks: [String: Task<Void, Never>] = [:]
    /// Songs Soulseek didn't have this session; not suggested again.
    private var failedDiscoveries = Set<String>()
    /// Discoveries fetched at once, in list order. Keeps downloads close to what plays next.
    private static let discoveriesAhead = 2
    /// Whether the current list was made while discoveries were possible. A list made before
    /// Soulseek connected (or before a Last.fm key was added) is rebuilt once they are.
    private var autoplayListAllowsDiscovery = false

    // Scrobbling: count real listening time, not position, so seeking doesn't cheat.
    private var listened: Double = 0
    private var startedAt = Date()
    private var scrobbled = false
    private var countedPlay = false

    init(equalizer: Equalizer) {
        self.equalizer = equalizer
        clock = PlaybackClock()
        engine = EngineBackend()
        avPlayer = AVPlayerBackend()
        bitPerfect = UserDefaults.standard.bool(forKey: AppSettings.bitPerfectKey)
        let savedRate = UserDefaults.standard.object(forKey: "playback.rate") as? Float ?? 1
        playbackRate = min(max(savedRate, Self.rateRange.lowerBound), Self.rateRange.upperBound)
        autoplay = AppSettings.flag(AppSettings.autoplayKey)
        autoplayLibraryOnly = UserDefaults.standard.bool(forKey: AppSettings.autoplayLibraryOnlyKey)
        recentlyPlayed = UserDefaults.standard.stringArray(forKey: "autoplay.recent") ?? []
        engine.bitPerfect = bitPerfect
        engine.rate = playbackRate
        avPlayer.rate = playbackRate
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        try? session.setSupportsMultichannelContent(true)

        equalizer.onChange = { [weak self] in self?.applyEqualizer() }
        applyEqualizer()
        engine.onOutputChange = { [weak self] in self?.refreshOutputInfo() }

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
                self?.refreshOutputInfo()
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
        refreshAutoplay()
    }

    func addToQueue(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        if queue.isEmpty { return play(tracks) }
        queue += tracks
        unshuffledQueue += tracks
        refreshAutoplay()
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
        refreshAutoplay()
    }

    func moveInQueue(from offsets: IndexSet, to destination: Int) {
        var upcoming = Array(upNext)
        upcoming.move(fromOffsets: offsets, toOffset: destination)
        queue = Array(queue[...index]) + upcoming
        refreshAutoplay()
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
        refreshAutoplay()
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
        setAutoplayUpcoming(autoplayUpcoming.filter { item in item.track.map { !doomed.contains($0.id) } ?? true })
        index = max(0, index - before)
        if queue.isEmpty {
            stop()
        } else if wasCurrent {
            index = min(index, queue.count - 1)
            loadCurrent(autoplay: isPlaying)
        } else {
            refreshAutoplay()
        }
    }

    // MARK: Autoplay

    /// Plays a ready autoplay song now. Past the end of the queue, ready songs before it are
    /// skipped (discoveries still downloading stay for later); with songs still queued it plays
    /// next-up and the rest of the queue follows.
    func playAutoplay(at offset: Int) {
        guard autoplayUpcoming.indices.contains(offset), let track = autoplayUpcoming[offset].track else { return }
        var items = autoplayUpcoming
        items.remove(at: offset)
        if upNext.isEmpty {
            let skipped = Set(items.prefix(offset).filter { $0.track != nil }.map(\.id))
            items.removeAll { skipped.contains($0.id) }
            queue.append(track)
            unshuffledQueue.append(track)
            // What's left of the list follows on from this song. A fetch for the old end of the
            // queue would be thrown away when it lands, so stop it; loadCurrent tops up again.
            autoplaySeedID = track.id
            autoplayTask?.cancel()
            autoplayTask = nil
            isFindingAutoplay = false
            index = queue.count - 1
        } else {
            queue.insert(track, at: index + 1)
            unshuffledQueue.append(track)
            index += 1
        }
        setAutoplayUpcoming(items)
        loadCurrent(autoplay: true)
    }

    func removeAutoplay(at offsets: IndexSet) {
        var items = autoplayUpcoming
        items.remove(atOffsets: offsets)
        setAutoplayUpcoming(items)
        refreshAutoplay()
    }

    /// Every change to the list goes through here: fetches for discoveries that left the list
    /// are cancelled, and the next discoveries start downloading.
    private func setAutoplayUpcoming(_ items: [AutoplayItem]) {
        let kept = Set(items.map(\.id))
        for (id, task) in discoveryTasks where !kept.contains(id) {
            task.cancel()
            discoveryTasks[id] = nil
        }
        if items != autoplayUpcoming { autoplayUpcoming = items }
        pumpDiscoveries()
    }

    /// Keeps the autoplay list in step with the queue: rebuilt when the queue's last song changes,
    /// topped up when it runs low, cleared when autoplay can't apply (off, repeat, nothing queued).
    private func refreshAutoplay() {
        guard autoplay, repeatMode == .off, let last = queue.last else {
            autoplayTask?.cancel()
            autoplayTask = nil
            autoplaySeedID = nil
            advanceWhenAutoplayReady = false
            setAutoplayUpcoming([])
            if isFindingAutoplay { isFindingAutoplay = false }
            if autoplayNote != nil { autoplayNote = nil }
            return
        }
        if last.id != autoplaySeedID {
            autoplaySeedID = last.id
            setAutoplayUpcoming([])
            fetchAutoplay(after: AutoplaySeed(last))
        } else if !autoplayListAllowsDiscovery, autoplayTask == nil, discoveryCheck().allowed,
                  !autoplayUpcoming.contains(where: \.isDiscovery) {
            setAutoplayUpcoming([])
            fetchAutoplay(after: AutoplaySeed(last))
        } else if autoplayUpcoming.count < 4, autoplayTask == nil {
            fetchAutoplay(after: autoplayUpcoming.last.map { AutoplaySeed($0.song) } ?? AutoplaySeed(last))
        }
    }

    private func fetchAutoplay(after seed: AutoplaySeed) {
        autoplayTask?.cancel()
        let seedID = autoplaySeedID
        let wanted = max(10 - autoplayUpcoming.count, 1)
        let discovery = discoveryCheck()
        if autoplayUpcoming.isEmpty { autoplayListAllowsDiscovery = discovery.allowed }
        let maxDiscoveries = discovery.allowed ? (wanted + 1) / 2 : 0
        autoplayNote = discovery.note
        isFindingAutoplay = true
        autoplayTask = Task { [weak self] in
            guard let self else { return }
            var picks = await self.recommender.recommendations(
                after: seed, count: wanted, excludedTracks: self.autoplayExclusions(strict: true),
                excludedSongs: self.discoveryExclusions(), maxDiscoveries: maxDiscoveries)
            guard !Task.isCancelled, self.autoplaySeedID == seedID else { return }
            if picks.isEmpty {
                // Small library: everything was played recently. Repeat rather than stop.
                picks = await self.recommender.recommendations(
                    after: seed, count: wanted, excludedTracks: self.autoplayExclusions(strict: false),
                    excludedSongs: self.discoveryExclusions(), maxDiscoveries: maxDiscoveries)
                guard !Task.isCancelled, self.autoplaySeedID == seedID else { return }
            }
            if discovery.allowed, self.recommender.lastSimilarCount == 0 {
                self.autoplayNote = "Last.fm has no similar songs for this one, so these are from your library."
            }
            let present = Set(self.autoplayUpcoming.map(\.id))
            self.autoplayTask = nil
            self.isFindingAutoplay = false
            self.setAutoplayUpcoming(self.autoplayUpcoming + picks.filter { !present.contains($0.id) })
            self.advanceIfWaiting()
        }
    }

    /// Starts fetching the first discoveries in the list that aren't ready yet.
    private func pumpDiscoveries() {
        guard let fetcher else { return }
        var inFlight = discoveryTasks.count
        for item in autoplayUpcoming where inFlight < Self.discoveriesAhead
            && item.isDiscovery && item.track == nil && discoveryTasks[item.id] == nil {
            inFlight += 1
            let id = item.id
            let song = item.song
            discoveryTasks[id] = Task { [weak self] in
                let outcome = await fetcher.fetch(song, priority: .high) { progress in
                    self?.updateDiscovery(id, progress)
                }
                guard let self, !Task.isCancelled else { return }
                self.discoveryTasks[id] = nil
                self.finishDiscovery(id, outcome)
            }
        }
    }

    private func updateDiscovery(_ id: String, _ progress: SongFetcher.Progress) {
        guard let position = autoplayUpcoming.firstIndex(where: { $0.id == id }),
              autoplayUpcoming[position].track == nil else { return }
        switch progress {
        case .searching:
            autoplayUpcoming[position].state = .searching
        case let .downloading(fraction, _):
            autoplayUpcoming[position].state = .downloading(fraction)
        }
    }

    private func finishDiscovery(_ id: String, _ outcome: SongFetcher.Outcome) {
        guard let position = autoplayUpcoming.firstIndex(where: { $0.id == id }) else { return }
        var items = autoplayUpcoming
        switch outcome {
        case let .found(track, downloaded):
            if downloaded { onAutoplayDownload?(track) }
            let duplicate = queue.contains(track) || items.contains { $0.track?.id == track.id }
            if duplicate {
                items.remove(at: position)
            } else {
                items[position].state = .ready(track)
            }
        case let .notFound(reason):
            failedDiscoveries.insert(TrackMatcher.songKey(items[position].song))
            Diagnostics.shared.log("Autoplay: \(items[position].song.title) not found (\(reason))", category: "autoplay")
            items.remove(at: position)
        }
        setAutoplayUpcoming(items)
        refreshAutoplay()
        advanceIfWaiting()
    }

    /// The queue ended while nothing was ready: play the first song that is.
    private func advanceIfWaiting() {
        guard advanceWhenAutoplayReady, upNext.isEmpty,
              let ready = autoplayUpcoming.firstIndex(where: { $0.track != nil }) else { return }
        advanceWhenAutoplayReady = false
        playAutoplay(at: ready)
    }

    /// Songs autoplay shouldn't pick: what's queued or already lined up, and (when strict) what
    /// was played recently. The recent window shrinks with small libraries so there's always
    /// something left to choose from.
    private func autoplayExclusions(strict: Bool) -> Set<String> {
        var ids = Set(autoplayUpcoming.compactMap { $0.track?.id })
        if strict {
            ids.formUnion(queue.map(\.id))
            let window = min(recentlyPlayed.count, Self.recentLimit, (library?.tracks.count ?? 0) / 2)
            ids.formUnion(recentlyPlayed.suffix(window))
        } else {
            ids.formUnion(queue.suffix(3).map(\.id))
        }
        return ids
    }

    /// Whether autoplay may download songs, and if not (and the user didn't choose that), why.
    private func discoveryCheck() -> (allowed: Bool, note: String?) {
        if autoplayLibraryOnly { return (false, nil) }
        if LastFM.publicAPIKey == nil {
            return (false, "Connect Last.fm in Settings to also get songs you don't have.")
        }
        guard let fetcher, fetcher.isAvailable else {
            return (false, "Log in to Soulseek to also get songs you don't have.")
        }
        return (true, nil)
    }

    /// Songs not to discover: already lined up, or not on Soulseek earlier.
    private func discoveryExclusions() -> Set<String> {
        failedDiscoveries.union(autoplayUpcoming.map { TrackMatcher.songKey($0.song) })
    }

    private func notePlayed(_ track: Track) {
        recentlyPlayed.removeAll { $0 == track.id }
        recentlyPlayed.append(track.id)
        if recentlyPlayed.count > Self.recentLimit { recentlyPlayed.removeFirst(recentlyPlayed.count - Self.recentLimit) }
        UserDefaults.standard.set(recentlyPlayed, forKey: "autoplay.recent")
    }

    // MARK: Transport

    func togglePlayPause() {
        if isPlaying { pause() } else { resume() }
    }

    func resume() {
        guard let backend, current != nil else { return }
        advanceWhenAutoplayReady = false
        let session = AVAudioSession.sharedInstance()
        // The background keeper may have switched the session to mix-with-others; take it back.
        try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        try? session.setActive(true)
        backend.play()
        isPlaying = backend.isPlaying || backend === avPlayer
        startTimer()
        updateNowPlaying()
        refreshOutputInfo()
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
        } else if autoplay, repeatMode == .off, current != nil {
            if let ready = autoplayUpcoming.firstIndex(where: { $0.track != nil }) {
                playAutoplay(at: ready)
            } else {
                pause()
                seek(to: 0)
                advanceWhenAutoplayReady = true
                refreshAutoplay()
            }
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
        refreshAutoplay()
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
            Diagnostics.shared.log("Playing \(track.id) with AVPlayer: \(error.localizedDescription)", category: "playback")
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
        countedPlay = false
        artwork = nil
        advanceWhenAutoplayReady = false
        notePlayed(track)
        refreshOutputInfo()

        if autoplay {
            resume()
        } else {
            isPlaying = false
            updateNowPlaying()
        }
        scrobbler?.nowPlaying(track)

        reloadArtwork()
        refreshAutoplay()
    }

    /// Reloads the current cover (after a new one was downloaded or picked).
    func reloadArtwork() {
        guard let id = current?.id, let source = artworkSource else { return }
        Task {
            let image = await ArtworkStore.shared.image(for: source, maxPixel: 1200)
            guard self.current?.id == id, image !== self.artwork else { return }
            self.artwork = image
            self.updateNowPlaying()
        }
    }

    private func applyEqualizer() {
        if bitPerfect {
            engine.eq.bypass = true
            engine.eq.globalGain = 0
        } else {
            equalizer.configure(engine.eq)
        }
    }

    /// What the hardware is doing right now, for the Now Playing badge and Settings.
    func refreshOutputInfo() {
        let session = AVAudioSession.sharedInstance()
        let port = session.currentRoute.outputs.first
        let fileRate = backend === engine ? engine.fileSampleRate : 0
        let info = OutputInfo(routeName: port?.portName ?? "",
                              routeKind: OutputInfo.Kind(port?.portType),
                              hardwareRate: session.sampleRate,
                              fileRate: fileRate,
                              usingEngine: backend === engine,
                              speed: playbackRate)
        if info != output { output = info }
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
            if let track = current {
                let album = library?.album(containing: track)?.title ?? track.album
                stats?.addListening(track, album: album, seconds: 0.2)
                // A play counts after 30 s, or half of a shorter song.
                if !countedPlay, listened >= min(30, max(duration, 1) * 0.5) {
                    countedPlay = true
                    stats?.recordPlay(track, album: album)
                }
            }
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
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(playbackRate) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(playbackRate),
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let album = library?.album(containing: track)?.title ?? track.album {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        if let image = artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        stateChanged.send()
    }
}

/// The current audio output, and whether playback reaches it untouched.
struct OutputInfo: Equatable {
    enum Kind: Equatable {
        case wired, bluetooth, airPlay, builtIn, other

        init(_ port: AVAudioSession.Port?) {
            guard let port else {
                self = .other
                return
            }
            if [.usbAudio, .headphones, .lineOut, .HDMI].contains(port) {
                self = .wired
            } else if [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP].contains(port) {
                self = .bluetooth
            } else if port == .airPlay {
                self = .airPlay
            } else if port == .builtInSpeaker || port == .builtInReceiver {
                self = .builtIn
            } else {
                self = .other
            }
        }
    }

    var routeName = ""
    var routeKind = Kind.other
    var hardwareRate: Double = 0
    var fileRate: Double = 0
    var usingEngine = false
    var speed: Float = 1

    var ratesMatch: Bool { fileRate > 0 && abs(fileRate - hardwareRate) < 1 }

    /// Bit-perfect is only possible over a wired digital output with matching rates.
    func isBitPerfect(enabled: Bool) -> Bool {
        enabled && usingEngine && routeKind == .wired && ratesMatch && abs(speed - 1) < 0.001
    }

    /// Why it isn't, in a few words.
    func blocker(enabled: Bool) -> String? {
        guard enabled else { return nil }
        if !usingEngine { return "Spatial audio file" }
        if abs(speed - 1) >= 0.001 { return "Speed isn't 1×" }
        switch routeKind {
        case .bluetooth: return "Bluetooth re-encodes audio"
        case .airPlay: return "AirPlay resamples audio"
        case .builtIn: return "Built-in speaker"
        case .other, .wired: break
        }
        if fileRate > 0, !ratesMatch {
            return "Resampled \(Formatting.sampleRate(fileRate)) → \(Formatting.sampleRate(hardwareRate))"
        }
        return nil
    }
}
