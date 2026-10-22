import Combine
import Foundation
import UIKit

/// What a colon3 backup holds, saved as JSON: "colon3-backup.json" in the "colon3 Backup" folder
/// on Google Drive, or a file you export. Passwords, tokens and API keys are never in it: they
/// stay in the Keychain.
struct BackupFile: Codable {
    static let currentFormat = 1

    var format: Int
    var app: String
    var device: String
    var created: Date
    /// Every song in the library when the backup was made.
    var songs: [Song]
    var playlists: [List]
    /// Song ids (paths inside the Music folder).
    var favoriteSongs: [String]
    var favoriteAlbums: [AlbumRef]
    /// Listening stats (stats.json as it is).
    var stats: Data?
    /// Settings: a property list of the keys in `BackupService.settingsKeys`.
    var settings: Data?
    /// Files copied to Google Drive, when music backup is on.
    var music: [MusicFile]?

    struct Song: Codable, Hashable {
        /// The path inside the Music folder, which is also the song's id in playlists.
        var id: String
        var title: String
        var artist: String
        var albumArtist: String?
        var album: String?
        var track: Int?
        var disc: Int?
        var year: Int?
        var duration: Double

        init(_ track: Track) {
            id = track.id
            title = track.title
            artist = track.artist
            albumArtist = track.albumArtist
            album = track.album
            self.track = track.trackNumber
            disc = track.discNumber
            year = track.year
            duration = track.duration
        }

        var wanted: WantedSong {
            WantedSong(title: title, artists: [artist], album: album, duration: duration > 0 ? duration : nil)
        }
    }

    struct List: Codable {
        var id: UUID
        var name: String
        var created: Date
        var modified: Date
        /// Song ids, in order. Can include songs that were already missing from the library.
        var songs: [String]
    }

    struct AlbumRef: Codable, Hashable {
        var title: String
        var artist: String

        var key: String { TrackMatcher.normalizeName(title) + "|" + TrackMatcher.normalizeName(artist) }
    }

    struct MusicFile: Codable, Hashable {
        /// The path inside the Music folder.
        var path: String
        var fileID: String
        var size: Int64

        var isAudio: Bool { LibraryStore.audioExtensions.contains((path as NSString).pathExtension.lowercased()) }
        var folder: String { (path as NSString).deletingLastPathComponent }
    }

    static func encode(_ backup: BackupFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(backup)
    }

    static func decode(_ data: Data) throws -> BackupFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup: BackupFile
        do {
            backup = try decoder.decode(BackupFile.self, from: data)
        } catch {
            throw BackupService.BackupError.message("That isn't a colon3 backup.")
        }
        guard backup.format <= currentFormat else {
            throw BackupService.BackupError.message("This backup was made by a newer colon3. Update colon3 first.")
        }
        return backup
    }

    /// A relative path that stays inside the Music folder (a hand-edited backup can't write
    /// anywhere else).
    static func isSafe(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") else { return false }
        return !path.split(separator: "/").contains { $0 == ".." || $0 == "." }
    }
}

