import Combine
import Foundation
import SoulseekKit

/// A folder from one user's search results — usually an album.
struct FolderResult: Identifiable {
    let id: String
    let username: String
    let folder: String
    var files: [SharedFile]
    /// Image files seen in this folder (usually only when the search terms matched the folder name).
    var images: [SharedFile] = []
    let slotFree: Bool
    let speed: UInt32
    let queueLength: UInt32

    var name: String {
        let parts = folder.split(separator: "\\")
        return parts.last.map(String.init) ?? username
    }

    /// Parent folders, e.g. "Music\Artist" — helps tell same-named albums apart.
    var parentPath: String {
        folder.split(separator: "\\").dropLast().joined(separator: " › ")
    }

    var totalSize: UInt64 { files.reduce(0) { $0 + $1.size } }

    /// "artist album" guess for an online cover lookup.
    var coverQuery: String { CoverLookup.query(forFolderPath: folder) }

    var formatSummary: String {
        let extensions = Set(files.map { $0.fileExtension.uppercased() })
        var summary = extensions.sorted().joined(separator: "/")
        if let file = files.first(where: { $0.attributes.bitDepth != nil }),
           let depth = file.attributes.bitDepth, let rate = file.attributes.sampleRate {
            summary += " \(depth)/\(Formatting.kilohertz(rate))"
        } else if let bitrate = files.compactMap({ $0.attributes.bitrate }).max() {
            summary += " \(bitrate)k"
        }
        return summary
    }
}

struct DownloadItem: Identifiable {
    let id: DownloadID
    var state: DownloadState
    var received: UInt64
    var size: UInt64

    var filename: String { SharedFile(path: id.path, size: size).filename }
    var folderPath: String { SharedFile(path: id.path, size: size).folder }

    /// Cover images and .lrc lyrics fetched alongside albums; kept out of the downloads list.
    var isArtwork: Bool {
        LibraryStore.sidecarExtensions.contains(SharedFile(path: id.path, size: size).fileExtension)
    }

    var progress: Double {
        size > 0 ? min(1, Double(received) / Double(size)) : 0
    }

    var isActive: Bool {
        switch state {
        case .completed, .failed: return false
        default: return true
        }
    }
}

/// A file from a one-off "find this song" search (missing album tracks).
struct TrackCandidate: Identifiable {
    let username: String
    let file: SharedFile
    let slotFree: Bool
    let speed: UInt32
    let queueLength: UInt32
    var id: String { username + "|" + file.path }
}

struct UploadItem: Identifiable {
    let id: DownloadID
    var state: UploadState
    var sent: UInt64
    var size: UInt64

    var filename: String { SharedFile(path: id.path, size: size).filename }
    var progress: Double { size > 0 ? min(1, Double(sent) / Double(size)) : 0 }
    var isActive: Bool { state == .queued || state == .transferring }
}

@MainActor
final class SoulseekModel: ObservableObject {
    @Published private(set) var connection: ClientState = .disconnected
    @Published private(set) var results: [FolderResult] = []
    @Published private(set) var responseCount = 0
    @Published private(set) var currentQuery = ""
    @Published private(set) var downloads: [DownloadItem] = []
    @Published private(set) var uploads: [UploadItem] = []
    @Published private(set) var trackCandidates: [TrackCandidate] = []
    @Published private(set) var isFindingTrack = false
    @Published private(set) var logLines: [String] = []
    @Published var username: String = UserDefaults.standard.string(forKey: "username") ?? ""
    @Published var audioOnly = true {
        didSet { rebuildResults() }
    }
    @Published var filters = ResultFilters.load() {
        didSet {
            filters.save()
            rebuildResults()
        }
    }
    /// Folders found but hidden by the filters.
    @Published private(set) var hiddenCount = 0
    /// Set by the playlist importer while it works, so the app stays awake in the background
    /// between downloads too (see TransferMonitor).
    @Published var isImportingPlaylist = false
    /// Every download update, after `downloads` has been updated (the playlist importer follows
    /// its own downloads with this).
    let downloadEvents = PassthroughSubject<DownloadUpdate, Never>()

    let client: SoulseekClient
    let library: LibraryStore
    /// Set by the app; receives full folder listings for the missing-songs view.
    weak var completeness: AlbumCompletenessStore?
    weak var stats: StatsStore?

