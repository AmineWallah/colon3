import ActivityKit
import Foundation

/// Live Activity with the current lyric line, on the Lock Screen while a song with synced
/// lyrics plays. Compiled into both the app and the widget.
struct LyricsActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var artist: String
        /// The line being sung ("" before the first one, or when the song has no synced lyrics).
        var line: String
        /// Romaji / pinyin for it, when that's turned on.
        var romanized: String?
        var next: String
        var isPlaying: Bool
    }

    /// The app's accent colour at the time the activity started.
    var accentHex: String
}
