import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import UIKit

/// Discord Rich Presence through Discord's Social SDK: "Listening to colon3" with the song,
/// artist, album cover and a progress bar on your profile, while music plays.
///
/// Linking is OAuth2 with PKCE against the colon3 Discord application (public client), done
/// here with ASWebAuthenticationSession; the SDK then gets the access token and keeps the
/// presence up. The SDK itself is closed source and can't be in the public repository, so it's
/// only in builds made with it (COLON3_DISCORD); other builds explain that in Settings.
@MainActor
final class DiscordPresence: ObservableObject {
    enum Connection: Equatable {
        case off
        case connecting
        case connected
        case failed(String)
    }

    /// What's shown on Discord, after the length rules (2 to 128 characters).
    struct Content: Equatable {
        var title: String
        var artist: String
        var album: String?
        var coverURL: String?
        var startMs: Int64
        var endMs: Int64
    }

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "discord.enabled")
            if enabled != oldValue { enabled ? start() : stop() }
        }
    }
    @Published private(set) var isLinked: Bool
    @Published private(set) var isLinking = false
    @Published private(set) var connection: Connection = .off
    /// Set when Discord turned down "Listening" and the presence fell back to "Playing".
    @Published private(set) var showsAsPlaying = false

    static let keychainService = "colon3.discord-social"

    /// The Discord application ID built in (COLON3_DISCORD_APP_ID), if any.
    static let applicationID: String = {
        let value = (Bundle.main.object(forInfoDictionaryKey: "Colon3DiscordAppID") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.hasPrefix("$(") ? "" : value
    }()

    /// This build has Discord's SDK compiled in.
    static var sdkIncluded: Bool {
        #if COLON3_DISCORD
        return true
        #else
        return false
        #endif
    }

    static var isAvailable: Bool { sdkIncluded && UInt64(applicationID) != nil }

    private let player: Player
    private let library: LibraryStore
    private var backend: DiscordBackend?
    private var timer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    private var sent: Content?
    private var lastSend = Date.distantPast
    private var lastTokenCheck = Date()
    private var sendScheduled = false
    private var listeningRejected: Bool
    /// Discord turned down the artist as the activity name ("Listening to <artist>").
    private var artistNameRejected: Bool
    private var coverURLs: [String: String] = [:]
    private var coverMisses: Set<String> = []
    private var coverLookups: Set<String> = []
    private var authSession: ASWebAuthenticationSession?
    private var authAnchor: DiscordAuthAnchor?
    private var loginContinuation: CheckedContinuation<URL, Error>?

    init(player: Player, library: LibraryStore) {
        self.player = player
        self.library = library
        let defaults = UserDefaults.standard
        enabled = defaults.bool(forKey: "discord.enabled")
        listeningRejected = defaults.bool(forKey: "discord.listeningRejected")
        artistNameRejected = defaults.bool(forKey: "discord.artistNameRejected")
        isLinked = Keychain.load(account: "refreshToken", service: Self.keychainService) != nil
        showsAsPlaying = listeningRejected
        coverURLs = defaults.dictionary(forKey: "discord.covers") as? [String: String] ?? [:]

        // Anything about the song or playing state changing: update (debounced).
        player.objectWillChange
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            .store(in: &subscriptions)

        if enabled, isLinked { start() }
    }

    // MARK: Linking

    enum DiscordError: LocalizedError {
        case message(String)
        case rejected(String)
        var errorDescription: String? {
            switch self {
            case let .message(text): return text
            case let .rejected(reason): return "Discord said: \(reason)"
            }
        }
    }

    private var redirectScheme: String { "discord-" + Self.applicationID }
    private var redirectURI: String { redirectScheme + ":/authorize/callback" }

    private var scopes: String {
        #if COLON3_DISCORD
        return C3DiscordBridge.presenceScopes()
        #else
        return "openid sdk.social_layer_presence"
        #endif
    }

    /// Signs in with Discord (browser sheet, reusing a Safari login) and turns presence on.
    func link() async throws {
        guard Self.isAvailable else { throw DiscordError.message("Discord isn't set up in this build of colon3.") }
        isLinking = true
        defer { isLinking = false }

        let verifier = Self.randomString(length: 64)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomString(length: 16)
        var components = URLComponents(string: "https://discord.com/oauth2/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.applicationID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let authorizeURL = components.url else { throw DiscordError.message("Couldn't build the sign-in address.") }

        let callback = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            self.beginAuthSession(url: authorizeURL, continuation: continuation)
        }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            throw DiscordError.message(error == "access_denied" ? "Discord access was declined." : "Discord said: \(error)")
        }
        guard items.first(where: { $0.name == "state" })?.value == state else {
            throw DiscordError.message("Discord's reply didn't match this sign-in. Try again.")
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw DiscordError.message("Discord didn't send a sign-in code.")
        }
        let tokens = try await tokenRequest([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": Self.applicationID,
            "code_verifier": verifier,
        ])
        try store(tokens)
        isLinked = true
        if enabled {
            stop()
            start()
        } else {
            enabled = true
        }
    }

    /// Signs out: presence off, tokens forgotten and revoked.
    func unlink() {
        enabled = false
        stop()
        if let token = Keychain.load(account: "refreshToken", service: Self.keychainService) {
            var request = URLRequest(url: URL(string: "https://discord.com/api/oauth2/token/revoke")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = HTTP.formBody(["token": token, "token_type_hint": "refresh_token", "client_id": Self.applicationID])
            let revoke = request
            Task.detached { _ = try? await URLSession.shared.data(for: revoke) }
        }
        for account in ["accessToken", "refreshToken"] {
            Keychain.delete(account: account, service: Self.keychainService)
        }
        UserDefaults.standard.removeObject(forKey: "discord.tokenExpiry")
        isLinked = false
        connection = .off
    }

    private func beginAuthSession(url: URL, continuation: CheckedContinuation<URL, Error>) {
        loginContinuation = continuation
        let session = ASWebAuthenticationSession(url: url, callback: .customScheme(redirectScheme)) { [weak self] callbackURL, error in
            Task { @MainActor in
                self?.finishAuthSession(callbackURL: callbackURL, error: error)
            }
        }
        let anchor = DiscordAuthAnchor(window: Self.keyWindow() ?? UIWindow())
        session.presentationContextProvider = anchor
        session.prefersEphemeralWebBrowserSession = false
        authSession = session
        authAnchor = anchor
        if !session.start() {
            finishAuthSession(callbackURL: nil, error: DiscordError.message("Couldn't open the Discord sign-in."))
        }
    }

    private func finishAuthSession(callbackURL: URL?, error: Error?) {
        guard let continuation = loginContinuation else { return }
        loginContinuation = nil
        authSession = nil
        authAnchor = nil
        if let callbackURL {
            continuation.resume(returning: callbackURL)
        } else if let authError = error as? ASWebAuthenticationSessionError, authError.code == .canceledLogin {
            continuation.resume(throwing: DiscordError.message("Sign-in cancelled."))
        } else {
            continuation.resume(throwing: error ?? DiscordError.message("Sign-in didn't finish."))
        }
    }

    private static func keyWindow() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }

    // MARK: Tokens

    private func tokenRequest(_ parameters: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://discord.com/api/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = HTTP.formBody(parameters)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let reason = json["error_description"] as? String ?? json["error"] as? String ?? "HTTP \(status)"
            if status == 400 || status == 401 { throw DiscordError.rejected(reason) }
            throw DiscordError.message("Discord sign-in failed: \(reason)")
        }
        return json
    }

    private func store(_ tokens: [String: Any]) throws {
        guard let access = tokens["access_token"] as? String else {
            throw DiscordError.message("Discord didn't send an access token.")
        }
        Keychain.save(access, account: "accessToken", service: Self.keychainService)
        if let refresh = tokens["refresh_token"] as? String {
            Keychain.save(refresh, account: "refreshToken", service: Self.keychainService)
        }
        let lifetime = (tokens["expires_in"] as? Double) ?? 604_800
        UserDefaults.standard.set(Date().addingTimeInterval(lifetime), forKey: "discord.tokenExpiry")
    }

    /// The access token, refreshed when it has less than a day left (they last a week).
    private func validAccessToken() async throws -> String {
        let expiry = UserDefaults.standard.object(forKey: "discord.tokenExpiry") as? Date ?? .distantPast
        if let access = Keychain.load(account: "accessToken", service: Self.keychainService),
           expiry.timeIntervalSinceNow > 86_400 {
            return access
        }
        guard let refresh = Keychain.load(account: "refreshToken", service: Self.keychainService) else {
            isLinked = false
            throw DiscordError.message("Connect Discord first.")
        }
        do {
            try store(try await tokenRequest([
                "grant_type": "refresh_token",
                "refresh_token": refresh,
                "client_id": Self.applicationID,
            ]))
        } catch DiscordError.rejected(_) {
            unlink()
            throw DiscordError.message("Your Discord sign-in expired or was removed. Connect Discord again.")
        }
        guard let access = Keychain.load(account: "accessToken", service: Self.keychainService) else {
            throw DiscordError.message("Discord didn't send an access token.")
        }
        return access
    }

    // MARK: Connection

    private func start() {
        guard enabled, isLinked, Self.isAvailable, backend == nil else { return }
        guard let backend = Self.makeBackend() else { return }
        self.backend = backend
        connection = .connecting
        backend.onStatus = { [weak self] status, error, detail in
            MainActor.assumeIsolated { self?.statusChanged(status, error: error, detail: detail) }
        }
        backend.onLog = { message in
            Diagnostics.shared.log("Discord SDK: \(message)", category: "discord")
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        Task {
            do {
                let token = try await validAccessToken()
                guard self.backend === backend else { return }
                backend.connect(token: token) { [weak self] error in
                    MainActor.assumeIsolated {
                        guard let self, let error else { return }
                        self.connection = .failed(error)
                        Diagnostics.shared.log("Discord: token not accepted: \(error)", category: "discord")
                    }
                }
            } catch {
                self.connection = .failed(error.localizedDescription)
                self.stop(keepState: true)
            }
        }
    }

    private func stop(keepState: Bool = false) {
        backend?.clearPresence()
        backend?.disconnect()
        // Let the disconnect go out before the client is released.
        backend?.runCallbacks()
        backend = nil
        timer?.invalidate()
        timer = nil
        sent = nil
        if !keepState { connection = .off }
    }

    private func statusChanged(_ status: Int, error: Int, detail: Int) {
        switch status {
        case 3:  // Ready
            connection = .connected
            sent = nil
            refresh()
        case 0 where error != 0:
            connection = .failed("Disconnected (error \(error), \(detail))")
            Diagnostics.shared.log("Discord: disconnected, error \(error) detail \(detail)", category: "discord")
        case 0:
            connection = .off
        default:
            if connection != .connected { connection = .connecting }
        }
    }

    private func tick() {
        backend?.runCallbacks()
        // Access tokens last a week: in a long session (Seeding Mode), hand over a fresh one.
        if let backend, Date().timeIntervalSince(lastTokenCheck) > 6 * 3600 {
            lastTokenCheck = Date()
            Task {
                guard let token = try? await self.validAccessToken(), self.backend === backend else { return }
                backend.updateToken(token)
            }
        }
        // A seek moves the song without any published change: catch it here.
        guard let sent, player.isPlaying, connection == .connected else { return }
        let rate = Double(max(player.playbackRate, 0.1))
        let expected = (Date().timeIntervalSince1970 * 1000 - Double(sent.startMs)) / 1000 * rate
        if abs(expected - player.position) > 3 { refresh() }
    }

    // MARK: Presence

    /// Sends what's playing now (or clears it when paused), at most once every 4 seconds.
    private func refresh() {
        guard let backend, connection == .connected else { return }
        guard player.isPlaying, let track = player.current else {
            if sent != nil {
                backend.clearPresence()
                sent = nil
            }
            return
        }
        let wait = 4 - Date().timeIntervalSince(lastSend)
        if wait > 0 {
            guard !sendScheduled else { return }
            sendScheduled = true
            Task {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                self.sendScheduled = false
                self.refresh()
            }
            return
        }

        let content = makeContent(for: track)
        if let sent, sent.title == content.title, sent.artist == content.artist, sent.album == content.album,
           sent.coverURL == content.coverURL, abs(sent.startMs - content.startMs) < 2000 {
            return
        }
        send(content, listening: !listeningRejected, artistAsName: !artistNameRejected, via: backend)
    }

    /// `artistAsName`: "Listening to <artist>" instead of "Listening to colon3". If Discord
    /// refuses, it tries again without the artist name, then as "Playing".
    private func send(_ content: Content, listening: Bool, artistAsName: Bool, via backend: DiscordBackend) {
        sent = content
        lastSend = Date()
        backend.setPresence(content, listening: listening, artistAsName: artistAsName) { [weak self] error in
            MainActor.assumeIsolated {
                guard let self, let error else { return }
                Diagnostics.shared.log("Discord: presence not accepted (\(listening ? "Listening" : "Playing")\(artistAsName ? ", artist as name" : "")): \(error)", category: "discord")
                if artistAsName {
                    self.artistNameRejected = true
                    UserDefaults.standard.set(true, forKey: "discord.artistNameRejected")
                    if let current = self.backend { self.send(content, listening: listening, artistAsName: false, via: current) }
                } else if listening {
                    // Discord may only take "Playing" from the SDK: fall back, and remember.
                    self.listeningRejected = true
                    self.showsAsPlaying = true
                    UserDefaults.standard.set(true, forKey: "discord.listeningRejected")
                    if let current = self.backend { self.send(content, listening: false, artistAsName: false, via: current) }
                } else {
                    self.sent = nil
                }
            }
        }
    }

    /// Try "Listening" again (after Discord changes something).
    func retryListening() {
        listeningRejected = false
        artistNameRejected = false
        showsAsPlaying = false
        UserDefaults.standard.removeObject(forKey: "discord.listeningRejected")
        UserDefaults.standard.removeObject(forKey: "discord.artistNameRejected")
        sent = nil
        refresh()
    }

    private func makeContent(for track: Track) -> Content {
        let album = library.album(containing: track)?.title ?? track.album
        let rate = Double(max(player.playbackRate, 0.1))
        let now = Date().timeIntervalSince1970 * 1000
        let start = now - player.position / rate * 1000
        let duration = player.duration > 0 ? player.duration : track.duration
        let end = duration > 0 ? start + duration / rate * 1000 : 0
        return Content(title: Self.field(track.title) ?? "Unknown Song",
                       artist: Self.field(track.artist) ?? "Unknown Artist",
                       album: album.flatMap(Self.field),
                       coverURL: coverURL(artist: track.albumArtist ?? track.artist, album: album, title: track.title),
                       startMs: Int64(start),
                       endMs: Int64(end))
    }

    /// Discord wants 2 to 128 characters.
    private static func field(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count < 2 { return trimmed + "\u{200B}" }
        return trimmed.count > 128 ? String(trimmed.prefix(127)) + "\u{2026}" : trimmed
    }

    // MARK: Covers

    /// Discord can only show images from the web, so covers come from Apple's catalogue (the
    /// iTunes Search API): the cached address, or nil while it's looked up (the presence
    /// updates once it's found).
    private func coverURL(artist: String, album: String?, title: String) -> String? {
        let key = (artist + "|" + (album ?? title)).lowercased()
        if let url = coverURLs[key] { return url }
        guard !coverMisses.contains(key), !coverLookups.contains(key) else { return nil }
        coverLookups.insert(key)
        let term = artist + " " + (album ?? title)
        let entity = album == nil ? "song" : "album"
        Task {
            let url = await Self.lookUpCover(term: term, entity: entity)
            self.coverLookups.remove(key)
            if let url {
                self.coverURLs[key] = url
                if self.coverURLs.count > 500 { self.coverURLs.removeAll() }
                UserDefaults.standard.set(self.coverURLs, forKey: "discord.covers")
                self.sent = nil
                self.refresh()
            } else {
                self.coverMisses.insert(key)
            }
        }
        return nil
    }

    private nonisolated static func lookUpCover(term: String, entity: String) async -> String? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: entity),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = components.url,
              let reply = try? await URLSession.shared.data(from: url),
              (reply.1 as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: reply.0) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let small = results.first?["artworkUrl100"] as? String else { return nil }
        let large = small.replacingOccurrences(of: "100x100bb", with: "512x512bb")
        return large.count <= 300 ? large : nil
    }

    // MARK: Helpers

    private static func makeBackend() -> DiscordBackend? {
        #if COLON3_DISCORD
        guard let id = UInt64(applicationID) else { return nil }
        return SocialSDKBackend(applicationID: id)
        #else
        return nil
        #endif
    }

    private static func randomString(length: Int) -> String {
        let characters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in characters.randomElement(using: &generator)! })
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// What DiscordPresence needs from the SDK.
@MainActor
protocol DiscordBackend: AnyObject {
    var onStatus: ((Int, Int, Int) -> Void)? { get set }
    var onLog: ((String) -> Void)? { get set }
    func connect(token: String, completion: @escaping (String?) -> Void)
    func updateToken(_ token: String)
    func disconnect()
    func runCallbacks()
    func setPresence(_ content: DiscordPresence.Content, listening: Bool, artistAsName: Bool,
                     completion: @escaping (String?) -> Void)
    func clearPresence()
}

