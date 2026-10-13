import Combine
import Foundation

/// "Listening to …" on your Discord profile, Kizzy-style: the app opens its own connection to
/// Discord's gateway as you (with your account token) and updates your activity.
///
/// Discord has no official way for an iPhone app to set rich presence (RPC needs the desktop
/// client), so this uses the token. That's against Discord's Terms of Service and could get the
/// account flagged; the token is kept in the Keychain and only ever sent to discord.com.
/// Presence lasts while colon3 runs, which it does while music plays.
@MainActor
final class DiscordPresence: ObservableObject {
    enum Status: Equatable {
        case off
        case connecting
        case connected(String)
        case failed(String)
    }

    enum OnlineStatus: String, CaseIterable, Identifiable {
        case online, idle, dnd, invisible
        var id: String { rawValue }
        var label: String {
            switch self {
            case .online: return "Online"
            case .idle: return "Idle"
            case .dnd: return "Do Not Disturb"
            case .invisible: return "Invisible"
            }
        }
    }

    @Published private(set) var status: Status = .off
    @Published var applicationID: String {
        didSet {
            UserDefaults.standard.set(applicationID.trimmingCharacters(in: .whitespaces), forKey: "discord.applicationID")
            imageCache.removeAll()
            pushPresence()
        }
    }
    @Published var onlineStatus: OnlineStatus {
        didSet {
            UserDefaults.standard.set(onlineStatus.rawValue, forKey: "discord.status")
            pushPresence()
        }
    }
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: AppSettings.discordKey)
            if enabled { connect() } else { disconnect() }
        }
    }

    var hasToken: Bool { Keychain.load(account: Self.tokenAccount, service: Self.keychainService) != nil }

    private static let keychainService = "colon3.discord"
    private static let tokenAccount = "token"
    private static let gatewayURL = URL(string: "wss://gateway.discord.gg/?v=10&encoding=json")!

    private weak var player: Player?
    private var socket: URLSessionWebSocketTask?
    private var heartbeatTask: Task<Void, Never>?
    private var sequence: Int?
    private var connectionID = 0
    private var retryDelay: UInt64 = 5
    private var playerSubscription: AnyCancellable?
    private var lastSent: String?
    /// Album key → "mp:external/…" asset path (or "" when no image).
    private var imageCache: [String: String] = [:]

    init() {
        applicationID = UserDefaults.standard.string(forKey: "discord.applicationID") ?? ""
        onlineStatus = OnlineStatus(rawValue: UserDefaults.standard.string(forKey: "discord.status") ?? "") ?? .online
        enabled = UserDefaults.standard.bool(forKey: AppSettings.discordKey)
    }

    func attach(_ player: Player) {
        self.player = player
        playerSubscription = player.stateChanged
            // Discord allows 5 presence updates per 20 s.
            .throttle(for: .seconds(4), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] in
                MainActor.assumeIsolated { self?.playerChanged() }
            }
        if enabled { connect() }
    }

    func saveToken(_ token: String) {
        // People often paste it with quotes or a "Bearer"/"Authorization:" prefix.
        var cleaned = token.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
        for prefix in ["Authorization:", "authorization:", "Bearer "] where cleaned.hasPrefix(prefix) {
            cleaned = String(cleaned.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        guard !cleaned.isEmpty else { return }
        Keychain.save(cleaned, account: Self.tokenAccount, service: Self.keychainService)
        if enabled { reconnect() } else { enabled = true }
    }

    func forgetToken() {
        Keychain.delete(account: Self.tokenAccount, service: Self.keychainService)
        enabled = false
        objectWillChange.send()
    }

    /// Called when the app comes back to the foreground; iOS may have dropped the socket.
    func resumeIfNeeded() {
        guard enabled else { return }
        switch status {
        case .off, .failed: connect()
        default: break
        }
    }

    // MARK: Connection

    private func connect() {
        guard enabled, socket == nil else { return }
        guard let token = Keychain.load(account: Self.tokenAccount, service: Self.keychainService) else {
            status = .failed("Paste your token first")
            return
        }
        connectionID += 1
        let id = connectionID
        status = .connecting
        sequence = nil
        lastSent = nil
        let task = URLSession.shared.webSocketTask(with: Self.gatewayURL)
        // A user account's READY payload can be several megabytes.
        task.maximumMessageSize = 64 * 1024 * 1024
        socket = task
        task.resume()
        receive(on: task, id: id, token: token)
    }

    private func disconnect() {
        connectionID += 1
        heartbeatTask?.cancel()
        heartbeatTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        status = .off
    }

    private func reconnect() {
        disconnect()
        connect()
    }

    private func receive(on task: URLSessionWebSocketTask, id: Int, token: String) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.connectionID == id else { return }
                switch result {
                case let .success(message):
                    var data: Data?
                    switch message {
                    case let .string(text): data = Data(text.utf8)
                    case let .data(bytes): data = bytes
                    @unknown default: break
                    }
                    if let data { self.handle(data, token: token, id: id) }
                    if self.connectionID == id { self.receive(on: task, id: id, token: token) }
                case .failure:
                    self.connectionLost(closeCode: task.closeCode.rawValue)
                }
            }
        }
    }

    private func connectionLost(closeCode: Int) {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        socket = nil
        // 4004: bad token. 4013/4014: bad intents (shouldn't happen). Don't hammer Discord.
        if closeCode == 4004 {
            status = .failed("Discord rejected the token")
            return
        }
        guard enabled else {
            status = .off
            return
        }
        status = .failed("Disconnected, retrying…")
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 300)
        let id = connectionID
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard let self, self.connectionID == id, self.enabled else { return }
            self.connect()
        }
    }

    private func handle(_ data: Data, token: String, id: Int) {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = payload["op"] as? Int else { return }
        if let seq = payload["s"] as? Int { sequence = seq }

        switch op {
        case 10:  // Hello
            let interval = ((payload["d"] as? [String: Any])?["heartbeat_interval"] as? Double) ?? 41_250
            startHeartbeat(every: interval, id: id)
            send([
                "op": 2,
                "d": [
                    "token": token,
                    "properties": ["os": "iOS", "browser": "Discord iOS", "device": "iPhone"],
                    "presence": presencePayload(),
                    "compress": false,
                ] as [String: Any],
            ])
        case 0:  // Dispatch
            if payload["t"] as? String == "READY" {
                let user = (payload["d"] as? [String: Any])?["user"] as? [String: Any]
                let name = (user?["global_name"] as? String) ?? (user?["username"] as? String) ?? "Discord"
                status = .connected(name)
                retryDelay = 5
                lastSent = nil
                pushPresence()
            }
        case 1:  // Heartbeat request
            send(["op": 1, "d": sequenceValue])
        case 7:  // Reconnect
            reconnect()
        case 9:  // Invalid session
            disconnect()
            status = .failed("Discord ended the session, retrying…")
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                guard let self, self.enabled else { return }
                self.connect()
            }
        default:
            break
        }
    }

    private func startHeartbeat(every milliseconds: Double, id: Int) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            // First beat at a random point in the interval, as Discord asks.
            var wait = UInt64(milliseconds * Double.random(in: 0.1...1) * 1_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: wait)
                guard let self, self.connectionID == id, !Task.isCancelled else { return }
                self.send(["op": 1, "d": self.sequenceValue])
                wait = UInt64(milliseconds * 1_000_000)
            }
        }
    }

    /// JSONSerialization needs NSNull, not a wrapped Optional (which would crash it).
    private var sequenceValue: Any { sequence.map { $0 as Any } ?? NSNull() }

    private func send(_ object: [String: Any]) {
        guard let socket, JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    // MARK: Presence

    private func playerChanged() {
        if enabled, socket == nil { connect() }
        pushPresence()
    }

    private func pushPresence() {
        guard case .connected = status else { return }
        let presence = presencePayload()
        // Only send real changes; Discord rate-limits presence updates (5 per 20 s).
        let signature = (try? JSONSerialization.data(withJSONObject: presence, options: .sortedKeys))
            .map { String(decoding: $0, as: UTF8.self) }
        guard signature != lastSent else { return }
        lastSent = signature
        send(["op": 3, "d": presence])

        // Fetch the cover for next time if we don't have it yet.
        if let track = player?.current, imageCache[albumKey(track)] == nil, !applicationID.isEmpty {
            let key = albumKey(track)
            imageCache[key] = ""
            Task { await self.resolveImage(for: track, key: key) }
        }
    }

    private func presencePayload() -> [String: Any] {
        var activities: [[String: Any]] = []
        if let player, let track = player.current, player.isPlaying {
            let now = Date().timeIntervalSince1970
            let start = (now - player.position).rounded()
            var activity: [String: Any] = [
                "name": "colon3",
                "type": 2,  // Listening
                "details": track.title,
                "state": track.artist,
                "status_display_type": 1,  // "Listening to <artist>" in the member list
                "timestamps": [
                    "start": Int64(start * 1000),
                    "end": Int64((start + max(player.duration, 1)) * 1000),
                ],
            ]
            let id = applicationID.trimmingCharacters(in: .whitespaces)
            if !id.isEmpty { activity["application_id"] = id }
            var assets: [String: Any] = [:]
            if let album = player.library?.album(containing: track)?.title ?? track.album {
                assets["large_text"] = album
            }
            if let image = imageCache[albumKey(track)], !image.isEmpty {
                assets["large_image"] = image
            }
            if !assets.isEmpty { activity["assets"] = assets }
            activities.append(activity)
        }
        return [
            "since": 0,
            "activities": activities,
            "status": onlineStatus.rawValue,
            "afk": false,
        ]
    }

    private func albumKey(_ track: Track) -> String {
        let album = player?.library?.album(containing: track)?.title ?? track.album ?? track.title
        return (track.albumArtist ?? track.artist) + "|" + album
    }

    /// Discord only shows images it proxies: find the cover on iTunes, then register its URL
    /// as an external asset of your application.
    private func resolveImage(for track: Track, key: String) async {
        let id = applicationID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, let token = Keychain.load(account: Self.tokenAccount, service: Self.keychainService) else { return }
        let album = player?.library?.album(containing: track)?.title ?? track.album
        let query = album.map { "\(track.albumArtist ?? track.artist) \($0)" } ?? "\(track.artist) \(track.title)"
        guard let imageURL = await CoverLookup.shared.artworkURL(query: query, entity: album == nil ? "song" : "album") else { return }

        var request = URLRequest(url: URL(string: "https://discord.com/api/v10/applications/\(id)/external-assets")!)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["urls": [imageURL]])
        guard let result = try? await URLSession.shared.data(for: request),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let list = try? JSONSerialization.jsonObject(with: result.0) as? [[String: Any]],
              let path = list.first?["external_asset_path"] as? String else { return }
        imageCache[key] = "mp:" + path
        lastSent = nil
        pushPresence()
    }
}