    private var searchToken: UInt32?
    /// Searches made for someone else (the playlist importer), kept off the Search tab.
    private var sideSearches: [UInt32: (SearchResponse) -> Void] = [:]
    private var trackSearchToken: UInt32?
    private var trackSearchTitle = ""
    private var responses: [SearchResponse] = []
    private var pendingResponses: [SearchResponse] = []
    private var flushScheduled = false
    private var started = false
    private var coverRequested = Set<String>()

    init(library: LibraryStore) {
        self.library = library
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        client = SoulseekClient(downloadDirectory: library.root,
                                incompleteDirectory: support.appendingPathComponent("Incomplete", isDirectory: true))
        client.onEvent = { [weak self] event in self?.handle(event) }
        library.onSharesChanged = { [weak self] shares in self?.client.updateShares(shares) }
    }

    var hasCredentials: Bool {
        !username.isEmpty && Keychain.load(account: username) != nil
    }

    var isLoggedIn: Bool { connection == .loggedIn }

    var activeDownloadCount: Int { downloads.filter { $0.isActive && !$0.isArtwork }.count }
    var visibleDownloads: [DownloadItem] { downloads.filter { !$0.isArtwork } }

    func start() {
        guard !started else { return }
        started = true
        library.rescan()
        reconnectIfNeeded()
    }

    func reconnectIfNeeded() {
        switch connection {
        case .disconnected, .failed:
            guard hasCredentials, let password = Keychain.load(account: username) else { return }
            client.connect(username: username, password: password)
        case .connecting, .loggedIn:
            break
        }
    }

    func logIn(username: String, password: String) {
        let trimmed = username.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !password.isEmpty else { return }
        if trimmed != self.username { Keychain.delete(account: self.username) }
        self.username = trimmed
        UserDefaults.standard.set(trimmed, forKey: "username")
        Keychain.save(password, account: trimmed)
        client.connect(username: trimmed, password: password)
    }

    func logOut() {
        client.disconnect()
    }

    // MARK: Search

    func search(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isLoggedIn else { return }
        currentQuery = trimmed
        responses.removeAll()
        pendingResponses.removeAll()
        results.removeAll()
        hiddenCount = 0
        responseCount = 0
        searchToken = client.search(trimmed)
    }

