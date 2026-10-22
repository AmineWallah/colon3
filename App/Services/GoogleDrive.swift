import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// A file or folder colon3 created on Google Drive.
struct DriveItem {
    let id: String
    let name: String
    let isFolder: Bool
    let size: Int64?
    let modified: Date?
}

/// Google Drive for backups, through the Drive API with the `drive.file` scope: colon3 can only
/// see and change files it created itself, nothing else in your Drive.
///
/// Sign-in is Authorization Code with PKCE through ASWebAuthenticationSession, using the iOS
/// OAuth client built into the app (the `COLON3_GOOGLE_CLIENT_ID` build setting, which ends up
/// in Info.plist as `Colon3GoogleClientID`). Builds without one can use a client ID entered in
/// Settings. The refresh token goes in the Keychain.
@MainActor
final class GoogleDrive: ObservableObject {
    @Published private(set) var isConnected: Bool
    @Published private(set) var account: String?
    @Published private(set) var isConnecting = false
    /// A client ID typed in Settings, for builds that don't have one built in.
    @Published var customClientID: String {
        didSet { UserDefaults.standard.set(customClientID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "drive.clientID") }
    }

    static let scope = "https://www.googleapis.com/auth/drive.file"
    static let folderMIME = "application/vnd.google-apps.folder"
    private static let keychainService = "colon3.drive"
    private static let api = "https://www.googleapis.com/drive/v3/"
    private static let uploadAPI = "https://www.googleapis.com/upload/drive/v3/"

