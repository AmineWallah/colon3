import ActivityKit
import Combine
import Foundation
import UIKit

extension Notification.Name {
    /// A song's lyrics file was added, replaced or removed.
    static let colon3LyricsChanged = Notification.Name("colon3LyricsChanged")
}

/// Lyrics on the Lock Screen: a Live Activity showing the line being sung (plus its
/// romanization and the next line) while songs with synced lyrics play.
///
/// iOS only lets an app start a Live Activity while it's on screen, so the activity starts when
/// you play something with the app open and then follows every song in the background
/// (songs without synced lyrics just show the title). It ends after 10 minutes paused, or when
/// playback stops. Turned off with "Lyrics on Lock Screen".
@MainActor
final class LyricsActivityController {
    nonisolated static let enabledKey = "lyrics.lockScreen"

    private let player: Player
    private let library: LibraryStore
    private var activity: Activity<LyricsActivityAttributes>?
    private var lines: [LyricLine] = []
    private var romanized: [Int: String] = [:]
    private var loadedTrackID: String?
    private var loadTask: Task<Void, Never>?
    private var lastState: LyricsActivityAttributes.ContentState?
    private var pausedSince: Date?
    private var timer: Timer?
    private var subscriptions = Set<AnyCancellable>()

    private var enabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    init(player: Player, library: LibraryStore) {
        self.player = player
        self.library = library

        // Left over from a previous run (crash, force quit).
        for stale in Activity<LyricsActivityAttributes>.activities {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }

        player.objectWillChange
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .colon3LyricsChanged)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.loadedTrackID = nil
                    self?.refresh()
                }
            }
            .store(in: &subscriptions)
        // The setting (and romanization) can change from Settings or the player menu.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            .store(in: &subscriptions)

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func refresh() {
        guard enabled, let track = player.current else {
            end()
            return
        }
        if track.id != loadedTrackID { load(track) }
        tick()
    }

    private func load(_ track: Track) {
        loadedTrackID = track.id
        lines = []
        romanized = [:]
        loadTask?.cancel()
        let album = library.album(containing: track)?.title ?? track.album
        let romanize = UserDefaults.standard.object(forKey: "lyrics.romanize") as? Bool ?? true
        loadTask = Task { [weak self] in
            let file = LibraryStore.lyricsURL(for: track)
            var lyrics = await Task.detached(priority: .utility) { LyricsService.localLyrics(at: file) }.value
            if lyrics == nil {
                lyrics = await LyricsService.shared.lyrics(title: track.title, artist: track.artist, album: album,
                                                           duration: track.duration, cacheKey: track.id)
            }
            guard !Task.isCancelled, case let .synced(synced) = lyrics else { return }
            var readings: [Int: String] = [:]
            if romanize {
                readings = await Task.detached(priority: .utility) { () -> [Int: String] in
                    guard let script = Romanizer.script(for: synced.map(\.text)) else { return [:] }
                    var output: [Int: String] = [:]
                    for line in synced {
                        if let reading = Romanizer.romanize(line.text, as: script) { output[line.id] = reading }
                    }
                    return output
                }.value
            }
            guard let self, !Task.isCancelled, self.loadedTrackID == track.id else { return }
            self.lines = synced
            self.romanized = readings
            self.tick()
        }
    }

    private func tick() {
        guard enabled, let track = player.current else { return }

        if player.isPlaying {
            pausedSince = nil
        } else {
            if pausedSince == nil { pausedSince = Date() }
            if let pausedSince, Date().timeIntervalSince(pausedSince) > 600 {
                end()
                return
            }
        }

        // Lead slightly so the line changes as it starts, like the lyrics view.
        let now = player.position + 0.25
        let current = lines.lastIndex { $0.time <= now }
        let line = current.map { lines[$0] }
        let next = current.map { $0 + 1 } ?? 0
        let state = LyricsActivityAttributes.ContentState(
            title: track.title,
            artist: track.artist,
            line: line?.text ?? "",
            romanized: line.flatMap { romanized[$0.id] },
            next: lines.indices.contains(next) ? lines[next].text : "",
            isPlaying: player.isPlaying)
        guard state != lastState else { return }
        push(state)
    }

    private func push(_ state: LyricsActivityAttributes.ContentState) {
        if let activity {
            lastState = state
            Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
            return
        }
        // Only start for a song that has synced lyrics, while playing with the app open.
        guard player.isPlaying, !lines.isEmpty,
              UIApplication.shared.applicationState == .active,
              ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let accent = UserDefaults.standard.string(forKey: "accentHex") ?? "#FF2D55"
        do {
            activity = try Activity.request(attributes: LyricsActivityAttributes(accentHex: accent),
                                            content: ActivityContent(state: state, staleDate: nil),
                                            pushType: nil)
            lastState = state
        } catch {
            Diagnostics.shared.log("Lyrics Live Activity: \(error.localizedDescription)", category: "lyrics")
        }
    }

    private func end() {
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        pausedSince = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