/// Backs colon3 up to Google Drive (or a file) and restores it.
///
/// A restore brings back playlists, favourites, stats and settings straight away. Songs that
/// aren't on the phone stay listed as missing: playlists keep their place for them, and they're
/// linked up as they arrive, whether downloaded from the Drive music backup, found again on
/// Soulseek, or copied in by hand.
@MainActor
final class BackupService: ObservableObject {
    enum BackupError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self {
            case let .message(text): return text
            }
        }
    }

    /// What's running, for the Backup screen.
    struct Activity: Equatable {
        var title: String
        var detail = ""
        var fraction: Double?
    }

    /// Backup contents not on this phone yet.
    struct Pending: Codable, Equatable {
        var songs: [BackupFile.Song] = []
        var albums: [BackupFile.AlbumRef] = []
        /// Drive copies of missing songs (and their covers and lyrics).
        var driveFiles: [BackupFile.MusicFile] = []

        var isEmpty: Bool { songs.isEmpty && albums.isEmpty && driveFiles.isEmpty }
        var driveSongCount: Int { driveFiles.filter(\.isAudio).count }
    }

    /// Looking for missing songs on Soulseek.
    struct Search: Equatable {
        var total: Int
        var done = 0
        var found = 0
        var current: String?
        var isRunning = true
    }

    struct RestoreSummary: Equatable {
        var songs: Int
        var onPhone: Int
        var playlists: Int
        var favorites: Int
        var settings: Bool
    }

    static let folderName = "colon3 Backup"
    static let fileName = "colon3-backup.json"
    static let musicFolderName = "Music"

    /// Settings that go in backups. Not: Keychain items (passwords, tokens, keys), account names,
    /// caches, window state.
    static let settingsKeys = [
        AppSettings.artworkLookupKey, AppSettings.lyricsLookupKey, AppSettings.scrobblingKey,
        AppSettings.backgroundTransfersKey, AppSettings.transferActivityKey, AppSettings.showMissingKey,
        AppSettings.musicBrainzKey, AppSettings.autoplayKey, AppSettings.autoplayLibraryOnlyKey,
        AppSettings.autoplayAutoDownloadKey, AppSettings.bitPerfectKey, AppSettings.seedingKey,
        "accentHex", "home.sections", "home.hidden", "trending.country", "library.scope", "library.sort",
        "eq.custom", "eq.enabled", "eq.gains", "eq.mode", "eq.peq", "eq.peqName", "eq.peqPreamp",
        "eq.peqProfiles", "eq.preamp", "eq.preset", "playback.rate", "search.filters.v2",
        "missing.hiddenAlbums", "spotify.clientID", "update.automatic", "update.channel", "username",
        "import.playlists", "autoplay.discoveriesPlaylist",
        "backup.automatic", "backup.includeMusic", "backup.cellular",
    ]

    let drive: GoogleDrive

    @Published private(set) var activity: Activity?
    @Published private(set) var lastBackup: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var pending: Pending
    @Published private(set) var search: Search?
    /// The backup on Google Drive, once looked up.
    @Published private(set) var remote: BackupFile?
    @Published private(set) var remoteChecked = false
    @Published private(set) var isCheckingRemote = false
    /// Songs with a copy in the Drive music backup.
    @Published private(set) var uploadedSongs = 0

    @Published var automatic: Bool {
        didSet { UserDefaults.standard.set(automatic, forKey: "backup.automatic") }
    }
    @Published var includeMusic: Bool {
        didSet { UserDefaults.standard.set(includeMusic, forKey: "backup.includeMusic") }
    }
    @Published var useCellular: Bool {
        didSet { UserDefaults.standard.set(useCellular, forKey: "backup.cellular") }
    }

    var isWorking: Bool { activity != nil || search?.isRunning == true }

    /// True while a backup, restore or search runs (TransferMonitor keeps the app awake).
    var workPublisher: AnyPublisher<Bool, Never> {
        $activity.combineLatest($search)
            .map { activity, search in activity != nil || search?.isRunning == true }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    private let library: LibraryStore
    private let playlists: PlaylistStore
    private let favorites: FavoritesStore
    private let stats: StatsStore
    private let fetcher: SongFetcher
    private var work: Task<Void, Never>?
    private var searchWork: Task<Void, Never>?
    private var folderIDs: [String: String] = [:]
    private var backUpAfterScan = false
    private var subscriptions = Set<AnyCancellable>()

    private static let supportFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    private static let pendingURL = supportFolder.appendingPathComponent("backup-pending.json")
    /// Which music files are already on Drive: path → Drive file.
    private static let manifestURL = supportFolder.appendingPathComponent("backup-music.json")

    private struct Manifest: Codable {
        var account: String?
        var files: [String: BackupFile.MusicFile] = [:]
    }

    init(drive: GoogleDrive, library: LibraryStore, playlists: PlaylistStore, favorites: FavoritesStore,
         stats: StatsStore, fetcher: SongFetcher) {
        self.drive = drive
        self.library = library
        self.playlists = playlists
        self.favorites = favorites
        self.stats = stats
        self.fetcher = fetcher
        let defaults = UserDefaults.standard
        automatic = defaults.bool(forKey: "backup.automatic")
        includeMusic = defaults.bool(forKey: "backup.includeMusic")
        useCellular = defaults.bool(forKey: "backup.cellular")
        lastBackup = defaults.object(forKey: "backup.last") as? Date
        if let data = try? Data(contentsOf: Self.pendingURL), let stored = try? JSONDecoder().decode(Pending.self, from: data) {
            pending = stored
        } else {
            pending = Pending()
        }
        uploadedSongs = Self.loadManifest().files.values.filter(\.isAudio).count

        // Missing songs get linked up as they turn up in the library.
        library.$tracks
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.resolvePending()
                    if self.backUpAfterScan, self.isLibraryReady {
                        self.backUpAfterScan = false
                        self.backUpIfDue()
                    }
                }
            }
            .store(in: &subscriptions)
    }

    // MARK: Backing up

    func backUpNow() {
        guard activity == nil else { return }
        lastError = nil
        activity = Activity(title: "Backing Up…")
        work = Task { [weak self] in
            await self?.runBackup()
        }
    }

    /// Automatic backups: once a day, when colon3 is opened. Only after this phone has backed up
    /// or restored once, so a fresh install never replaces your backup with an empty one.
    func backUpIfDue() {
        guard automatic, drive.isConnected, activity == nil, search?.isRunning != true else { return }
        let restored = UserDefaults.standard.object(forKey: "backup.lastRestore") as? Date
        guard let last = lastBackup ?? restored, Date().timeIntervalSince(last) > 20 * 3600 else { return }
        // Not while the library is still loading at launch (the backup would miss its songs).
        guard isLibraryReady else {
            backUpAfterScan = true
            return
        }
        backUpNow()
    }

    /// Stops a backup or a music download.
    func cancel() {
        work?.cancel()
    }

    func cancelSearch() {
        searchWork?.cancel()
    }

    /// The library has finished loading (backups and restores wait for it).
    var isLibraryReady: Bool { library.scanRevision > 0 && !library.isScanning }

    private func runBackup() async {
        defer {
            activity = nil
            work = nil
        }
        do {
            guard isLibraryReady else { throw BackupError.message("The library is still loading. Try again in a moment.") }
            let folder = try await drive.folder(named: Self.folderName, in: "root")
            let existing = try await drive.children(of: folder, named: Self.fileName).first { !$0.isFolder }
            if existing != nil, library.tracks.isEmpty, playlists.playlists.isEmpty {
                throw BackupError.message("This phone has no music or playlists yet, so backing up would replace your backup with an empty one. Restore it first.")
            }
            if includeMusic {
                try await uploadMusic(into: folder)
            }
            activity = Activity(title: "Saving Backup…")
            let backup = makeBackup(music: driveCopiesOnPhone())
            let data = try BackupFile.encode(backup)
            _ = try await drive.save(data, named: Self.fileName, mimeType: "application/json", in: folder)
            lastBackup = backup.created
            UserDefaults.standard.set(backup.created, forKey: "backup.last")
            remote = backup
            remoteChecked = true
            Diagnostics.shared.log("Backed up \(backup.songs.count) songs and \(backup.playlists.count) playlists to Google Drive", category: "backup")
        } catch {
            report(error)
        }
    }

    /// The backup of this phone as it is now.
    func makeBackup(music: [BackupFile.MusicFile]?) -> BackupFile {
        let favoriteAlbums = favorites.albums.compactMap { library.album(id: $0) }
            .map { BackupFile.AlbumRef(title: $0.title, artist: $0.artist) }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return BackupFile(
            format: BackupFile.currentFormat,
            app: "colon3 " + version,
            device: UIDevice.current.name,
            created: Date(),
            songs: library.tracks.map { BackupFile.Song($0) },
            playlists: playlists.playlists.map {
                BackupFile.List(id: $0.id, name: $0.name, created: $0.created, modified: $0.modified, songs: $0.trackIDs)
            },
            favoriteSongs: favorites.songs.sorted(),
            favoriteAlbums: favoriteAlbums.sorted { $0.key < $1.key },
            stats: stats.exportData(),
            settings: Self.collectSettings(),
            music: music)
    }

    /// A backup file to save or share (without Google Drive).
    func exportData() throws -> Data {
        guard isLibraryReady else { throw BackupError.message("The library is still loading. Try again in a moment.") }
        return try BackupFile.encode(makeBackup(music: drive.isConnected ? driveCopiesOnPhone() : nil))
    }

    private static func collectSettings() -> Data? {
        var values: [String: Any] = [:]
        for key in settingsKeys {
            if let value = UserDefaults.standard.object(forKey: key) { values[key] = value }
        }
        return try? PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
    }

    private static func applySettings(_ data: Data) {
        guard let values = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else { return }
        let allowed = Set(settingsKeys)
        let defaults = UserDefaults.standard
        for (key, value) in values where allowed.contains(key) {
            // Don't switch accounts on a phone that's already logged in to Soulseek.
            if key == "username", !(defaults.string(forKey: key) ?? "").isEmpty { continue }
            defaults.set(value, forKey: key)
        }
    }

    // MARK: Music on Drive

    private struct LocalFile {
        let url: URL
        let path: String
        let size: Int64

        var name: String { (path as NSString).lastPathComponent }
        var folder: String { (path as NSString).deletingLastPathComponent }
    }

    /// Songs, covers and lyrics in the Music folder.
    private nonisolated static func localMusicFiles(in root: URL) -> [LocalFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles]) else { return [] }
        let wanted = LibraryStore.audioExtensions.union(LibraryStore.sidecarExtensions)
        let rootPath = root.standardizedFileURL.path
        var found: [LocalFile] = []
        for case let url as URL in enumerator {
            guard wanted.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let fullPath = url.standardizedFileURL.path
            guard fullPath.hasPrefix(rootPath) else { continue }
            var relative = String(fullPath.dropFirst(rootPath.count))
            if relative.hasPrefix("/") { relative.removeFirst() }
            found.append(LocalFile(url: url, path: relative, size: Int64(values.fileSize ?? 0)))
        }
        return found.sorted { $0.path < $1.path }
    }

    /// Uploads songs (and covers and lyrics) that aren't on Drive yet, into Music/ with the same
    /// folders as on the phone. Files already uploaded are skipped, so later backups only send
    /// what's new.
    private func uploadMusic(into backupFolder: String) async throws {
        activity = Activity(title: "Checking Music…")
        var manifest = Self.loadManifest()
        let existingFolder = try await drive.children(of: backupFolder, named: Self.musicFolderName).first(where: \.isFolder)
        let musicFolder: String
        if let existingFolder {
            musicFolder = existingFolder.id
        } else {
            musicFolder = try await drive.folder(named: Self.musicFolderName, in: backupFolder)
        }
        // A different account, or the folder was deleted: everything goes up again.
        if existingFolder == nil || manifest.account != drive.account {
            manifest = Manifest(account: drive.account)
        }
        folderIDs = ["": musicFolder]

        let root = library.root
        let files = await Task.detached(priority: .utility) { Self.localMusicFiles(in: root) }.value
        let todo = files.filter { manifest.files[$0.path]?.size != $0.size }
        guard !todo.isEmpty else {
            saveManifest(manifest)
            return
        }
        let totalBytes = max(todo.reduce(Int64(0)) { $0 + $1.size }, 1)
        var sent: Int64 = 0
        defer { saveManifest(manifest) }
        for (number, file) in todo.enumerated() {
            try Task.checkCancellation()
            activity = Activity(title: "Uploading Music…",
                                detail: "\(number + 1) of \(todo.count) · \(file.name)",
                                fraction: Double(sent) / Double(totalBytes))
            let parent = try await driveFolder(for: file.folder)
            if let old = manifest.files[file.path] {
                // The file changed (new tags or artwork): replace the copy.
                try? await drive.delete(old.fileID)
            }
            let id = try await drive.upload(file.url, named: file.name, in: parent, size: file.size, cellular: useCellular)
            manifest.files[file.path] = BackupFile.MusicFile(path: file.path, fileID: id, size: file.size)
            sent += file.size
            if number % 10 == 9 { saveManifest(manifest) }
        }
    }

    /// The Drive folder for a folder inside Music/, made if needed.
    private func driveFolder(for path: String) async throws -> String {
        if let id = folderIDs[path] { return id }
        let parentPath = (path as NSString).deletingLastPathComponent
        let parent = try await driveFolder(for: parentPath)
        let id = try await drive.folder(named: (path as NSString).lastPathComponent, in: parent)
        folderIDs[path] = id
        return id
    }

    /// Uploaded files that are still on the phone (what a restore can bring back from Drive).
    private func driveCopiesOnPhone() -> [BackupFile.MusicFile]? {
        let manifest = Self.loadManifest()
        guard !manifest.files.isEmpty, manifest.account == drive.account else { return nil }
        let root = library.root
        return manifest.files.values
            .filter { FileManager.default.fileExists(atPath: root.appendingPathComponent($0.path).path) }
            .sorted { $0.path < $1.path }
    }

    private static func loadManifest() -> Manifest {
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return Manifest() }
        return manifest
    }

    private func saveManifest(_ manifest: Manifest) {
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: Self.manifestURL, options: .atomic)
        }
        uploadedSongs = manifest.files.values.filter(\.isAudio).count
    }

    /// Forget which songs were uploaded (after disconnecting Google Drive).
    func forgetUploads() {
        try? FileManager.default.removeItem(at: Self.manifestURL)
        uploadedSongs = 0
        remote = nil
        remoteChecked = false
        pending.driveFiles = []
        savePending()
    }

    // MARK: Restoring

    /// Looks up the backup on Google Drive.
    func checkRemote() async {
        guard drive.isConnected, !isCheckingRemote else { return }
        isCheckingRemote = true
        defer { isCheckingRemote = false }
        do {
            remote = try await fetchRemote()
            remoteChecked = true
        } catch {
            report(error)
        }
    }

    private func fetchRemote() async throws -> BackupFile? {
        guard let folder = try await drive.children(of: "root", named: Self.folderName).first(where: \.isFolder),
              let file = try await drive.children(of: folder.id, named: Self.fileName).first(where: { !$0.isFolder }) else {
            return nil
        }
        return try BackupFile.decode(try await drive.contents(of: file.id))
    }

    func loadFile(_ url: URL) throws -> BackupFile {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try BackupFile.decode(try Data(contentsOf: url))
    }

    /// Brings back playlists, favourites and stats (and settings if asked). Songs that aren't on
    /// the phone are matched by title and artist when another copy is; the rest stay missing.
    @discardableResult
    func restore(_ backup: BackupFile, settings: Bool) -> RestoreSummary {
        lastError = nil
        let index = LibraryIndex(library.tracks)
        var remap: [String: String] = [:]
        var missing: [BackupFile.Song] = []
        for song in backup.songs {
            if let track = library.track(id: song.id) ?? index.match(song.wanted) {
                remap[song.id] = track.id
            } else {
                missing.append(song)
            }
        }

        for list in backup.playlists {
            playlists.restore(Playlist(id: list.id, name: list.name, trackIDs: list.songs.map { remap[$0] ?? $0 },
                                       created: list.created, modified: list.modified))
        }

        let albumsByKey = Dictionary(library.albums.map { (BackupFile.AlbumRef(title: $0.title, artist: $0.artist).key, $0.id) },
                                     uniquingKeysWith: { first, _ in first })
        var albumIDs: [String] = []
        var missingAlbums: [BackupFile.AlbumRef] = []
        for album in backup.favoriteAlbums {
            if let id = albumsByKey[album.key] { albumIDs.append(id) } else { missingAlbums.append(album) }
        }
        favorites.restore(songs: backup.favoriteSongs.map { remap[$0] ?? $0 }, albums: albumIDs)

        if let data = backup.stats { stats.merge(data, remap: remap) }
        if settings, let data = backup.settings {
            Self.applySettings(data)
            let defaults = UserDefaults.standard
            automatic = defaults.bool(forKey: "backup.automatic")
            includeMusic = defaults.bool(forKey: "backup.includeMusic")
            useCellular = defaults.bool(forKey: "backup.cellular")
        }

        // Drive copies of the missing songs, plus the covers and lyrics in their folders.
        let missingPaths = Set(missing.map(\.id))
        let missingFolders = Set(missing.map { ($0.id as NSString).deletingLastPathComponent })
        let root = library.root
        let driveFiles = (backup.music ?? []).filter { file in
            guard BackupFile.isSafe(file.path),
                  !FileManager.default.fileExists(atPath: root.appendingPathComponent(file.path).path) else { return false }
            return file.isAudio ? missingPaths.contains(file.path) : missingFolders.contains(file.folder)
        }

        var merged = pending
        let knownSongs = Set(merged.songs.map(\.id))
        merged.songs += missing.filter { !knownSongs.contains($0.id) }
        let knownAlbums = Set(merged.albums.map(\.key))
        merged.albums += missingAlbums.filter { !knownAlbums.contains($0.key) }
        let knownFiles = Set(merged.driveFiles.map(\.path))
        merged.driveFiles += driveFiles.filter { !knownFiles.contains($0.path) }
        pending = merged
        savePending()

        UserDefaults.standard.set(Date(), forKey: "backup.lastRestore")
        Diagnostics.shared.log("Restored a backup from \(backup.device): \(backup.songs.count - missing.count) of \(backup.songs.count) songs on this phone, \(backup.playlists.count) playlists", category: "backup")
        return RestoreSummary(songs: backup.songs.count, onPhone: backup.songs.count - missing.count,
                              playlists: backup.playlists.count,
                              favorites: backup.favoriteSongs.count + backup.favoriteAlbums.count,
                              settings: settings && backup.settings != nil)
    }

    /// Downloads the missing songs' Drive copies into the Music folder, at their old paths.
    func restoreMusicFromDrive() {
        guard activity == nil, !pending.driveFiles.isEmpty else { return }
        lastError = nil
        activity = Activity(title: "Downloading Music…")
        let files = pending.driveFiles
        work = Task { [weak self] in
            await self?.runDriveRestore(files)
        }
    }

    private func runDriveRestore(_ files: [BackupFile.MusicFile]) async {
        defer {
            activity = nil
            work = nil
            savePending()
            library.rescan()
        }
        var manifest = Self.loadManifest()
        if manifest.account != drive.account { manifest = Manifest(account: drive.account) }
        defer { saveManifest(manifest) }
        let root = library.root
        let totalBytes = max(files.reduce(Int64(0)) { $0 + $1.size }, 1)
        var received: Int64 = 0
        for (number, file) in files.enumerated() {
            guard !Task.isCancelled else { return }
            let destination = root.appendingPathComponent(file.path)
            received += file.size
            if FileManager.default.fileExists(atPath: destination.path) {
                pending.driveFiles.removeAll { $0.path == file.path }
                continue
            }
            activity = Activity(title: "Downloading Music…",
                                detail: "\(number + 1) of \(files.count) · \((file.path as NSString).lastPathComponent)",
                                fraction: Double(received - file.size) / Double(totalBytes))
            do {
                let temporary = try await drive.download(file.fileID, cellular: useCellular)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: temporary, to: destination)
                // It's the same file that's on Drive: no need to upload it again.
                manifest.files[file.path] = file
                pending.driveFiles.removeAll { $0.path == file.path }
            } catch {
                if Task.isCancelled { return }
                // One copy deleted from Drive shouldn't stop the rest.
                if (error as? GoogleDrive.DriveError)?.status == 404 {
                    Diagnostics.shared.log("Couldn't restore \(file.path): \(error.localizedDescription)", category: "backup")
                    pending.driveFiles.removeAll { $0.path == file.path }
                    continue
                }
                report(error)
                return
            }
            if number % 20 == 19 {
                savePending()
                library.rescan()
            }
        }
    }

    // MARK: Missing songs

    /// Missing songs that are in a playlist or favourites.
    var listedMissingSongs: [BackupFile.Song] {
        let listed = Set(playlists.playlists.flatMap(\.trackIDs)).union(favorites.songs)
        return pending.songs.filter { listed.contains($0.id) }
    }

    /// Looks for missing songs on Soulseek (a few at a time, through the same search queue as
    /// the playlist importer). Found songs go back into their playlists.
    func findMissingOnSoulseek(onlyListed: Bool) {
        guard search?.isRunning != true, fetcher.isAvailable else { return }
        let songs = onlyListed ? listedMissingSongs : pending.songs
        guard !songs.isEmpty else { return }
        lastError = nil
        search = Search(total: songs.count)
        searchWork = Task { [weak self] in
            await self?.runSearch(songs)
        }
    }

    private func runSearch(_ songs: [BackupFile.Song]) async {
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            while next < songs.count, next < 4 {
                let song = songs[next]
                next += 1
                group.addTask { await self.fetchMissing(song) }
            }
            while await group.next() != nil {
                if Task.isCancelled {
                    group.cancelAll()
                    continue
                }
                if next < songs.count {
                    let song = songs[next]
                    next += 1
                    group.addTask { await self.fetchMissing(song) }
                }
            }
        }
        search?.isRunning = false
        search?.current = nil
        searchWork = nil
        if let search {
            Diagnostics.shared.log("Backup restore: found \(search.found) of \(search.done) missing songs on Soulseek", category: "backup")
        }
    }

    private func fetchMissing(_ song: BackupFile.Song) async {
        defer { search?.done += 1 }
        // It may have turned up meanwhile.
        guard pending.songs.contains(where: { $0.id == song.id }) else {
            search?.found += 1
            return
        }
        search?.current = "\(song.artist) – \(song.title)"
        let outcome = await fetcher.fetch(song.wanted) { _ in }
        guard !Task.isCancelled else { return }
        if case let .found(track, _) = outcome {
            relink(song, to: track)
            search?.found += 1
        }
    }

    func dismissSearch() {
        guard search?.isRunning != true else { return }
        search = nil
    }

    /// Stops waiting for the missing songs (playlists keep their entries, hidden).
    func forgetMissing() {
        pending = Pending()
        savePending()
    }

    /// Links missing songs that are now in the library.
    private func resolvePending() {
        guard !pending.songs.isEmpty || !pending.albums.isEmpty else { return }
        let index = LibraryIndex(library.tracks)
        var changed = false
        for song in pending.songs {
            if let track = library.track(id: song.id) ?? index.match(song.wanted) {
                relink(song, to: track, save: false)
                changed = true
            }
        }
        if !pending.albums.isEmpty {
            let albumsByKey = Dictionary(library.albums.map { (BackupFile.AlbumRef(title: $0.title, artist: $0.artist).key, $0.id) },
                                         uniquingKeysWith: { first, _ in first })
            let found = pending.albums.filter { albumsByKey[$0.key] != nil }
            for album in found {
                if let id = albumsByKey[album.key] { favorites.addAlbum(id: id) }
            }
            if !found.isEmpty {
                let foundKeys = Set(found.map(\.key))
                pending.albums.removeAll { foundKeys.contains($0.key) }
                changed = true
            }
        }
        if changed { savePending() }
    }

    private func relink(_ song: BackupFile.Song, to track: Track, save: Bool = true) {
        playlists.replaceTrackID(song.id, with: track.id)
        favorites.replaceSong(song.id, with: track.id)
        stats.moveStats(from: song.id, to: track.id)
        pending.songs.removeAll { $0.id == song.id }
        let folder = (song.id as NSString).deletingLastPathComponent
        let stillMissingHere = pending.songs.contains { ($0.id as NSString).deletingLastPathComponent == folder }
        pending.driveFiles.removeAll { $0.path == song.id || (!stillMissingHere && !$0.isAudio && $0.folder == folder) }
        if save { savePending() }
    }

    private func savePending() {
        if pending.isEmpty {
            try? FileManager.default.removeItem(at: Self.pendingURL)
        } else if let data = try? JSONEncoder().encode(pending) {
            try? data.write(to: Self.pendingURL, options: .atomic)
        }
    }

    // MARK: Errors

    private func report(_ error: Error) {
        if error is CancellationError || Task.isCancelled { return }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled { return }
            if urlError.networkUnavailableReason == .expensive || urlError.networkUnavailableReason == .constrained {
                lastError = "Music is only sent over Wi-Fi. Connect to Wi-Fi, or turn on Use Cellular Data."
                return
            }
        }
        lastError = error.localizedDescription
        Diagnostics.shared.log("Backup: \(error.localizedDescription)", category: "backup")
    }
}
