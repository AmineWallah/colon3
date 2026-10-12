import Foundation
import SoulseekKit

/// A folder from one user's search results — usually an album.
struct FolderResult: Identifiable {
    let id: String
    let username: String
    let folder: String
    var files: [SharedFile]
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

final class AppModel: ObservableObject {
    @Published private(set) var connection: ClientState = .disconnected
    @Published private(set) var results: [FolderResult] = []
    @Published private(set) var responseCount = 0
    @Published private(set) var currentQuery = ""
    @Published private(set) var downloads: [DownloadItem] = []
    @Published private(set) var logLines: [String] = []
    @Published var username: String = UserDefaults.standard.string(forKey: "username") ?? ""
    @Published var audioOnly = true {
        didSet { rebuildResults() }
    }

    let client: SoulseekClient
    let library: Library

    private var searchToken: UInt32?
    private var responses: [SearchResponse] = []
    private var pendingResponses: [SearchResponse] = []
    private var flushScheduled = false
    private var started = false

    /// Formats AVPlayer can play on iOS. Ogg/Opus/WMA are skipped in "audio only" mode.
    static let playableExtensions: Set<String> = ["mp3", "m4a", "aac", "alac", "flac", "wav", "aif", "aiff", "caf"]

    init(library: Library) {
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

    var activeDownloadCount: Int { downloads.filter(\.isActive).count }

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
        for response in responses {
            let files = audioOnly
                ? response.files.filter { Self.playableExtensions.contains($0.fileExtension) }
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
        results = folders.values
            .map { folder in
                var sorted = folder
                sorted.files.sort { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
                return sorted
            }
            .sorted { lhs, rhs in
                if lhs.slotFree != rhs.slotFree { return lhs.slotFree }
                return lhs.speed > rhs.speed
            }
    }

    // MARK: Downloads

    func download(_ file: SharedFile, from username: String) {
        client.download(username: username, file: file)
    }

    func downloadFolder(_ folder: FolderResult) {
        folder.files.forEach { client.download(username: folder.username, file: $0) }
    }

    func retry(_ item: DownloadItem) { client.retry(item.id) }

    func cancel(_ item: DownloadItem) {
        client.cancel(item.id)
        downloads.removeAll { $0.id == item.id }
    }

    func clearFinished() {
        downloads.removeAll { !$0.isActive }
    }

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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.flushResponses() }
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
            if case .completed = update.state { library.rescan() }

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