    enum DriveError: LocalizedError {
        case message(String)
        /// The token endpoint turned the request down (revoked or expired sign-in).
        case rejected(String)
        /// Drive answered with an error status.
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case let .message(text): return text
            case let .rejected(reason): return "Google sign-in failed: \(reason)"
            case let .http(_, text): return text
            }
        }

        var status: Int? {
            if case let .http(status, _) = self { return status }
            return nil
        }
    }

    private var accessToken: String?
    private var accessTokenExpiry = Date.distantPast
    private var authSession: ASWebAuthenticationSession?
    private var authAnchor: DriveAuthAnchor?
    private var loginContinuation: CheckedContinuation<URL, Error>?

    init() {
        customClientID = UserDefaults.standard.string(forKey: "drive.clientID") ?? ""
        isConnected = Keychain.load(account: "refreshToken", service: Self.keychainService) != nil
        account = UserDefaults.standard.string(forKey: "drive.account")
    }

    /// The client ID built into this copy of colon3, if any.
    static let builtInClientID: String = {
        let value = (Bundle.main.object(forInfoDictionaryKey: "Colon3GoogleClientID") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // An unset build setting can come through as the literal "$(…)".
        return value.hasPrefix("$(") ? "" : value
    }()

    var hasBuiltInClient: Bool { !Self.builtInClientID.isEmpty }

    var clientID: String {
        hasBuiltInClient ? Self.builtInClientID : customClientID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "123-abc.apps.googleusercontent.com" → "com.googleusercontent.apps.123-abc", the URL
    /// scheme Google redirects iOS clients to.
    static func redirectScheme(for clientID: String) -> String? {
        let suffix = ".apps.googleusercontent.com"
        guard clientID.hasSuffix(suffix) else { return nil }
        let identifier = String(clientID.dropLast(suffix.count))
        return identifier.isEmpty ? nil : "com.googleusercontent.apps." + identifier
    }

    // MARK: Sign-in

    func connect() async throws {
        let client = clientID
        guard let scheme = Self.redirectScheme(for: client) else {
            throw DriveError.message(client.isEmpty
                ? "This build of colon3 has no Google client ID. Paste one in the Client ID field."
                : "That isn't an iOS client ID. It ends in .apps.googleusercontent.com.")
        }
        let redirect = scheme + ":/oauth2redirect"
        isConnecting = true
        defer { isConnecting = false }

        let verifier = Self.randomString(length: 64)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomString(length: 16)
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: client),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "prompt", value: "select_account consent"),
        ]
        guard let authorizeURL = components.url else { throw DriveError.message("Couldn't build the sign-in address.") }

        let callback = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            self.beginAuthSession(url: authorizeURL, scheme: scheme, continuation: continuation)
        }

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            throw DriveError.message(error == "access_denied" ? "Google access was declined." : "Google said: \(error)")
        }
        guard items.first(where: { $0.name == "state" })?.value == state else {
            throw DriveError.message("Google's reply didn't match this sign-in. Try again.")
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw DriveError.message("Google didn't send a sign-in code.")
        }
        let tokens = try await tokenRequest([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirect,
            "client_id": client,
            "code_verifier": verifier,
        ])
        try store(tokens)
        UserDefaults.standard.set(client, forKey: "drive.connectedClientID")
        isConnected = true

        let about = try? await getJSON("about", ["fields": "user(displayName,emailAddress)"])
        let user = about?["user"] as? [String: Any]
        let name = (user?["emailAddress"] as? String) ?? (user?["displayName"] as? String)
        account = name
        UserDefaults.standard.set(name, forKey: "drive.account")
    }

    func disconnect() {
        if let refresh = Keychain.load(account: "refreshToken", service: Self.keychainService) {
            // Tell Google too, so colon3 disappears from the account's connected apps.
            var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = HTTP.formBody(["token": refresh])
            let revoke = request
            Task.detached { _ = try? await URLSession.shared.data(for: revoke) }
        }
        Keychain.delete(account: "refreshToken", service: Self.keychainService)
        UserDefaults.standard.removeObject(forKey: "drive.account")
        accessToken = nil
        accessTokenExpiry = .distantPast
        account = nil
        isConnected = false
    }

    private func beginAuthSession(url: URL, scheme: String, continuation: CheckedContinuation<URL, Error>) {
        loginContinuation = continuation
        let session = ASWebAuthenticationSession(url: url, callback: .customScheme(scheme)) { [weak self] callbackURL, error in
            Task { @MainActor in
                self?.finishAuthSession(callbackURL: callbackURL, error: error)
            }
        }
        let anchor = DriveAuthAnchor(window: Self.keyWindow() ?? UIWindow())
        session.presentationContextProvider = anchor
        session.prefersEphemeralWebBrowserSession = false
        authSession = session
        authAnchor = anchor
        if !session.start() {
            finishAuthSession(callbackURL: nil, error: DriveError.message("Couldn't open the Google sign-in."))
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
            continuation.resume(throwing: DriveError.message("Sign-in cancelled."))
        } else {
            continuation.resume(throwing: error ?? DriveError.message("Sign-in didn't finish."))
        }
    }

    private static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }

    // MARK: Tokens

    private func tokenRequest(_ parameters: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = HTTP.formBody(parameters)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let reason = json["error_description"] as? String ?? json["error"] as? String ?? "HTTP \(status)"
            if status == 400 || status == 401 { throw DriveError.rejected(reason) }
            throw DriveError.message("Google sign-in failed: \(reason)")
        }
        return json
    }

    private func store(_ tokens: [String: Any]) throws {
        guard let access = tokens["access_token"] as? String else {
            throw DriveError.message("Google didn't send an access token.")
        }
        accessToken = access
        let lifetime = (tokens["expires_in"] as? Double) ?? 3600
        accessTokenExpiry = Date().addingTimeInterval(lifetime - 60)
        if let refresh = tokens["refresh_token"] as? String {
            Keychain.save(refresh, account: "refreshToken", service: Self.keychainService)
        }
    }

    private func validAccessToken() async throws -> String {
        if let accessToken, Date() < accessTokenExpiry { return accessToken }
        guard let refresh = Keychain.load(account: "refreshToken", service: Self.keychainService) else {
            isConnected = false
            throw DriveError.message("Connect Google Drive first.")
        }
        // The client the refresh token was issued to, even if the settings changed since.
        let client = UserDefaults.standard.string(forKey: "drive.connectedClientID") ?? clientID
        do {
            let tokens = try await tokenRequest(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": client])
            try store(tokens)
        } catch DriveError.rejected(_) {
            disconnect()
            throw DriveError.message("Your Google sign-in expired or was removed. Connect Google Drive again.")
        }
        guard let accessToken else { throw DriveError.message("Google didn't send an access token.") }
        return accessToken
    }

    // MARK: Requests

    /// Sends `request` with the access token, refreshing it once on 401 and retrying rate
    /// limits and server errors with backoff.
    private func send(_ make: () throws -> URLRequest) async throws -> (Data, HTTPURLResponse) {
        var refreshed = false
        var attempt = 0
        while true {
            var request = try make()
            let token = try await validAccessToken()
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw DriveError.message("No reply from Google Drive.") }
            if http.statusCode == 401, !refreshed {
                refreshed = true
                accessToken = nil
                continue
            }
            if [429, 500, 502, 503, 504].contains(http.statusCode) || Self.isRateLimit(data, status: http.statusCode), attempt < 4 {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(pow(2, Double(attempt))) * 1_000_000_000)
                continue
            }
            guard (200..<300).contains(http.statusCode) else { throw Self.error(from: data, status: http.statusCode) }
            return (data, http)
        }
    }

    private static func isRateLimit(_ data: Data, status: Int) -> Bool {
        guard status == 403 else { return false }
        let reason = Self.reason(data)
        return reason == "rateLimitExceeded" || reason == "userRateLimitExceeded"
    }

    private static func reason(_ data: Data) -> String? {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = json?["error"] as? [String: Any]
        return (error?["errors"] as? [[String: Any]])?.first?["reason"] as? String
    }

    private static func error(from data: Data, status: Int) -> DriveError {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = (json?["error"] as? [String: Any])?["message"] as? String
        switch reason(data) {
        case "storageQuotaExceeded":
            return .http(status, "Your Google Drive is full.")
        case "accessNotConfigured", "SERVICE_DISABLED":
            return .http(status, "The Google Drive API isn't turned on in this app's Google Cloud project.")
        default:
            let detail = message.map { ": " + $0 } ?? ""
            return .http(status, "Google Drive error \(status)\(detail)")
        }
    }

    private func getJSON(_ path: String, _ parameters: [String: String]) async throws -> [String: Any] {
        let (data, _) = try await send {
            var components = URLComponents(string: Self.api + path)!
            components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
            return URLRequest(url: components.url!, timeoutInterval: 30)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.message("Unexpected reply from Google Drive.")
        }
        return json
    }

    // MARK: Files

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Drive query strings quote with single quotes; escape them and backslashes in names.
    private static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    /// Files and folders colon3 made in `parent` ("root" for the top of My Drive).
    func children(of parent: String, named name: String? = nil) async throws -> [DriveItem] {
        var query = "\(Self.quoted(parent)) in parents and trashed = false"
        if let name { query += " and name = \(Self.quoted(name))" }
        var result: [DriveItem] = []
        var pageToken: String?
        repeat {
            var parameters = ["q": query, "pageSize": "1000", "spaces": "drive",
                              "fields": "nextPageToken,files(id,name,mimeType,size,modifiedTime)"]
            if let pageToken { parameters["pageToken"] = pageToken }
            let page = try await getJSON("files", parameters)
            for file in page["files"] as? [[String: Any]] ?? [] {
                guard let id = file["id"] as? String, let fileName = file["name"] as? String else { continue }
                result.append(DriveItem(id: id, name: fileName,
                                        isFolder: file["mimeType"] as? String == Self.folderMIME,
                                        size: (file["size"] as? String).flatMap { Int64($0) },
                                        modified: (file["modifiedTime"] as? String).flatMap { Self.dateFormatter.date(from: $0) }))
            }
            pageToken = page["nextPageToken"] as? String
        } while pageToken != nil
        return result
    }

    /// The folder called `name` in `parent`, made if it isn't there.
    func folder(named name: String, in parent: String) async throws -> String {
        if let existing = try await children(of: parent, named: name).first(where: \.isFolder) { return existing.id }
        let (data, _) = try await send {
            var request = URLRequest(url: URL(string: Self.api + "files?fields=id")!, timeoutInterval: 30)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "mimeType": Self.folderMIME, "parents": [parent]])
            return request
        }
        guard let id = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String else {
            throw DriveError.message("Google Drive didn't make the folder.")
        }
        return id
    }

    /// Writes small `data` as `name` in `parent`, replacing the file if one is there.
    func save(_ data: Data, named name: String, mimeType: String, in parent: String) async throws -> String {
        if let existing = try await children(of: parent, named: name).first(where: { !$0.isFolder }) {
            _ = try await send {
                var request = URLRequest(url: URL(string: Self.uploadAPI + "files/\(existing.id)?uploadType=media")!, timeoutInterval: 60)
                request.httpMethod = "PATCH"
                request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
                request.httpBody = data
                return request
            }
            return existing.id
        }
        let boundary = "colon3-" + UUID().uuidString
        let metadata = try JSONSerialization.data(withJSONObject: ["name": name, "parents": [parent]])
        var body = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
        body.append(metadata)
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let (reply, _) = try await send {
            var request = URLRequest(url: URL(string: Self.uploadAPI + "files?uploadType=multipart&fields=id")!, timeoutInterval: 60)
            request.httpMethod = "POST"
            request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            return request
        }
        guard let id = (try JSONSerialization.jsonObject(with: reply) as? [String: Any])?["id"] as? String else {
            throw DriveError.message("Google Drive didn't save the file.")
        }
        return id
    }

    /// Uploads a file from disk with a resumable session (any size). Returns the new file's ID.
    /// `cellular: false` waits for Wi-Fi (the request fails on cellular and Low Data Mode
    /// networks instead of using them).
    func upload(_ file: URL, named name: String, in parent: String, size: Int64, cellular: Bool) async throws -> String {
        let (_, session) = try await send {
            var request = URLRequest(url: URL(string: Self.uploadAPI + "files?uploadType=resumable&fields=id")!, timeoutInterval: 30)
            request.httpMethod = "POST"
            request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.setValue(String(size), forHTTPHeaderField: "X-Upload-Content-Length")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "parents": [parent]])
            return request
        }
        guard let location = session.value(forHTTPHeaderField: "Location"), let uploadURL = URL(string: location) else {
            throw DriveError.message("Google Drive didn't start the upload.")
        }
        var request = URLRequest(url: uploadURL, timeoutInterval: 600)
        request.allowsExpensiveNetworkAccess = cellular
        request.allowsConstrainedNetworkAccess = cellular
        request.httpMethod = "PUT"
        let token = try await validAccessToken()
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue(String(size), forHTTPHeaderField: "Content-Length")
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: file)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Self.error(from: data, status: status) }
        guard let id = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String else {
            throw DriveError.message("Google Drive didn't confirm the upload.")
        }
        return id
    }

    func delete(_ id: String) async throws {
        _ = try await send {
            var request = URLRequest(url: URL(string: Self.api + "files/\(id)")!, timeoutInterval: 30)
            request.httpMethod = "DELETE"
            return request
        }
    }

    /// A small file's contents.
    func contents(of id: String) async throws -> Data {
        let (data, _) = try await send {
            URLRequest(url: URL(string: Self.api + "files/\(id)?alt=media")!, timeoutInterval: 60)
        }
        return data
    }

    /// Downloads a file to a temporary location and returns it.
    func download(_ id: String, cellular: Bool) async throws -> URL {
        var request = URLRequest(url: URL(string: Self.api + "files/\(id)?alt=media")!, timeoutInterval: 600)
        request.allowsExpensiveNetworkAccess = cellular
        request.allowsConstrainedNetworkAccess = cellular
        let token = try await validAccessToken()
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (file, response) = try await URLSession.shared.download(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Self.error(from: (try? Data(contentsOf: file)) ?? Data(), status: status)
        }
        return file
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

/// Tells the sign-in sheet which window to appear over.
private final class DriveAuthAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let window: UIWindow

    init(window: UIWindow) {
        self.window = window
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        window
    }
}
