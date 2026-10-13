#if canImport(Network)
import Foundation
import Network

public struct DownloadID: Hashable, Sendable {
    public let username: String
    public let path: String

    public init(username: String, path: String) {
        self.username = username
        self.path = path
    }
}

public enum DownloadState: Equatable, Sendable {
    /// Connecting to the peer to send QueueUpload.
    case requesting
    /// Peer accepted the request; waiting for a free upload slot on their side.
    case queued(place: UInt32?)
    /// Peer sent TransferRequest; waiting for their file connection.
    case starting
    case transferring
    case completed(URL)
    case failed(String)
}

public struct DownloadUpdate: Sendable {
    public let id: DownloadID
    public let state: DownloadState
    public let received: UInt64
    public let size: UInt64
}

public enum ClientState: Equatable, Sendable {
    case disconnected
    case connecting
    case loggedIn
    case failed(String)
}

/// A local file we share. `virtualPath` is what peers see, backslash-separated.
public struct LocalShare: Sendable {
    public let virtualPath: String
    public let url: URL
    public let size: UInt64

    public init(virtualPath: String, url: URL, size: UInt64) {
        self.virtualPath = virtualPath
        self.url = url
        self.size = size
    }
}

public enum UploadState: Equatable, Sendable {
    case queued
    case transferring
    case completed
    case failed
}

/// Progress of a file we're sending to a peer. `id.username` is the downloader.
public struct UploadUpdate: Sendable {
    public let id: DownloadID
    public let state: UploadState
    public let sent: UInt64
    public let size: UInt64
}

public enum ClientEvent: Sendable {
    case state(ClientState)
    case searchResponse(SearchResponse)
    case download(DownloadUpdate)
    case upload(UploadUpdate)
    case log(String)
}

/// Soulseek client built on Network.framework.
///
/// It never listens for connections (iOS can't usefully do that behind NAT). Instead it relies on
/// indirect connections: when a peer can't reach us, the server sends us ConnectToPeer and we dial
/// out with PierceFireWall. Outgoing requests use direct connections, so they only work with peers
/// that have an open port, which is true of anyone who managed to send us search results.
///
/// All state lives on a private serial queue. `onEvent` is always called on the main queue;
/// set it before calling `connect`.
public final class SoulseekClient: @unchecked Sendable {
    public var onEvent: ((ClientEvent) -> Void)?

    public var serverHost = "server.slsknet.org"
    public var serverPort: UInt16 = 2242
    /// Reported to the server so peers try us directly first; nothing listens on it.
    public var advertisedPort: UInt32 = 2234

    public let downloadDirectory: URL
    public let incompleteDirectory: URL

    private let queue = DispatchQueue(label: "colon3.soulseek-client")
    private var server: NWConnection?
    private var serverFrames = FrameBuffer()
    private var username = ""
    private var isLoggedIn = false
    private var activeSearches = Set<UInt32>()

    private var peers: [String: PeerLink] = [:]
    private var addressWaiters: [String: [(PeerAddress?) -> Void]] = [:]
    private var fileLinks: [ObjectIdentifier: FileLink] = [:]

    private var downloads: [DownloadID: DownloadRecord] = [:]
    private var downloadsByToken: [String: DownloadID] = [:]

    private var shares: [String: LocalShare] = [:]
    private var uploadQueue: [UploadJob] = []
    private var activeUpload: UploadJob?
    private var completedUploads: UInt32 = 0
    private var folderBrowses: [UInt32: FolderBrowse] = [:]

    public init(downloadDirectory: URL, incompleteDirectory: URL) {
        self.downloadDirectory = downloadDirectory
        self.incompleteDirectory = incompleteDirectory
    }

    // MARK: - Public API

    public func connect(username: String, password: String) {
        queue.async { self.openServer(username: username, password: password) }
    }

    public func disconnect() {
        queue.async { self.tearDown(.disconnected) }
    }

    /// Starts a search and returns its token. Results arrive as `.searchResponse` events.
    @discardableResult
    public func search(_ query: String) -> UInt32 {
        let token = UInt32.random(in: 1..<UInt32.max)
        queue.async {
            guard self.isLoggedIn else { return }
            self.activeSearches.insert(token)
            self.sendServer(.fileSearch(token: token, query: query))
        }
        return token
    }

    public func download(username: String, file: SharedFile) {
        queue.async {
            let id = DownloadID(username: username, path: file.path)
            if let existing = self.downloads[id] {
                switch existing.state {
                case .failed: break
                default: return  // Already in progress or done
                }
            }
            self.downloads[id] = DownloadRecord(id: id, state: .requesting, size: file.size)
            self.emitDownload(id)
            self.requestQueuePlace(id)
        }
    }

