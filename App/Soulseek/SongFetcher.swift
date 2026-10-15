import Combine
import Foundation
import SoulseekKit

/// Finds one song on Soulseek and downloads it into the library. Shared by the playlist
/// importer and autoplay so their searches go through one queue: at most one search every
/// `searchSpacing` seconds in total, never a burst, with autoplay (high priority) going first.
///
/// A song is searched as "artist title", then by title alone with the artist checked in the
/// path. The best files (one per user) are tried in turn; a download that fails, or sends
/// nothing for `stallTimeout`, moves on to the next.
@MainActor
final class SongFetcher {
    enum Priority {
        case normal, high
    }

    enum Progress {
        case searching
        /// `source` describes the file, e.g. "FLAC 16/44.1 · username".
        case downloading(fraction: Double, source: String)
    }

    enum Outcome {
        /// `downloaded` is false when the file was already in the library.
        case found(Track, downloaded: Bool)
        case notFound(String)
    }

    /// Time between the starts of two searches, across everyone using the fetcher.
    static let searchSpacing: TimeInterval = 10
    /// How long results are collected for each search.
    static let searchWindow: TimeInterval = 10
    static let stallTimeout: TimeInterval = 180

    private let soulseek: SoulseekModel
    private let library: LibraryStore

    private struct Candidate {
        let username: String
        let file: SharedFile
        let score: Int
    }

    private enum DownloadEnd {
        case completed(URL)
        case failed(String)
        case cancelled
    }

    private enum DownloadResult {
        case track(Track, downloaded: Bool)
        case failed(String)
    }

    private struct Pending {
        let continuation: CheckedContinuation<DownloadEnd, Never>
        let progress: (Double) -> Void
        var lastProgressAt: Date
        var lastReceived: UInt64
        var lastFraction: Double
    }

    private var pending: [DownloadID: Pending] = [:]
    private var searchBusy = false
    private var lastSearchAt = Date.distantPast
    private var highPriorityWaiting = 0
    private var watchdog: Timer?
    private var subscription: AnyCancellable?

    init(soulseek: SoulseekModel, library: LibraryStore) {
        self.soulseek = soulseek
        self.library = library
        subscription = soulseek.downloadEvents.sink { [weak self] update in
            MainActor.assumeIsolated { self?.handle(update) }
        }
    }

    /// Whether a fetch could start searching now.
    var isAvailable: Bool { soulseek.isLoggedIn }

    /// Searches, picks and downloads. Cancelling the calling task stops the search and cancels
    /// the download.
    func fetch(_ song: WantedSong, priority: Priority = .normal,
               progress: @escaping (Progress) -> Void) async -> Outcome {
        let wanted = TrackMatcher.Prepared(song)
        guard !wanted.title.isEmpty else { return .notFound("No title to search for") }

        let query = TrackMatcher.searchQuery(for: song)
        var candidates = await search(query, wanted: wanted, requireArtistInPath: false,
                                      priority: priority, progress: progress)
        if Task.isCancelled { return .notFound("Cancelled") }
        if candidates.isEmpty {
            // The artist may be spelled differently on disk (accents, "&" vs "and"): search the
            // title alone and check the artist in the path instead.
            let titleOnly = TrackMatcher.searchQuery(for: song, includeArtist: false)
            if titleOnly != query, !wanted.artists.isEmpty,
               titleOnly.split(separator: " ").count >= 2 || titleOnly.count >= 6 {
                candidates = await search(titleOnly, wanted: wanted, requireArtistInPath: true,
                                          priority: priority, progress: progress)
                if Task.isCancelled { return .notFound("Cancelled") }
            }
        }
        guard !candidates.isEmpty else { return .notFound("No match on Soulseek") }

        var lastReason = ""
        for candidate in candidates {
            if Task.isCancelled { return .notFound("Cancelled") }
            let source = Self.describe(candidate)
            progress(.downloading(fraction: 0, source: source))
            let result = await download(candidate) { fraction in
                progress(.downloading(fraction: fraction, source: source))
            }
            switch result {
            case let .track(track, downloaded):
                return .found(track, downloaded: downloaded)
            case let .failed(reason):
                lastReason = reason
                Diagnostics.shared.log("Fetch: \(candidate.username) failed (\(reason)), trying the next file", category: "fetch")
            }
        }
        return .notFound("Download failed: \(lastReason)")
    }

    // MARK: Search

    private func search(_ query: String, wanted: TrackMatcher.Prepared, requireArtistInPath: Bool,
                        priority: Priority, progress: (Progress) -> Void) async -> [Candidate] {
        guard !query.isEmpty, await waitForSearchTurn(priority) else { return [] }
        defer { searchBusy = false }
        progress(.searching)

        var collected: [SearchResponse] = []
        guard let token = soulseek.sideSearch(query, onResponse: { collected.append($0) }) else { return [] }
        lastSearchAt = Date()
        try? await Task.sleep(nanoseconds: UInt64(Self.searchWindow * 1_000_000_000))
        soulseek.endSideSearch(token)
        return rank(collected, wanted: wanted, requireArtistInPath: requireArtistInPath)
    }

