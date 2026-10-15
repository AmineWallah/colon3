import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

struct SpotifyPlaylist: Identifiable, Hashable {
    let id: String
    let name: String
    let owner: String
    /// Nil when Spotify doesn't say (it hides the count of playlists you don't own).
    let trackCount: Int?
    let imageURL: URL?
    /// Development-mode apps can only read the songs of playlists you own or collaborate on.
    let isReadable: Bool
}

/// Your own Spotify developer app, used to read your playlists and Liked Songs.
///
/// Authorization Code with PKCE through ASWebAuthenticationSession, so no client secret is
/// needed. The Client ID is saved in settings; the refresh token goes in the Keychain.
@MainActor
final class SpotifyService: ObservableObject {
    /// Only editable while logged out (Settings hides the field otherwise).
    @Published var clientID: String {
        didSet { UserDefaults.standard.set(clientID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "spotify.clientID") }
    }
    @Published private(set) var isLoggedIn: Bool
    @Published private(set) var displayName: String?
    @Published private(set) var isLoggingIn = false

    static let redirectURI = "colon3://spotify-callback"
    static let scopes = "playlist-read-private playlist-read-collaborative user-library-read"
    private static let keychainService = "colon3.spotify"

    enum SpotifyError: LocalizedError {
        case message(String)
        /// The token endpoint turned the request down (bad code, revoked or expired refresh token).
        case rejected(String)
        var errorDescription: String? {
            switch self {
            case let .message(text): return text
            case let .rejected(reason): return "Spotify login failed: \(reason)"
            }
        }
    }

    private var accessToken: String?
    private var accessTokenExpiry = Date.distantPast
    private var userID: String?
    private var authSession: ASWebAuthenticationSession?
    private var authAnchor: AuthAnchor?
    private var loginContinuation: CheckedContinuation<URL, Error>?

    init() {
        clientID = UserDefaults.standard.string(forKey: "spotify.clientID") ?? ""
        isLoggedIn = Keychain.load(account: "refreshToken", service: Self.keychainService) != nil
        displayName = UserDefaults.standard.string(forKey: "spotify.displayName")
    }

