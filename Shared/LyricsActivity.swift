import ActivityKit
import Foundation

/// The Lock Screen lyrics Live Activity from 1.4.0 beta 3, since removed. Kept only so the app
/// can end one that's still showing after updating (see Colon3App).
struct LyricsActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var artist: String
        var line: String
        var romanized: String?
        var next: String
        var isPlaying: Bool
    }

    var accentHex: String
}