    public func retry(_ id: DownloadID) {
        queue.async {
            guard var record = self.downloads[id] else { return }
            record.state = .requesting
            record.retries = 0
            self.downloads[id] = record
            self.emitDownload(id)
            self.requestQueuePlace(id)
        }
    }

    public func cancel(_ id: DownloadID) {
        queue.async {
            if let token = self.downloads[id]?.token {
                self.downloadsByToken[self.tokenKey(id.username, token)] = nil
            }
            self.downloads[id] = nil
            for link in self.fileLinks.values {
                if case let .downloading(linkID) = link.role, linkID == id { self.closeFile(link, reason: nil) }
            }
        }
    }

    /// Lists a peer's folder (and its subfolders). `completion` runs on the main queue with full
    /// virtual paths, or nil if the peer can't be reached or doesn't answer within 30 seconds.
    public func browseFolder(username: String, folder: String, completion: @escaping ([SharedFile]?) -> Void) {
        queue.async {
            guard self.isLoggedIn else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let token = UInt32.random(in: 1..<UInt32.max)
            self.folderBrowses[token] = FolderBrowse(username: username, folder: folder, completion: completion)
            self.sendToPeer(username, [.folderContentsRequest(token: token, folder: folder)],
                            onFailure: { [weak self] in self?.finishBrowse(token: token, files: nil) })
            self.queue.asyncAfter(deadline: .now() + 30) { [weak self] in
                self?.finishBrowse(token: token, files: nil)
            }
        }
    }

    private func finishBrowse(token: UInt32, files: [SharedFile]?) {
        guard let browse = folderBrowses.removeValue(forKey: token) else { return }
        DispatchQueue.main.async { browse.completion(files) }
    }

    public func updateShares(_ list: [LocalShare]) {
        queue.async {
            var map: [String: LocalShare] = [:]
            for share in list { map[share.virtualPath] = share }
            self.shares = map
            if self.isLoggedIn { self.sendShareCounts() }
        }
    }

    // MARK: - Server connection