    private var trimmedClientID: String { clientID.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: Login

    func logIn() async throws {
        let client = trimmedClientID
        guard !client.isEmpty else { throw SpotifyError.message("Enter your app's Client ID first.") }
        isLoggingIn = true
        defer { isLoggingIn = false }

        let verifier = Self.randomString(length: 64)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomString(length: 16)
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: client),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "state", value: state),
        ]
        guard let authorizeURL = components.url else { throw SpotifyError.message("Couldn't build the login address.") }

        let callback = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            self.beginAuthSession(url: authorizeURL, continuation: continuation)
        }

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            throw SpotifyError.message(error == "access_denied" ? "Spotify access was declined." : "Spotify said: \(error)")
        }
        guard items.first(where: { $0.name == "state" })?.value == state else {
            throw SpotifyError.message("Spotify's reply didn't match this login. Try again.")
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw SpotifyError.message("Spotify didn't send a login code.")
        }

        let tokens = try await tokenRequest([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": client,
            "code_verifier": verifier,
        ])
        try store(tokens)
        isLoggedIn = true

        let me = try await get("https://api.spotify.com/v1/me")
        userID = me["id"] as? String
        let name = (me["display_name"] as? String) ?? userID
        displayName = name
        UserDefaults.standard.set(name, forKey: "spotify.displayName")
    }

    func logOut() {
        Keychain.delete(account: "refreshToken", service: Self.keychainService)
        UserDefaults.standard.removeObject(forKey: "spotify.displayName")
        accessToken = nil
        accessTokenExpiry = .distantPast
        userID = nil
        displayName = nil
        isLoggedIn = false
    }

    private func beginAuthSession(url: URL, continuation: CheckedContinuation<URL, Error>) {
        loginContinuation = continuation
        let session = ASWebAuthenticationSession(url: url, callback: .customScheme("colon3")) { [weak self] callbackURL, error in
            Task { @MainActor in
                self?.finishAuthSession(callbackURL: callbackURL, error: error)
            }
        }
        let anchor = AuthAnchor(window: Self.keyWindow() ?? UIWindow())
        session.presentationContextProvider = anchor
        // Reuses a Spotify login already in Safari, so usually it's one tap.
        session.prefersEphemeralWebBrowserSession = false
        authSession = session
        authAnchor = anchor
        if !session.start() {
            finishAuthSession(callbackURL: nil, error: SpotifyError.message("Couldn't open the Spotify login."))
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
            continuation.resume(throwing: SpotifyError.message("Login cancelled."))
        } else {
            continuation.resume(throwing: error ?? SpotifyError.message("Login didn't finish."))
        }
    }

    private static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }

    // MARK: Tokens

    private func tokenRequest(_ parameters: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = HTTP.formBody(parameters)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let reason = json["error_description"] as? String ?? json["error"] as? String ?? "HTTP \(status)"
            if status == 400 || status == 401 { throw SpotifyError.rejected(reason) }
            throw SpotifyError.message("Spotify login failed: \(reason)")
        }
        return json
    }

    private func store(_ tokens: [String: Any]) throws {
        guard let access = tokens["access_token"] as? String else {
            throw SpotifyError.message("Spotify didn't send an access token.")
        }
        accessToken = access
        let lifetime = (tokens["expires_in"] as? Double) ?? 3600
        accessTokenExpiry = Date().addingTimeInterval(lifetime - 60)
        // Spotify may rotate the refresh token; keep the newest.
        if let refresh = tokens["refresh_token"] as? String {
            Keychain.save(refresh, account: "refreshToken", service: Self.keychainService)
        }
    }

    private func validAccessToken() async throws -> String {
        if let accessToken, Date() < accessTokenExpiry { return accessToken }
        guard let refresh = Keychain.load(account: "refreshToken", service: Self.keychainService) else {
            isLoggedIn = false
            throw SpotifyError.message("Log in to Spotify first.")
        }
        do {
            let tokens = try await tokenRequest([
                "grant_type": "refresh_token",
                "refresh_token": refresh,
                "client_id": trimmedClientID,
            ])
            try store(tokens)
        } catch SpotifyError.rejected {
            // A revoked or expired refresh token: ask for a new login. (Network errors don't.)
            logOut()
            throw SpotifyError.message("Your Spotify login expired. Log in again.")
        }
        guard let accessToken else { throw SpotifyError.message("Spotify didn't send an access token.") }
        return accessToken
    }

    // MARK: API

    private func get(_ address: String) async throws -> [String: Any] {
        guard let url = URL(string: address) else { throw SpotifyError.message("Bad Spotify address.") }
        var refreshed = false
        var attempts = 0
        while true {
            attempts += 1
            let token = try await validAccessToken()
            var request = URLRequest(url: url)
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200:
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw SpotifyError.message("Unexpected reply from Spotify.")
                }
                return json
            case 401 where !refreshed:
                // Expired early or revoked: refresh once and try again.
                refreshed = true
                accessToken = nil
                continue
            case 429 where attempts < 4:
                let wait = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap { Double($0) } ?? 5
                try await Task.sleep(nanoseconds: UInt64(min(max(wait, 1), 30) * 1_000_000_000))
                continue
            case 403:
                throw SpotifyError.message("Spotify refused this. Development apps can only read playlists you own or collaborate on, and the app owner needs Premium.")
            default:
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let message = (json?["error"] as? [String: Any])?["message"] as? String
                let detail = message.map { ": " + $0 } ?? ""
                throw SpotifyError.message("Spotify error \(status)\(detail).")
            }
        }
    }

    private func currentUserID() async throws -> String? {
        if let userID { return userID }
        let me = try await get("https://api.spotify.com/v1/me")
        userID = me["id"] as? String
        if let name = (me["display_name"] as? String) ?? userID {
            displayName = name
            UserDefaults.standard.set(name, forKey: "spotify.displayName")
        }
        return userID
    }

    func playlists() async throws -> [SpotifyPlaylist] {
        let me = try await currentUserID()
        var result: [SpotifyPlaylist] = []
        var next: String? = "https://api.spotify.com/v1/me/playlists?limit=50"
        while let address = next {
            let page = try await get(address)
            for item in page["items"] as? [[String: Any]] ?? [] {
                guard let id = item["id"] as? String else { continue }
                let owner = item["owner"] as? [String: Any]
                let ownerID = owner?["id"] as? String
                let collaborative = item["collaborative"] as? Bool ?? false
                // Renamed from "tracks" to "items" in 2026; read either.
                let counts = (item["items"] as? [String: Any]) ?? (item["tracks"] as? [String: Any])
                let image = (item["images"] as? [[String: Any]])?.first?["url"] as? String
                result.append(SpotifyPlaylist(
                    id: id,
                    name: item["name"] as? String ?? "Untitled",
                    owner: owner?["display_name"] as? String ?? ownerID ?? "",
                    trackCount: counts?["total"] as? Int,
                    imageURL: image.flatMap { URL(string: $0) },
                    isReadable: collaborative || (me != nil && ownerID == me)))
            }
            next = page["next"] as? String
        }
        return result
    }

    func likedSongsCount() async throws -> Int {
        let page = try await get("https://api.spotify.com/v1/me/tracks?limit=1")
        return page["total"] as? Int ?? 0
    }

    /// Songs in playlist order. `progress` gets (loaded, total) after each page.
    func songs(inPlaylist id: String?, progress: (Int, Int) -> Void) async throws -> [WantedSong] {
        let first = id.map { "https://api.spotify.com/v1/playlists/\($0)/items?limit=50&additional_types=track" }
            ?? "https://api.spotify.com/v1/me/tracks?limit=50"
        var songs: [WantedSong] = []
        var seen = 0
        var next: String? = first
        while let address = next {
            let page = try await get(address)
            let entries = page["items"] as? [[String: Any]] ?? []
            for entry in entries {
                // Playlist entries hold "item" since 2026 ("track" before); Liked Songs use "track".
                guard let track = (entry["item"] as? [String: Any]) ?? (entry["track"] as? [String: Any]),
                      (track["type"] as? String ?? "track") == "track",
                      let title = track["name"] as? String, !title.isEmpty else { continue }
                let artists = (track["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
                let album = (track["album"] as? [String: Any])?["name"] as? String
                let milliseconds = (track["duration_ms"] as? Double) ?? 0
                songs.append(WantedSong(title: title, artists: artists,
                                        album: album, duration: milliseconds > 0 ? milliseconds / 1000 : nil))
            }
            seen += entries.count
            progress(seen, page["total"] as? Int ?? seen)
            next = page["next"] as? String
        }
        return songs
    }

    // MARK: Helpers

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

/// Tells the login sheet which window to appear over.
private final class AuthAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let window: UIWindow

    init(window: UIWindow) {
        self.window = window
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        window
    }
}
