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

    /// Cover images fetched alongside albums; kept out of the downloads list.
    var isArtwork: Bool {
        LibraryStore.imageExtensions.contains(SharedFile(path: id.path, size: size).fileExtension)
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

    let client: SoulseekClient
    let library: LibraryStore

    private var searchToken: UInt32?
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

    /// Grabs the album's cover image from the peer so the library has local art. Uses images
    /// already seen in search results, otherwise asks the peer for the folder listing.
    private func fetchCover(username: String, folder: String, knownImages: [SharedFile]) {
        let key = username + "|" + folder
        guard !coverRequested.contains(key) else { return }
        coverRequested.insert(key)

        if let best = Self.bestCover(knownImages) {
            client.download(username: username, file: best)
            return
        }
        client.browseFolder(username: username, folder: folder) { [weak self] files in
            guard let self, let files else { return }
            let images = files.filter { $0.folder == folder && LibraryStore.imageExtensions.contains($0.fileExtension) }
            if let best = Self.bestCover(images) {
                self.client.download(username: username, file: best)
            }
        }
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
        client.cancel(item.id)
        downloads.removeAll { $0.id == item.id }
    }

    func clearFinished() {
        downloads.removeAll { !$0.isActive }
        uploads.removeAll { !$0.isActive }
    }

    func cancelAll(from username: String) {
        for item in downloads where item.id.username == username { client.cancel(item.id) }
        downloads.removeAll { $0.id.username == username }
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
            if let index = downloads.firstIndex(where: { $0.id == update.id }) {
                downloads[index].state = update.state
                downloads[index].received = update.received
                downloads[index].size = update.size
            } else {
                downloads.insert(DownloadItem(id: update.id, state: update.state,
                                              received: update.received, size: update.size), at: 0)
            }
            if case .completed = update.state {
                if LibraryStore.imageExtensions.contains(SharedFile(path: update.id.path, size: 0).fileExtension) {
                    let library = self.library
                    Task {
                        await ArtworkStore.shared.invalidateFolders()
                        library.bumpArtwork()
                    }
                } else {
                    library.rescan()
                }
            }

        case let .upload(update):
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
    }
}
