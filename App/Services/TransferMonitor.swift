import ActivityKit
import Combine
import Foundation
import SoulseekKit

/// Watches Soulseek transfers and playback. While transfers run and nothing is playing it shows a
/// Live Activity (Dynamic Island / Lock Screen) and keeps the app awake in the background.
/// When music plays, the system's Now Playing takes the Island instead.
@MainActor
final class TransferMonitor {
    private let soulseek: SoulseekModel
    private let player: Player
    private let keeper = BackgroundKeeper()
    private var activity: Activity<TransferActivityAttributes>?
    private var subscription: AnyCancellable?

    private var lastBytes: UInt64 = 0
    private var lastSample = Date()
    private var speed: Double = 0

    init(soulseek: SoulseekModel, player: Player) {
        self.soulseek = soulseek
        self.player = player

        // Activities left over from a previous run (crash, force quit) would otherwise linger.
        for stale in Activity<TransferActivityAttributes>.activities {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }

        subscription = soulseek.$downloads
            .combineLatest(soulseek.$uploads, player.$isPlaying)
            .throttle(for: .seconds(1.5), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] downloads, uploads, isPlaying in
                MainActor.assumeIsolated {
                    self?.update(downloads: downloads, uploads: uploads, isPlaying: isPlaying)
                }
            }
    }

    private func update(downloads: [DownloadItem], uploads: [UploadItem], isPlaying: Bool) {
        let activeDownloads = downloads.filter { $0.isActive && !$0.isArtwork }
        let moving = activeDownloads.filter { $0.state == .transferring || $0.state == .starting }
        let sending = uploads.filter { $0.state == .transferring }
        let busy = !activeDownloads.isEmpty || !sending.isEmpty

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
        if busy, !isPlaying, flag(AppSettings.backgroundTransfersKey) {
            keeper.start()
        } else {
            keeper.stop()
        }

        guard flag(AppSettings.transferActivityKey) else {
            endActivity(finished: false)
            return
        }
        if busy, !isPlaying {
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
                finished: false)
            showActivity(state)
        } else {
            endActivity(finished: !busy)
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

    private func flag(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}