    /// Separate from the main search so it doesn't replace what's on the Search tab.
    func findTrack(artist: String, title: String) {
        guard isLoggedIn else { return }
        trackCandidates = []
        trackSearchTitle = AlbumCompletenessStore.normalizeTitle(title)
        isFindingTrack = true
        let query = ResultFilters.terms("\(artist) \(title)").joined(separator: " ")
        trackSearchToken = client.search(query)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            self?.isFindingTrack = false
        }
    }

    /// A search whose results go to `onResponse` instead of the Search tab. Returns nil when not
    /// logged in. Call `endSideSearch` when done listening.
    func sideSearch(_ query: String, onResponse: @escaping (SearchResponse) -> Void) -> UInt32? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isLoggedIn else { return nil }
        let token = client.search(trimmed)
        sideSearches[token] = onResponse
        return token
    }

    func endSideSearch(_ token: UInt32) {
        sideSearches[token] = nil
    }

    private func addTrackCandidates(from response: SearchResponse) {
        let wanted = trackSearchTitle
        let matches = response.files.filter { file in
            guard LibraryStore.audioExtensions.contains(file.fileExtension) else { return false }
            let name = AlbumCompletenessStore.normalizeTitle((file.filename as NSString).deletingPathExtension)
            return wanted.isEmpty || name.contains(wanted)
        }
        guard !matches.isEmpty else { return }
        trackCandidates += matches.prefix(5).map {
            TrackCandidate(username: response.username, file: $0, slotFree: response.slotFree,
                           speed: response.averageSpeed, queueLength: response.queueLength)
        }
        trackCandidates.sort { lhs, rhs in
            if lhs.slotFree != rhs.slotFree { return lhs.slotFree }
            let left = lhs.file.attributes.bitDepth != nil ? 2_000 : Int(lhs.file.attributes.bitrate ?? 0)
            let right = rhs.file.attributes.bitDepth != nil ? 2_000 : Int(rhs.file.attributes.bitrate ?? 0)
            if left != right { return left > right }
            return lhs.speed > rhs.speed
        }
        if trackCandidates.count > 60 { trackCandidates.removeLast(trackCandidates.count - 60) }
    }

    func folder(withID id: String) -> FolderResult? {
        results.first { $0.id == id }
    }

    private func flushResponses() {
        flushScheduled = false
        guard !pendingResponses.isEmpty else { return }
        responses += pendingResponses
        responseCount = responses.count
        pendingResponses.removeAll()
        rebuildResults()
    }

    private func rebuildResults() {
        var folders: [String: FolderResult] = [:]
        var images: [String: [SharedFile]] = [:]
        for response in responses {
            for file in response.files where LibraryStore.imageExtensions.contains(file.fileExtension) {
                images[response.username + "|" + file.folder, default: []].append(file)
            }
            let files = audioOnly
                ? response.files.filter { LibraryStore.audioExtensions.contains($0.fileExtension) }
                : response.files
            for file in files {
                let key = response.username + "|" + file.folder
                if folders[key] == nil {
                    folders[key] = FolderResult(id: key, username: response.username, folder: file.folder, files: [],
                                                slotFree: response.slotFree, speed: response.averageSpeed,
                                                queueLength: response.queueLength)
                }
                folders[key]?.files.append(file)
            }
        }
        let all = folders.values.map { folder in
            var sorted = folder
            sorted.images = images[folder.id] ?? []
            sorted.files.sort { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
            return sorted
        }
        let kept = all.filter { filters.accepts($0) }
        hiddenCount = all.count - kept.count
        results = filters.ordered(kept, query: currentQuery)
    }

    // MARK: Downloads

    func download(_ file: SharedFile, from username: String, knownImages: [SharedFile] = []) {
        client.download(username: username, file: file)
        if LibraryStore.audioExtensions.contains(file.fileExtension) {
            fetchCover(username: username, folder: file.folder, knownImages: knownImages)
        }
    }

    func downloadFolder(_ folder: FolderResult) {
        folder.files.forEach { client.download(username: folder.username, file: $0) }
        fetchCover(username: folder.username, folder: folder.folder, knownImages: folder.images)
    }

    /// Once per folder: asks the peer for the full listing, which gives the album's cover image
    /// (downloaded so the library has local art) and its complete tracklist (for missing songs).
    private func fetchCover(username: String, folder: String, knownImages: [SharedFile]) {
        let key = username + "|" + folder
        guard !coverRequested.contains(key) else { return }
        coverRequested.insert(key)

        client.browseFolder(username: username, folder: folder) { [weak self] files in
            guard let self else { return }
            if let files {
                self.completeness?.recordListing(username: username, remoteFolder: folder, files: files)
            }
            let images = (files ?? []).filter { $0.folder == folder && LibraryStore.imageExtensions.contains($0.fileExtension) }
            if let best = Self.bestCover(images.isEmpty ? knownImages : images) {
                self.client.download(username: username, file: best)
            }
            // Synced lyrics some rippers keep next to the music; tiny, so take them all.
            for lyrics in (files ?? []) where lyrics.folder == folder && lyrics.fileExtension == "lrc" && lyrics.size < 512_000 {
                self.client.download(username: username, file: lyrics)
            }
        }
    }

    /// Downloads a missing song straight into the album's existing folder.
    func downloadMissing(_ file: SharedFile, from username: String, into album: Album) {
        client.download(username: username, file: file, folderName: album.folder.lastPathComponent)
    }

    static func bestCover(_ images: [SharedFile]) -> SharedFile? {
        let usable = images.filter { $0.size > 0 && $0.size < 15_000_000 }
        let preferred = ["cover", "folder", "front", "album", "artwork"]
        for name in preferred {
            if let match = usable.first(where: { ($0.filename as NSString).deletingPathExtension.lowercased() == name }) {
                return match
            }
        }
        for name in preferred {
            if let match = usable.first(where: { $0.filename.lowercased().contains(name) }) { return match }
        }
        return usable.count <= 3 ? usable.max { $0.size < $1.size } : nil
    }

    func retry(_ item: DownloadItem) { client.retry(item.id) }

    func cancel(_ item: DownloadItem) {
        remove([item.id])
    }

    /// Cancels anything still running and drops the entries. The client forgets them too, so the
    /// same file can be downloaded again later.
    func remove(_ ids: Set<DownloadID>) {
        for id in ids { client.cancel(id) }
        downloads.removeAll { ids.contains($0.id) }
    }

    /// Retries the failed ones among `ids`; returns how many.
    @discardableResult
    func retry(_ ids: Set<DownloadID>) -> Int {
        var count = 0
        for item in downloads where ids.contains(item.id) {
            if case .failed = item.state {
                client.retry(item.id)
                count += 1
            }
        }
        return count
    }

    func clearFinished() {
        remove(Set(downloads.filter { !$0.isActive }.map(\.id)))
        uploads.removeAll { !$0.isActive }
    }

    func clearCompleted() {
        remove(Set(downloads.filter { if case .completed = $0.state { return true } else { return false } }.map(\.id)))
    }

    func clearFailed() {
        remove(Set(downloads.filter { if case .failed = $0.state { return true } else { return false } }.map(\.id)))
    }

    func retryAllFailed() {
        retry(Set(downloads.map(\.id)))
    }

    func cancelAllActive() {
        remove(Set(downloads.filter(\.isActive).map(\.id)))
    }

    /// Finished downloads among `ids` that are songs in the library.
    func libraryTracks(for ids: Set<DownloadID>) -> [Track] {
        downloads.compactMap { item -> Track? in
            guard ids.contains(item.id), case let .completed(url) = item.state else { return nil }
            return library.track(at: url)
        }
    }

    func cancelAll(from username: String) {
        remove(Set(downloads.filter { $0.id.username == username }.map(\.id)))
    }

    func retryFailed(from username: String) {
        for item in downloads where item.id.username == username {
            if case .failed = item.state { client.retry(item.id) }
        }
    }

    var activeUploadCount: Int { uploads.filter(\.isActive).count }

    func state(of file: SharedFile, from username: String) -> DownloadState? {
        downloads.first { $0.id == DownloadID(username: username, path: file.path) }?.state
    }

    // MARK: Events

    private func handle(_ event: ClientEvent) {
        switch event {
        case let .state(state):
            connection = state
            if case let .failed(message) = state { appendLog(message) }

        case let .searchResponse(response):
            if response.token == trackSearchToken {
                addTrackCandidates(from: response)
                return
            }
            if let handler = sideSearches[response.token] {
                handler(response)
                return
            }
            guard response.token == searchToken else { return }
            pendingResponses.append(response)
            if !flushScheduled {
                flushScheduled = true
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    self?.flushResponses()
                }
            }

        case let .download(update):
            if case .completed = update.state, !LibraryStore.sidecarExtensions.contains(SharedFile(path: update.id.path, size: 0).fileExtension) {
                let wasCompleted: Bool = {
                    guard let old = downloads.first(where: { $0.id == update.id }), case .completed = old.state else { return false }
                    return true
                }()
                if !wasCompleted { stats?.recordDownload(bytes: update.size, from: update.id.username) }
            }
            if let index = downloads.firstIndex(where: { $0.id == update.id }) {
                downloads[index].state = update.state
                downloads[index].received = update.received
                downloads[index].size = update.size
            } else {
                downloads.insert(DownloadItem(id: update.id, state: update.state,
                                              received: update.received, size: update.size), at: 0)
            }
            if case .completed = update.state {
                let ext = SharedFile(path: update.id.path, size: 0).fileExtension
                if ext == "lrc" {
                    // Sidecar lyrics: nothing to rescan, LyricsView looks for them when it opens.
                } else if LibraryStore.imageExtensions.contains(ext) {
                    let library = self.library
                    Task {
                        await ArtworkStore.shared.invalidateFolders()
                        library.bumpArtwork()
                    }
                } else {
                    library.rescan()
                }
            }
            downloadEvents.send(update)

        case let .upload(update):
            if update.state == .completed, uploads.first(where: { $0.id == update.id })?.state != .completed {
                stats?.recordUpload(bytes: update.size, to: update.id.username)
            }
            if let index = uploads.firstIndex(where: { $0.id == update.id }) {
                uploads[index].state = update.state
                uploads[index].sent = update.sent
                uploads[index].size = update.size
            } else {
                uploads.insert(UploadItem(id: update.id, state: update.state, sent: update.sent, size: update.size), at: 0)
                if uploads.count > 100 { uploads.removeLast(uploads.count - 100) }
            }

        case let .log(line):
            appendLog(line)
        }
    }

    private func appendLog(_ line: String) {
        let stamp = Formatting.time.string(from: Date())
        logLines.append("\(stamp)  \(line)")
        if logLines.count > 500 { logLines.removeFirst(logLines.count - 500) }
        Diagnostics.shared.log(line, category: "soulseek")
    }
}
