import Foundation
import UIKit

/// Settings › Software Update. CI publishes version.json next to the install page on every
/// signed build; a higher build number there than in this app means an update is available.
@MainActor
final class UpdateChecker: ObservableObject {
    struct Remote: Decodable, Equatable {
        let version: String
        let build: String
        let built: String?
        let commit: String?
        let notes: String?
        let size: Int?
        let install: String?
        let page: String?

        var builtDate: Date? { built.flatMap { ISO8601DateFormatter().date(from: $0) } }

        /// The commit message without trailer lines.
        var cleanNotes: String {
            (notes ?? "")
                .components(separatedBy: .newlines)
                .filter { line in !["Co-Authored-By:", "Claude-Session:", "Signed-off-by:"].contains { line.hasPrefix($0) } }
                // CHANGELOG headings ("### Transfers") read better as plain lines.
                .map { $0.hasPrefix("#") ? String($0.drop(while: { $0 == "#" || $0 == " " })) : $0 }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Remote)
        case failed(String)
    }

    enum Channel: String, CaseIterable, Identifiable {
        case stable, beta
        var id: String { rawValue }
        var label: String { self == .stable ? "Stable" : "Beta" }
        /// Stable lives at the root of the install site, beta under /beta/.
        var path: String { self == .stable ? "" : "beta/" }
    }

    static let siteRoot = "https://aminewallah.github.io/colon3/"

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?
    @Published var automatic: Bool {
        didSet { UserDefaults.standard.set(automatic, forKey: "update.automatic") }
    }
    /// Which install page to follow. Defaults to the channel this build came from.
    @Published var channel: Channel {
        didSet {
            UserDefaults.standard.set(channel.rawValue, forKey: "update.channel")
            state = .idle
            Task { await check() }
        }
    }

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    let currentBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    /// The channel CI built this copy for.
    let builtChannel = Channel(rawValue: Bundle.main.object(forInfoDictionaryKey: "Colon3Channel") as? String ?? "") ?? .stable

    /// The install page's address; version.json sits next to it.
    var source: String { Self.siteRoot + channel.path }

    var isUpdateAvailable: Bool {
        if case .available = state { return true }
        return false
    }

    init() {
        automatic = UserDefaults.standard.object(forKey: "update.automatic") as? Bool ?? true
        let built = Channel(rawValue: Bundle.main.object(forInfoDictionaryKey: "Colon3Channel") as? String ?? "") ?? .stable
        channel = UserDefaults.standard.string(forKey: "update.channel").flatMap(Channel.init(rawValue:)) ?? built
        lastChecked = UserDefaults.standard.object(forKey: "update.lastChecked") as? Date
    }

    /// On launch / foreground: at most every few hours, and only when automatic checks are on.
    func checkIfDue() {
        guard automatic else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < 4 * 3600, state != .idle { return }
        Task { await check() }
    }

    func check() async {
        guard state != .checking else { return }
        guard let url = URL(string: source + "version.json") else { return }
        state = .checking
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.setValue(HTTP.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                state = .failed(status == 404
                                ? "No \(channel.label.lowercased()) build published yet. It appears after the next signed CI build of that branch."
                                : "Server answered \(status).")
                return
            }
            let remote = try JSONDecoder().decode(Remote.self, from: data)
            lastChecked = Date()
            UserDefaults.standard.set(lastChecked, forKey: "update.lastChecked")
            state = Self.isNewer(remote, thanVersion: currentVersion, build: currentBuild) ? .available(remote) : .upToDate
        } catch is DecodingError {
            state = .failed("Couldn't read the version info.")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Opens the OTA install prompt; falls back to the install page in Safari.
    func install(_ remote: Remote) {
        let page = URL(string: remote.page ?? source)
        if let link = remote.install.flatMap(URL.init(string:)) {
            UIApplication.shared.open(link) { opened in
                if !opened, let page { UIApplication.shared.open(page) }
            }
        } else if let page {
            UIApplication.shared.open(page)
        }
    }

    func openPage() {
        if let url = URL(string: source) { UIApplication.shared.open(url) }
    }

    /// CI build numbers are shared by main and beta and only go up, so they decide. A different
    /// version string with an equal or higher build (switching channels) also counts.
    nonisolated static func isNewer(_ remote: Remote, thanVersion version: String, build: String) -> Bool {
        if let remoteBuild = Int(remote.build), let localBuild = Int(build), remoteBuild != localBuild {
            return remoteBuild > localBuild
        }
        return remote.version.compare(version, options: .numeric) == .orderedDescending
    }
}
