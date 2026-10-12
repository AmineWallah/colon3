import Foundation
import Security

/// Password storage. Works with free-account sideloading (no extra entitlements needed).
enum Keychain {
    static let soulseekService = "colon3.soulseek"

    static func save(_ value: String, account: String, service: String = soulseekService) {
        delete(account: account, service: service)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: Data(value.utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(account: String, service: String = soulseekService) -> String? {
        guard !account.isEmpty else { return nil }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String, service: String = soulseekService) {
        guard !account.isEmpty else { return }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum Formatting {
    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file)
    }

    static func speed(_ bytesPerSecond: UInt32) -> String {
        bytes(UInt64(bytesPerSecond)) + "/s"
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func kilohertz(_ hertz: UInt32) -> String {
        let value = Double(hertz) / 1000
        return value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// User-facing switches, stored in UserDefaults so views can bind with @AppStorage.
enum AppSettings {
    static let artworkLookupKey = "artworkLookup"
    static let lyricsLookupKey = "lyricsLookup"
    static let scrobblingKey = "lastfmScrobbling"

    static var artworkLookupEnabled: Bool { flag(artworkLookupKey) }
    static var lyricsLookupEnabled: Bool { flag(lyricsLookupKey) }
    static var scrobblingEnabled: Bool { flag(scrobblingKey) }

    /// All switches default to on.
    private static func flag(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}

enum HTTP {
    static let userAgent = "colon3/0.2 (https://github.com/AmineWallah/colon3)"

    static func formBody(_ parameters: [String: String]) -> Data {
        // ASCII-only unreserved set; CharacterSet.alphanumerics would let accented letters through raw.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let body = parameters.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }
}