    private func openServer(username: String, password: String) {
        tearDown(.connecting)
        self.username = username
        guard let port = NWEndpoint.Port(rawValue: serverPort) else { return }

        let connection = NWConnection(host: NWEndpoint.Host(serverHost), port: port, using: Self.tcpParameters(timeout: 15))
        server = connection
        serverFrames = FrameBuffer()

        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.server === connection else { return }
            switch state {
            case .ready:
                self.log("Connected to \(self.serverHost), logging in as \(username)")
                self.sendServer(.login(username: username, password: password,
                                       majorVersion: ServerRequest.majorVersion,
                                       minorVersion: ServerRequest.minorVersion))
                self.receive(on: connection, onData: { [weak self] data in
                    guard let self, self.server === connection else { return }
                    self.handleServerData(data)
                }, onClose: { [weak self] _ in
                    guard let self, self.server === connection else { return }
                    self.tearDown(.failed("Disconnected from server"))
                })
            case let .waiting(error), let .failed(error):
                self.tearDown(.failed("Can't reach server: \(error.localizedDescription)"))
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func tearDown(_ newState: ClientState) {
        isLoggedIn = false
        activeSearches.removeAll()
        if let server {
            server.stateUpdateHandler = nil
            server.cancel()
        }
        server = nil

        for link in Array(peers.values) { closePeer(link, failed: true) }
        for link in Array(fileLinks.values) { closeFile(link, reason: "Disconnected") }
        for waiters in addressWaiters.values { waiters.forEach { $0(nil) } }
        addressWaiters.removeAll()

        for (id, record) in downloads {
            switch record.state {
            case .requesting, .starting, .transferring:
                downloads[id]?.state = .failed("Disconnected")
                emitDownload(id)
            default:
                break
            }
        }
        for job in uploadQueue + [activeUpload].compactMap({ $0 }) {
            emitUpload(username: job.username, path: job.path, state: .failed, sent: 0, size: job.share.size)
        }
        uploadQueue.removeAll()
        for token in Array(folderBrowses.keys) { finishBrowse(token: token, files: nil) }
        activeUpload = nil
        emit(.state(newState))
    }

    private func handleServerData(_ data: Data) {
        serverFrames.append(data)
        while server != nil {
            let body: Data
            do {
                guard let next = try serverFrames.nextFrame() else { return }
                body = next
            } catch {
                tearDown(.failed("Server sent an invalid frame"))
                return
            }
            do {
                let event = try ServerEvent.decode(body)
                handleServerEvent(event)
            } catch {
                log("Couldn't decode server message: \(error)")
            }
        }
    }

    private func handleServerEvent(_ event: ServerEvent) {
        switch event {
        case let .loginSucceeded(greeting, ownIP):
            isLoggedIn = true
            log("Logged in (public IP \(ownIP)). \(greeting)")
            sendServer(.setWaitPort(advertisedPort))
            sendServer(.setStatus(2))
            // We don't take part in the distributed search tree.
            sendServer(.haveNoParent(true))
            sendServer(.branchRoot(username))
            sendServer(.branchLevel(0))
            sendServer(.acceptChildren(false))
            sendShareCounts()
            emit(.state(.loggedIn))

        case let .loginFailed(reason, detail):
            tearDown(.failed(Self.describeLoginFailure(reason, detail)))

        case let .peerAddress(username, ip, port):
            let waiters = addressWaiters.removeValue(forKey: username) ?? []
            let address: PeerAddress? = (ip == "0.0.0.0" || port == 0) ? nil : PeerAddress(ip: ip, port: port)
            waiters.forEach { $0(address) }

        case let .connectToPeer(username, type, ip, port, token):
            switch type {
            case ConnectionType.peer.rawValue:
                openPiercedPeer(username: username, ip: ip, port: port, token: token)
            case ConnectionType.file.rawValue:
                openPiercedFile(username: username, ip: ip, port: port, token: token)
            default:
                sendServer(.cantConnectToPeer(token: token, username: username))
            }

        case .relogged:
            tearDown(.failed("Logged in from somewhere else"))

        case .cantConnectToPeer, .other:
            break
        }
    }

    private static func describeLoginFailure(_ reason: String, _ detail: String?) -> String {
        switch reason {
        case "INVALIDPASS": return "Wrong password for this username"
        case "INVALIDUSERNAME": return "Invalid username" + (detail.map { ": \($0)" } ?? "")
        case "EMPTYPASSWORD": return "Password can't be empty"
        case "INVALIDVERSION": return "Server rejected this client version"
        case "SVRFULL": return "Server is full, try again later"
        case "SVRPRIVATE": return "Server isn't accepting new accounts"
        default: return "Login failed: \(reason)"
        }
    }

    private func sendServer(_ request: ServerRequest) {
        server?.send(content: request.frame, completion: .contentProcessed { _ in })
    }

    private func sendShareCounts() {
        let folders = Set(shares.keys.map { Self.splitVirtualPath($0).folder })
        sendServer(.sharedFoldersFiles(folders: UInt32(folders.count), files: UInt32(shares.count)))
    }

    private func resolveAddress(_ username: String, completion: @escaping (PeerAddress?) -> Void) {
        let isFirst = addressWaiters[username] == nil
        addressWaiters[username, default: []].append(completion)
        guard isFirst else { return }
        sendServer(.getPeerAddress(username: username))
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, let waiters = self.addressWaiters.removeValue(forKey: username) else { return }
            waiters.forEach { $0(nil) }
        }
    }

    // MARK: - Peer (P) connections

    /// Sends messages to a peer, opening a direct connection if there isn't one yet.
    private func sendToPeer(_ username: String, _ messages: [PeerMessage],
                            onSent: (() -> Void)? = nil, onFailure: (() -> Void)? = nil) {
        var frames: [Data] = []
        do {
            for message in messages { frames.append(try message.frame()) }
        } catch {
            log("Couldn't encode message for \(username): \(error)")
            return
        }

        if let link = peers[username] {
            if link.isReady, let connection = link.connection {
                frames.forEach { connection.send(content: $0, completion: .contentProcessed { _ in }) }
                onSent?()
            } else {
                link.outbox += frames
                if let onSent { link.sentHandlers.append(onSent) }
                if let onFailure { link.failureHandlers.append(onFailure) }
            }
            return
        }

        let link = PeerLink(username: username)
        link.outbox = frames
        if let onSent { link.sentHandlers.append(onSent) }
        if let onFailure { link.failureHandlers.append(onFailure) }
        peers[username] = link

        resolveAddress(username) { [weak self] address in
            guard let self, !link.isClosed else { return }
            guard let address else {
                self.log("\(username) is offline or unknown")
                self.closePeer(link, failed: true)
                return
            }
            self.startPeerConnection(link, address: address, firstFrame: PeerInitMessage.peerInit(username: self.username, type: "P").frame)
        }
    }

    private func openPiercedPeer(username: String, ip: String, port: UInt32, token: UInt32) {
        let link = PeerLink(username: username)
        if let existing = peers[username], !existing.isReady {
            // Hand queued messages over to the connection that is actually coming up.
            link.outbox = existing.outbox
            link.sentHandlers = existing.sentHandlers
            link.failureHandlers = existing.failureHandlers
            existing.outbox.removeAll()
            existing.sentHandlers.removeAll()
            existing.failureHandlers.removeAll()
            closePeer(existing, failed: false)
        }
        peers[username] = link
        startPeerConnection(link, address: PeerAddress(ip: ip, port: port),
                            firstFrame: PeerInitMessage.pierceFirewall(token: token).frame,
                            pierceToken: token)
    }

    private func startPeerConnection(_ link: PeerLink, address: PeerAddress, firstFrame: Data, pierceToken: UInt32? = nil) {
        guard let port = NWEndpoint.Port(rawValue: UInt16(truncatingIfNeeded: address.port)) else {
            closePeer(link, failed: true)
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(address.ip), port: port, using: Self.tcpParameters(timeout: 8))
        link.connection = connection

        connection.stateUpdateHandler = { [weak self, weak link] state in
            guard let self, let link, !link.isClosed else { return }
            switch state {
            case .ready:
                connection.send(content: firstFrame, completion: .contentProcessed { _ in })
                link.isReady = true
                link.outbox.forEach { connection.send(content: $0, completion: .contentProcessed { _ in }) }
                link.outbox.removeAll()
                link.failureHandlers.removeAll()
                let sent = link.sentHandlers
                link.sentHandlers.removeAll()
                sent.forEach { $0() }
                self.receive(on: connection, onData: { [weak self, weak link] data in
                    guard let self, let link else { return }
                    self.handlePeerData(link, data)
                }, onClose: { [weak self, weak link] _ in
                    guard let self, let link else { return }
                    self.closePeer(link, failed: false)
                })
            case .waiting, .failed:
                if let pierceToken {
                    self.sendServer(.cantConnectToPeer(token: pierceToken, username: link.username))
                }
                self.closePeer(link, failed: true)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func closePeer(_ link: PeerLink, failed: Bool) {
        guard !link.isClosed else { return }
        link.isClosed = true
        link.connection?.stateUpdateHandler = nil
        link.connection?.cancel()
        if peers[link.username] === link { peers[link.username] = nil }
        if failed {
            let handlers = link.failureHandlers
            link.failureHandlers.removeAll()
            handlers.forEach { $0() }
        }
    }

    private func handlePeerData(_ link: PeerLink, _ data: Data) {
        link.frames.append(data)
        while true {
            let body: Data
            do {
                guard let next = try link.frames.nextFrame() else { return }
                body = next
            } catch {
                log("Bad frame from \(link.username): \(error)")
                closePeer(link, failed: false)
                return
            }
            do {
                let message = try PeerMessage.decode(body)
                handlePeerMessage(from: link.username, message)
            } catch {
                log("Couldn't decode message from \(link.username): \(error)")
            }
        }
    }

    private func handlePeerMessage(from username: String, _ message: PeerMessage) {
        switch message {
        case let .fileSearchResponse(response):
            guard activeSearches.contains(response.token) else { return }
            emit(.searchResponse(response))

        case let .transferRequest(direction, token, filename, size):
            if direction == .upload {
                acceptIncomingTransfer(from: username, token: token, filename: filename, size: size)
            } else {
                // Legacy download request (slskd, Seeker). Nicotine+ answers "Queued" and queues it.
                sendToPeer(username, [.transferResponse(token: token, allowed: false, reason: "Queued", size: nil)])
                enqueueUpload(for: username, path: filename)
            }

        case let .transferResponse(token, allowed, reason, _):
            handleUploadResponse(from: username, token: token, allowed: allowed, reason: reason)

        case let .queueUpload(filename):
            enqueueUpload(for: username, path: filename)

        case let .placeInQueueResponse(filename, place):
            let id = DownloadID(username: username, path: filename)
            guard let record = downloads[id] else { return }
            switch record.state {
            case .requesting, .queued:
                downloads[id]?.state = .queued(place: place)
                emitDownload(id)
            default:
                break
            }

        case let .uploadDenied(filename, reason):
            let id = DownloadID(username: username, path: filename)
            guard downloads[id] != nil else { return }
            downloads[id]?.state = .failed(reason.isEmpty ? "Denied by peer" : reason)
            emitDownload(id)

        case let .uploadFailed(filename):
            let id = DownloadID(username: username, path: filename)
            guard let record = downloads[id] else { return }
            if case .completed = record.state { return }
            if record.retries < 2 {
                downloads[id]?.retries += 1
                downloads[id]?.state = .requesting
                emitDownload(id)
                requestQueuePlace(id)
            } else {
                downloads[id]?.state = .failed("Upload failed on \(username)'s side")
                emitDownload(id)
            }

        case .sharedFileListRequest:
            sendToPeer(username, [.sharedFileListResponse(folders: sharedFolders())])

        case .userInfoRequest:
            sendToPeer(username, [.userInfoResponse(description: "colon3 (iOS)",
                                                    totalUploads: completedUploads,
                                                    queueSize: UInt32(uploadQueue.count),
                                                    slotsFree: activeUpload == nil)])

        case let .placeInQueueRequest(filename):
            if let index = uploadQueue.firstIndex(where: { $0.username == username && $0.path == filename }) {
                sendToPeer(username, [.placeInQueueResponse(filename: filename, place: UInt32(index + 1))])
            }

        case let .folderContentsRequest(token, folder):
            let folders = sharedFolders().filter { $0.name == folder || $0.name.hasPrefix(folder + "\\") }
            sendToPeer(username, [.folderContentsResponse(token: token, folder: folder, folders: folders)])

        case let .folderContentsResponse(token, _, folders):
            guard let browse = folderBrowses[token], browse.username == username else { return }
            let files = folders.flatMap { entry in
                entry.files.map { file in
                    var full = file
                    full.path = entry.name.isEmpty ? file.path : entry.name + "\\" + file.path
                    return full
                }
            }
            finishBrowse(token: token, files: files)

        case .sharedFileListResponse, .userInfoResponse, .unknown:
            break
        }
    }

    // MARK: - Downloads

    private func requestQueuePlace(_ id: DownloadID) {
        sendToPeer(id.username, [.queueUpload(filename: id.path), .placeInQueueRequest(filename: id.path)],
                   onSent: { [weak self] in
                       guard let self, self.downloads[id]?.state == .requesting else { return }
                       self.downloads[id]?.state = .queued(place: nil)
                       self.emitDownload(id)
                   },
                   onFailure: { [weak self] in
                       guard let self, self.downloads[id]?.state == .requesting else { return }
                       self.downloads[id]?.state = .failed("Couldn't connect to \(id.username)")
                       self.emitDownload(id)
                   })
    }

    private func acceptIncomingTransfer(from username: String, token: UInt32, filename: String, size: UInt64?) {
        let id = DownloadID(username: username, path: filename)
        guard var record = downloads[id] else {
            sendToPeer(username, [.transferResponse(token: token, allowed: false, reason: "Cancelled", size: nil)])
            return
        }
        switch record.state {
        case .completed, .transferring:
            sendToPeer(username, [.transferResponse(token: token, allowed: false, reason: "Cancelled", size: nil)])
            return
        default:
            break
        }

        if let size { record.size = size }
        if let oldToken = record.token { downloadsByToken[tokenKey(username, oldToken)] = nil }
        record.token = token
        record.state = .starting
        downloads[id] = record
        downloadsByToken[tokenKey(username, token)] = id
        sendToPeer(username, [.transferResponse(token: token, allowed: true, reason: nil, size: nil)])
        emitDownload(id)

        queue.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self, let current = self.downloads[id], current.token == token, current.state == .starting else { return }
            self.downloads[id]?.state = .failed("\(username) never opened the file connection")
            self.emitDownload(id)
        }
    }

    private func openPiercedFile(username: String, ip: String, port: UInt32, token: UInt32) {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(truncatingIfNeeded: port)) else { return }
        let connection = NWConnection(host: NWEndpoint.Host(ip), port: nwPort, using: Self.tcpParameters(timeout: 8))
        let link = FileLink(username: username, connection: connection, role: .awaitingToken)
        fileLinks[ObjectIdentifier(link)] = link

        connection.stateUpdateHandler = { [weak self, weak link] state in
            guard let self, let link, !link.isClosed else { return }
            switch state {
            case .ready:
                connection.send(content: PeerInitMessage.pierceFirewall(token: token).frame,
                                completion: .contentProcessed { _ in })
                self.receive(on: connection, onData: { [weak self, weak link] data in
                    guard let self, let link else { return }
                    self.handleFileData(link, data)
                }, onClose: { [weak self, weak link] _ in
                    guard let self, let link else { return }
                    self.closeFile(link, reason: "Connection closed early")
                })
            case .waiting, .failed:
                self.sendServer(.cantConnectToPeer(token: token, username: username))
                self.closeFile(link, reason: "Couldn't open file connection")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func handleFileData(_ link: FileLink, _ data: Data) {
        switch link.role {
        case .awaitingToken:
            link.pending.append(data)
            guard link.pending.count >= 4 else { return }
            var reader = ByteReader(link.pending)
            guard let token = try? reader.u32() else { return }
            let leftover = reader.rest()
            link.pending = Data()
            beginReceivingFile(link, token: token, leftover: leftover)

        case let .downloading(id):
            writeChunk(data, link: link, id: id)

        case .uploading:
            handleUploadOffset(link, data)
        }
    }

    private func beginReceivingFile(_ link: FileLink, token: UInt32, leftover: Data) {
        guard let id = downloadsByToken[tokenKey(link.username, token)], var record = downloads[id] else {
            log("Unexpected file connection from \(link.username)")
            closeFile(link, reason: nil)
            return
        }

        let partial = partialURL(for: id)
        var offset: UInt64 = 0
        do {
            try FileManager.default.createDirectory(at: incompleteDirectory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: partial.path) {
                FileManager.default.createFile(atPath: partial.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: partial)
            offset = try handle.seekToEnd()
            if offset > record.size {
                try handle.truncate(atOffset: 0)
                offset = 0
            }
            link.handle = handle
        } catch {
            record.state = .failed("Can't write file: \(error.localizedDescription)")
            downloads[id] = record
            emitDownload(id)
            closeFile(link, reason: nil)
            return
        }

        record.received = offset
        record.state = .transferring
        downloads[id] = record
        link.role = .downloading(id)

        var writer = ByteWriter()
        writer.u64(offset)
        link.connection.send(content: writer.data, completion: .contentProcessed { _ in })
        emitDownload(id)

        if record.received >= record.size {
            finishDownload(link, id: id)
        } else if !leftover.isEmpty {
            writeChunk(leftover, link: link, id: id)
        }
    }

    private func writeChunk(_ data: Data, link: FileLink, id: DownloadID) {
        guard let handle = link.handle, downloads[id] != nil else {
            closeFile(link, reason: nil)
            return
        }
        do {
            try handle.write(contentsOf: data)
        } catch {
            downloads[id]?.state = .failed("Write failed: \(error.localizedDescription)")
            emitDownload(id)
            closeFile(link, reason: nil)
            return
        }
        downloads[id]?.received += UInt64(data.count)
        guard let record = downloads[id] else { return }

        if record.received >= record.size {
            finishDownload(link, id: id)
        } else if Date().timeIntervalSince(link.lastProgress) > 0.3 {
            link.lastProgress = Date()
            emitDownload(id)
        }
    }

    private func finishDownload(_ link: FileLink, id: DownloadID) {
        try? link.handle?.close()
        link.handle = nil
        // The downloader closes the connection to signal completion.
        link.isClosed = true
        link.connection.stateUpdateHandler = nil
        link.connection.cancel()
        fileLinks[ObjectIdentifier(link)] = nil

        if let token = downloads[id]?.token { downloadsByToken[tokenKey(id.username, token)] = nil }
        do {
            let destination = try moveToLibrary(partialURL(for: id), id: id)
            downloads[id]?.state = .completed(destination)
            log("Finished \(destination.lastPathComponent)")
        } catch {
            downloads[id]?.state = .failed("Couldn't save file: \(error.localizedDescription)")
        }
        emitDownload(id)
    }

    private func closeFile(_ link: FileLink, reason: String?) {
        guard !link.isClosed else { return }
        link.isClosed = true
        link.connection.stateUpdateHandler = nil
        link.connection.cancel()
        try? link.handle?.close()
        link.handle = nil
        fileLinks[ObjectIdentifier(link)] = nil

        switch link.role {
        case let .downloading(id):
            guard let record = downloads[id], record.state == .transferring else { return }
            let percent = record.size > 0 ? Int(Double(record.received) / Double(record.size) * 100) : 0
            downloads[id]?.state = .failed("\(reason ?? "Interrupted") at \(percent)%")
            emitDownload(id)
        case let .uploading(token):
            finishUpload(token: token, succeeded: link.uploadDone)
        case .awaitingToken:
            break
        }
    }

    private func partialURL(for id: DownloadID) -> URL {
        incompleteDirectory.appendingPathComponent(MD5.hex(id.username + "\n" + id.path) + ".part")
    }

    private func moveToLibrary(_ source: URL, id: DownloadID) throws -> URL {
        let file = SharedFile(path: id.path, size: 0)
        let folder = Self.sanitize(file.folderName.isEmpty ? id.username : file.folderName)
        let directory = downloadDirectory.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let name = Self.sanitize(file.filename)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var destination = directory.appendingPathComponent(name)
        var counter = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            let candidate = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            destination = directory.appendingPathComponent(candidate)
            counter += 1
        }
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }

    private static func sanitize(_ name: String) -> String {
        let cleaned = name.map { "/:\0".contains($0) ? "_" : $0 }
        let result = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty || result.hasPrefix(".") ? "_" + result : result
    }

    // MARK: - Uploads (so we're not a pure leecher)

    private func enqueueUpload(for username: String, path: String) {
        guard let share = shares[path] else {
            sendToPeer(username, [.uploadDenied(filename: path, reason: "File not shared.")])
            return
        }
        if activeUpload?.username == username && activeUpload?.path == path { return }
        if uploadQueue.contains(where: { $0.username == username && $0.path == path }) { return }
        uploadQueue.append(UploadJob(username: username, path: path, share: share))
        emitUpload(username: username, path: path, state: .queued, sent: 0, size: share.size)
        startNextUpload()
    }

    private func startNextUpload() {
        guard activeUpload == nil, isLoggedIn, !uploadQueue.isEmpty else { return }
        var job = uploadQueue.removeFirst()
        job.token = UInt32.random(in: 1..<UInt32.max)
        activeUpload = job
        let token = job.token

        sendToPeer(job.username, [.transferRequest(direction: .upload, token: token, filename: job.path, size: job.share.size)],
                   onFailure: { [weak self] in self?.finishUpload(token: token, succeeded: false) })

        queue.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self, let active = self.activeUpload, active.token == token, !active.started else { return }
            self.finishUpload(token: token, succeeded: false)
        }
    }

    private func handleUploadResponse(from username: String, token: UInt32, allowed: Bool, reason: String?) {
        guard let job = activeUpload, job.token == token, job.username == username, !job.started else { return }
        guard allowed else {
            log("\(username) declined upload: \(reason ?? "no reason")")
            finishUpload(token: token, succeeded: false)
            return
        }
        activeUpload?.started = true

        resolveAddress(username) { [weak self] address in
            guard let self else { return }
            guard let address, let port = NWEndpoint.Port(rawValue: UInt16(truncatingIfNeeded: address.port)) else {
                self.finishUpload(token: token, succeeded: false)
                return
            }
            let connection = NWConnection(host: NWEndpoint.Host(address.ip), port: port, using: Self.tcpParameters(timeout: 8))
            let link = FileLink(username: username, connection: connection, role: .uploading(token))
            self.fileLinks[ObjectIdentifier(link)] = link

            connection.stateUpdateHandler = { [weak self, weak link] state in
                guard let self, let link, !link.isClosed else { return }
                switch state {
                case .ready:
                    var writer = ByteWriter()
                    writer.raw(PeerInitMessage.peerInit(username: self.username, type: "F").frame)
                    writer.u32(token)  // FileTransferInit
                    connection.send(content: writer.data, completion: .contentProcessed { _ in })
                    self.receive(on: connection, onData: { [weak self, weak link] data in
                        guard let self, let link else { return }
                        self.handleFileData(link, data)
                    }, onClose: { [weak self, weak link] _ in
                        guard let self, let link else { return }
                        self.closeFile(link, reason: nil)
                    })
                case .waiting, .failed:
                    self.closeFile(link, reason: nil)
                default:
                    break
                }
            }
            connection.start(queue: self.queue)
        }
    }

    private func handleUploadOffset(_ link: FileLink, _ data: Data) {
        guard link.handle == nil, !link.uploadDone else { return }
        link.pending.append(data)
        guard link.pending.count >= 8 else { return }
        var reader = ByteReader(link.pending)
        guard let offset = try? reader.u64(), let job = activeUpload else { return }
        link.pending = Data()

        do {
            let handle = try FileHandle(forReadingFrom: job.share.url)
            let start = min(offset, job.share.size)
            try handle.seek(toOffset: start)
            link.handle = handle
            link.sentBytes = start
        } catch {
            closeFile(link, reason: nil)
            return
        }
        emitUpload(username: job.username, path: job.path, state: .transferring, sent: link.sentBytes, size: job.share.size)
        sendNextUploadChunk(link)
    }

    private func sendNextUploadChunk(_ link: FileLink) {
        guard !link.isClosed, let handle = link.handle else { return }
        let chunk: Data
        do {
            chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
        } catch {
            closeFile(link, reason: nil)
            return
        }
        if chunk.isEmpty {
            // Everything sent. The downloader closes the connection when it has it all.
            link.uploadDone = true
            try? handle.close()
            link.handle = nil
            return
        }
        link.connection.send(content: chunk, completion: .contentProcessed { [weak self, weak link] error in
            guard let self, let link else { return }
            if error != nil {
                self.closeFile(link, reason: nil)
            } else {
                link.sentBytes += UInt64(chunk.count)
                if Date().timeIntervalSince(link.lastProgress) > 0.5, let job = self.activeUpload {
                    link.lastProgress = Date()
                    self.emitUpload(username: job.username, path: job.path, state: .transferring,
                                    sent: link.sentBytes, size: job.share.size)
                }
                self.sendNextUploadChunk(link)
            }
        })
    }

    private func finishUpload(token: UInt32, succeeded: Bool) {
        guard let job = activeUpload, job.token == token else { return }
        emitUpload(username: job.username, path: job.path, state: succeeded ? .completed : .failed,
                   sent: succeeded ? job.share.size : 0, size: job.share.size)
        if succeeded {
            completedUploads += 1
            log("Uploaded \(job.path) to \(job.username)")
        } else if job.started && isLoggedIn {
            sendToPeer(job.username, [.uploadFailed(filename: job.path)])
        }
        activeUpload = nil
        startNextUpload()
    }

    private func sharedFolders() -> [SharedFolder] {
        var grouped: [String: [SharedFile]] = [:]
        for share in shares.values {
            let parts = Self.splitVirtualPath(share.virtualPath)
            grouped[parts.folder, default: []].append(SharedFile(path: parts.name, size: share.size))
        }
        return grouped.keys.sorted().map { SharedFolder(name: $0, files: grouped[$0] ?? []) }
    }

    private static func splitVirtualPath(_ path: String) -> (folder: String, name: String) {
        guard let separator = path.lastIndex(of: "\\") else { return ("", path) }
        return (String(path[..<separator]), String(path[path.index(after: separator)...]))
    }

    // MARK: - Helpers

    private func receive(on connection: NWConnection, onData: @escaping (Data) -> Void, onClose: @escaping (NWError?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty { onData(data) }
            if isComplete || error != nil {
                onClose(error)
                return
            }
            self?.receive(on: connection, onData: onData, onClose: onClose)
        }
    }

    private static func tcpParameters(timeout: Int) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 60
        tcp.connectionTimeout = timeout
        tcp.noDelay = true
        return NWParameters(tls: nil, tcp: tcp)
    }

    private func tokenKey(_ username: String, _ token: UInt32) -> String { "\(username)|\(token)" }

    private func emitUpload(username: String, path: String, state: UploadState, sent: UInt64, size: UInt64) {
        emit(.upload(UploadUpdate(id: DownloadID(username: username, path: path), state: state, sent: sent, size: size)))
    }

    private func emitDownload(_ id: DownloadID) {
        guard let record = downloads[id] else { return }
        emit(.download(DownloadUpdate(id: id, state: record.state, received: record.received, size: record.size)))
    }

    private func log(_ message: String) { emit(.log(message)) }

    private func emit(_ event: ClientEvent) {
        let handler = onEvent
        DispatchQueue.main.async { handler?(event) }
    }
}

// MARK: - Internal state

private struct PeerAddress {
    let ip: String
    let port: UInt32
}

private final class PeerLink {
    let username: String
    var connection: NWConnection?
    var frames = FrameBuffer()
    var isReady = false
    var isClosed = false
    var outbox: [Data] = []
    var sentHandlers: [() -> Void] = []
    var failureHandlers: [() -> Void] = []

    init(username: String) {
        self.username = username
    }
}

private final class FileLink {
    enum Role {
        case awaitingToken
        case downloading(DownloadID)
        case uploading(UInt32)
    }

    let username: String
    let connection: NWConnection
    var role: Role
    var pending = Data()
    var handle: FileHandle?
    var isClosed = false
    var uploadDone = false
    var sentBytes: UInt64 = 0
    var lastProgress = Date.distantPast

    init(username: String, connection: NWConnection, role: Role) {
        self.username = username
        self.connection = connection
        self.role = role
    }
}

private struct DownloadRecord {
    let id: DownloadID
    var state: DownloadState
    var size: UInt64
    var received: UInt64 = 0
    var token: UInt32?
    var retries = 0
}

private struct FolderBrowse {
    let username: String
    let folder: String
    let completion: ([SharedFile]?) -> Void
}

private struct UploadJob {
    let username: String
    let path: String
    let share: LocalShare
    var token: UInt32 = 0
    var started = false
}
#endif
