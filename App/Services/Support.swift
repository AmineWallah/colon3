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

    /// "1 hr 12 min" / "42 minutes".
    static func longDuration(_ seconds: Double) -> String {
        let total = Int(seconds / 60)
        return total >= 60 ? "\(total / 60) hr \(total % 60) min" : "\(total) minute\(total == 1 ? "" : "s")"
    }

    /// "3.2 h" / "45 min" for listening totals.
    static func hours(_ seconds: Double) -> String {
        if seconds >= 3600 { return String(format: "%.1f h", seconds / 3600) }
        return "\(Int(seconds / 60)) min"
    }

    static func sampleRate(_ hertz: Double) -> String {
        guard hertz > 0 else { return "–" }
        return kilohertz(UInt32(hertz.rounded())) + " kHz"
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
    static let backgroundTransfersKey = "backgroundTransfers"
    static let transferActivityKey = "transferLiveActivity"
    static let showMissingKey = "showMissingSongs"
    static let musicBrainzKey = "musicBrainzLookup"
    /// These three default to off.
    static let bitPerfectKey = "bitPerfect"
    static let seedingKey = "seedingMode"
    static let discordKey = "discordPresence"

    static var artworkLookupEnabled: Bool { flag(artworkLookupKey) }
    static var lyricsLookupEnabled: Bool { flag(lyricsLookupKey) }
    static var scrobblingEnabled: Bool { flag(scrobblingKey) }
    static var seedingEnabled: Bool { UserDefaults.standard.bool(forKey: seedingKey) }

    /// Most switches default to on.
    static func flag(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}

enum HTTP {
    static let userAgent = "colon3/0.4 (https://github.com/AmineWallah/colon3)"

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