    /// Waits until Soulseek is connected, no other search is collecting results, and the spacing
    /// has passed. High-priority callers go ahead of normal ones. False if cancelled.
    private func waitForSearchTurn(_ priority: Priority) async -> Bool {
        if priority == .high { highPriorityWaiting += 1 }
        defer { if priority == .high { highPriorityWaiting -= 1 } }
        var ticks = 0
        while !Task.isCancelled {
            let connected = soulseek.isLoggedIn
            if connected, !searchBusy, Date().timeIntervalSince(lastSearchAt) >= Self.searchSpacing,
               priority == .high || highPriorityWaiting == 0 {
                searchBusy = true
                return true
            }
            if !connected, ticks % 60 == 0 { soulseek.reconnectIfNeeded() }
            ticks += 1
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    /// The best file from each user, best first, at most five.
    private func rank(_ responses: [SearchResponse], wanted: TrackMatcher.Prepared,
                      requireArtistInPath: Bool) -> [Candidate] {
        let ownName = soulseek.username.lowercased()
        var bestPerUser: [String: Candidate] = [:]
        for response in responses where response.username.lowercased() != ownName {
            for file in response.files {
                guard let score = TrackMatcher.score(file, slotFree: response.slotFree, queueLength: response.queueLength,
                                                     speed: response.averageSpeed, for: wanted,
                                                     requireArtistInPath: requireArtistInPath) else { continue }
                if score > bestPerUser[response.username]?.score ?? .min {
                    bestPerUser[response.username] = Candidate(username: response.username, file: file, score: score)
                }
            }
        }
        return Array(bestPerUser.values.sorted { $0.score > $1.score }.prefix(5))
    }

    // MARK: Download

    private func download(_ candidate: Candidate, progress: @escaping (Double) -> Void) async -> DownloadResult {
        let id = DownloadID(username: candidate.username, path: candidate.file.path)
        var alreadyRunning = false

        // This exact file was downloaded (or started) before.
        if let state = soulseek.state(of: candidate.file, from: candidate.username) {
            switch state {
            case let .completed(url):
                if FileManager.default.fileExists(atPath: url.path), let track = await libraryTrack(at: url) {
                    return .track(track, downloaded: false)
                }
                soulseek.remove([id])  // Deleted since: let the client fetch it again.
            case .failed:
                soulseek.remove([id])
            default:
                alreadyRunning = true  // Started from Search: follow that download.
            }
        }
        if Task.isCancelled { return .failed("Cancelled") }

        let end = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<DownloadEnd, Never>) in
                guard self.pending[id] == nil else {
                    continuation.resume(returning: .failed("Already being fetched"))
                    return
                }
                self.pending[id] = Pending(continuation: continuation, progress: progress, lastProgressAt: Date(),
                                           lastReceived: 0, lastFraction: 0)
                self.startWatchdog()
                if !alreadyRunning { self.soulseek.download(candidate.file, from: candidate.username) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(id, with: .cancelled, removeDownload: true)
            }
        }

        switch end {
        case let .completed(url):
            if let track = await libraryTrack(at: url) { return .track(track, downloaded: true) }
            return .failed("The downloaded file didn't show up in the library")
        case let .failed(reason):
            return .failed(reason)
        case .cancelled:
            return .failed("Cancelled")
        }
    }

    private func handle(_ update: DownloadUpdate) {
        guard var entry = pending[update.id] else { return }
        switch update.state {
        case .transferring:
            if update.received > entry.lastReceived {
                entry.lastReceived = update.received
                entry.lastProgressAt = Date()
            }
            let fraction = update.size > 0 ? min(1, Double(update.received) / Double(update.size)) : 0
            // Coarse steps keep long lists from redrawing on every packet.
            let report = fraction - entry.lastFraction >= 0.02
            if report { entry.lastFraction = fraction }
            pending[update.id] = entry
            if report { entry.progress(fraction) }
        case let .completed(url):
            finish(update.id, with: .completed(url), removeDownload: false)
        case let .failed(reason):
            // We move on to another peer; don't leave the failure in the Downloads list.
            finish(update.id, with: .failed(reason), removeDownload: true)
        case .requesting, .queued, .starting:
            break
        }
    }

    private func finish(_ id: DownloadID, with end: DownloadEnd, removeDownload: Bool) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        if removeDownload { soulseek.remove([id]) }
        if pending.isEmpty {
            watchdog?.invalidate()
            watchdog = nil
        }
        entry.continuation.resume(returning: end)
    }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkStalls() }
        }
    }

    /// Queued on a peer that never gets to us, or stuck mid-transfer: give up on that file.
    private func checkStalls() {
        let now = Date()
        for (id, entry) in pending where now.timeIntervalSince(entry.lastProgressAt) > Self.stallTimeout {
            finish(id, with: .failed("peer didn't send the file"), removeDownload: true)
        }
    }

    /// The library song for a finished file, once the scan has picked it up.
    private func libraryTrack(at url: URL) async -> Track? {
        for second in 0..<120 {
            if let track = library.track(at: url) { return track }
            if Task.isCancelled || !FileManager.default.fileExists(atPath: url.path) { return nil }
            if second > 0, second % 20 == 0 { library.rescan() }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return library.track(at: url)
    }

    private static func describe(_ candidate: Candidate) -> String {
        let file = candidate.file
        var format = file.fileExtension.uppercased()
        if let depth = file.attributes.bitDepth, let rate = file.attributes.sampleRate {
            format += " \(depth)/\(Formatting.kilohertz(rate))"
        } else if let bitrate = file.attributes.bitrate {
            format += " \(bitrate)k"
        }
        return format + " · " + candidate.username
    }
}
