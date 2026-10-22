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
    /// Backups and restores keep the app awake too (no Live Activity for them).
    private var backupWorking = false
    private let keeper = BackgroundKeeper()
    private var activity: Activity<TransferActivityAttributes>?
    private var subscriptions = Set<AnyCancellable>()
    private var heartbeat: Timer?
    private var lastReconnect = Date.distantPast

    private var lastBytes: UInt64 = 0
    private var lastSample = Date()
    private var speed: Double = 0

    /// Everything in the current burst of transfers, finished ones included, so the island's
    /// percentage climbs to 100% instead of resetting each time a file completes.
    private struct Progress { var done: UInt64; var size: UInt64 }
    private var downloadBatch: [DownloadID: Progress] = [:]
    private var uploadBatch: [DownloadID: Progress] = [:]

    init(soulseek: SoulseekModel, player: Player, stats: StatsStore, backup: BackupService) {
        self.soulseek = soulseek
        self.player = player
        self.stats = stats

        // Activities left over from a previous run (crash, force quit) would otherwise linger.
        for stale in Activity<TransferActivityAttributes>.activities {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }

        soulseek.$downloads
            .combineLatest(soulseek.$uploads, player.$isPlaying, soulseek.$isImportingPlaylist)
            .throttle(for: .seconds(1.5), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _, _, _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            .store(in: &subscriptions)

        // @Published sends before the value changes, so use the value it sends.
        backup.workPublisher
            .sink { [weak self] working in
                MainActor.assumeIsolated {
                    self?.backupWorking = working
                    self?.refresh()
                }
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
        let busy = !activeDownloads.isEmpty || !sending.isEmpty || soulseek.isImportingPlaylist
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
        let wantsKeeper = ((busy || backupWorking) && AppSettings.flag(AppSettings.backgroundTransfersKey)) || seeding
        if wantsKeeper, !isPlaying {
            keeper.start()
        } else {
            keeper.stop()
        }

        guard AppSettings.flag(AppSettings.transferActivityKey) else {
            endActivity(finished: false)
            return
        }
        let fraction = batchFraction(downloads: downloads, uploads: uploads, busy: busy)
        if (busy || seeding), !isPlaying {
            let state = TransferActivityAttributes.ContentState(
                downloading: moving.count,
                uploading: sending.count,
                queued: activeDownloads.count - moving.count,
                fraction: fraction,
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

    private func batchFraction(downloads: [DownloadItem], uploads: [UploadItem], busy: Bool) -> Double {
        guard busy else {
            downloadBatch.removeAll()
            uploadBatch.removeAll()
            return 0
        }
        var current: [DownloadID: Progress] = [:]
        for item in downloads where !item.isArtwork {
            switch item.state {
            case .completed:
                // Only files that were part of this burst count as done.
                if downloadBatch[item.id] != nil { current[item.id] = Progress(done: item.size, size: item.size) }
            case .failed:
                break  // Leaves the batch; a retry adds it back.
            default:
                current[item.id] = Progress(done: min(item.received, item.size), size: item.size)
            }
        }
        downloadBatch = current

        var sent: [DownloadID: Progress] = [:]
        for item in uploads {
            switch item.state {
            case .transferring:
                sent[item.id] = Progress(done: min(item.sent, item.size), size: item.size)
            case .completed:
                if uploadBatch[item.id] != nil { sent[item.id] = Progress(done: item.size, size: item.size) }
            default:
                break
            }
        }
        uploadBatch = sent

        let all = Array(downloadBatch.values) + Array(uploadBatch.values)
        let size = all.reduce(UInt64(0)) { $0 + $1.size }
        let done = all.reduce(UInt64(0)) { $0 + $1.done }
        return size > 0 ? min(1, Double(done) / Double(size)) : 0
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
