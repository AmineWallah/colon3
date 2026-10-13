import ActivityKit
import Combine
import Foundation
import SoulseekKit

/// Watches Soulseek transfers and playback. While transfers run and nothing is playing it shows a
/// Live Activity (Dynamic Island / Lock Screen) and keeps the app awake in the background.
/// When music plays, the system's Now Playing takes the Island instead.
///
/// Seeding Mode does the same with no transfers at all: the app stays online in the background
/// so peers can keep downloading from you, and reconnects if the server drops it.
@MainActor
final class TransferMonitor {
    private let soulseek: SoulseekModel
    private let player: Player
    private weak var stats: StatsStore?
    private let keeper = BackgroundKeeper()
    private var activity: Activity<TransferActivityAttributes>?
    private var subscriptions = Set<AnyCancellable>()
    private var heartbeat: Timer?
    private var lastReconnect = Date.distantPast

    private var lastBytes: UInt64 = 0
    private var lastSample = Date()
    private var speed: Double = 0

    init(soulseek: SoulseekModel, player: Player, stats: StatsStore) {
        self.soulseek = soulseek
        self.player = player
        self.stats = stats

        // Activities left over from a previous run (crash, force quit) would otherwise linger.
        for stale in Activity<TransferActivityAttributes>.activities {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }

        soulseek.$downloads
            .combineLatest(soulseek.$uploads, player.$isPlaying)
            .throttle(for: .seconds(1.5), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _, _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            .store(in: &subscriptions)

        // Settings toggles (seeding, activity, background) take effect right away.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            .store(in: &subscriptions)

        heartbeat = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    var isSeeding: Bool { AppSettings.seedingEnabled }

    func refresh() {
        update(downloads: soulseek.downloads, uploads: soulseek.uploads, isPlaying: player.isPlaying)
    }

    private func update(downloads: [DownloadItem], uploads: [UploadItem], isPlaying: Bool) {
        let activeDownloads = downloads.filter { $0.isActive && !$0.isArtwork }
        let moving = activeDownloads.filter { $0.state == .transferring || $0.state == .starting }
        let sending = uploads.filter { $0.state == .transferring }
        let busy = !activeDownloads.isEmpty || !sending.isEmpty
        let seeding = isSeeding && soulseek.hasCredentials

        // Seeding: stay logged in even if the server or network dropped us.
        if seeding, !soulseek.isLoggedIn, Date().timeIntervalSince(lastReconnect) > 60 {
            lastReconnect = Date()
            soulseek.reconnectIfNeeded()
        }

        // Combined speed across everything that's moving.
        let bytes = downloads.reduce(UInt64(0)) { $0 + $1.received } + uploads.reduce(UInt64(0)) { $0 + $1.sent }
        let now = Date()
        let elapsed = now.timeIntervalSince(lastSample)
        if elapsed > 0.5 {
            let delta = bytes >= lastBytes ? Double(bytes - lastBytes) : 0
            speed = speed * 0.4 + (delta / elapsed) * 0.6
            lastBytes = bytes
            lastSample = now
        }

        // Keep-alive only matters when music isn't already keeping the app running.
        let wantsKeeper = (busy && AppSettings.flag(AppSettings.backgroundTransfersKey)) || seeding
        if wantsKeeper, !isPlaying {
            keeper.start()
        } else {
            keeper.stop()
        }

        guard AppSettings.flag(AppSettings.transferActivityKey) else {
            endActivity(finished: false)
            return
        }
        if (busy || seeding), !isPlaying {
            let tracked = activeDownloads.map { ($0.received, $0.size) } + sending.map { ($0.sent, $0.size) }
            let total = tracked.reduce(UInt64(0)) { $0 + $1.1 }
            let done = tracked.reduce(UInt64(0)) { $0 + $1.0 }
            let state = TransferActivityAttributes.ContentState(
                downloading: moving.count,
                uploading: sending.count,
                queued: activeDownloads.count - moving.count,
                fraction: total > 0 ? min(1, Double(done) / Double(total)) : 0,
                bytesPerSecond: moving.isEmpty && sending.isEmpty ? 0 : speed,
                currentFile: moving.first?.filename ?? sending.first?.filename ?? "",
                finished: false,
                seeding: seeding ? soulseek.library.tracks.count : 0,
                sessionUploaded: Double(stats?.sessionUploadedBytes ?? 0))
            showActivity(state)
        } else {
            endActivity(finished: !busy && !seeding)
        }
    }

    private func showActivity(_ state: TransferActivityAttributes.ContentState) {
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(90))
        if let activity {
            Task { await activity.update(content) }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let accent = UserDefaults.standard.string(forKey: AccentPalette.storageKey) ?? AccentPalette.defaultHex
        activity = try? Activity.request(attributes: TransferActivityAttributes(accentHex: accent),
                                         content: content, pushType: nil)
    }

    private func endActivity(finished: Bool) {
        guard let activity else { return }
        self.activity = nil
        let final = TransferActivityAttributes.ContentState(
            downloading: 0, uploading: 0, queued: 0, fraction: 1, bytesPerSecond: 0, currentFile: "", finished: finished)
        Task {
            await activity.end(ActivityContent(state: final, staleDate: nil),
                               dismissalPolicy: finished ? .after(Date().addingTimeInterval(5)) : .immediate)
        }
    }
}