#if COLON3_DISCORD
/// The Social SDK, through the Objective-C++ bridge in DiscordBridge/.
@MainActor
final class SocialSDKBackend: DiscordBackend {
    private let bridge: C3DiscordBridge

    init(applicationID: UInt64) {
        bridge = C3DiscordBridge(applicationID: applicationID)
    }

    var onStatus: ((Int, Int, Int) -> Void)? {
        didSet {
            let handler = onStatus
            bridge.onStatus = { status, error, detail in handler?(status, error, detail) }
        }
    }

    var onLog: ((String) -> Void)? {
        didSet {
            let handler = onLog
            bridge.onLog = { message in handler?(message) }
        }
    }

    func connect(token: String, completion: @escaping (String?) -> Void) {
        bridge.connect(accessToken: token) { error in completion(error) }
    }

    func updateToken(_ token: String) { bridge.updateAccessToken(token) }
    func disconnect() { bridge.disconnect() }
    func runCallbacks() { bridge.runCallbacks() }

    /// With the artist as the name, the lines under it are the song and the album (the artist
    /// is already in the heading); otherwise the song and the artist.
    func setPresence(_ content: DiscordPresence.Content, listening: Bool, artistAsName: Bool,
                     completion: @escaping (String?) -> Void) {
        bridge.setPresence(name: artistAsName ? content.artist : nil,
                           details: content.title,
                           state: artistAsName ? (content.album ?? content.artist) : content.artist,
                           largeText: content.album,
                           imageURL: content.coverURL,
                           startMilliseconds: content.startMs,
                           endMilliseconds: content.endMs,
                           listening: listening) { error in completion(error) }
    }

    func clearPresence() { bridge.clearPresence() }
}
#endif

/// Tells the Discord sign-in sheet which window to appear over.
private final class DiscordAuthAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let window: UIWindow

    init(window: UIWindow) {
        self.window = window
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        window
    }
}
