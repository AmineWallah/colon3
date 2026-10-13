import ActivityKit
import Foundation

/// Live Activity for Soulseek transfers, shown in the Dynamic Island and on the Lock Screen while
/// downloads or uploads run and no song is playing. Compiled into both the app and the widget.
struct TransferActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var downloading: Int
        var uploading: Int
        var queued: Int
        /// Overall progress of the active transfers, 0...1.
        var fraction: Double
        var bytesPerSecond: Double
        /// The file currently moving, if any.
        var currentFile: String
        var finished: Bool
        /// Songs shared while Seeding Mode keeps the app up; 0 when not seeding.
        var seeding: Int = 0
        /// Bytes uploaded since the app started.
        var sessionUploaded: Double = 0

        /// Nothing moving, just staying online to share.
        var isIdleSeeding: Bool { seeding > 0 && downloading == 0 && uploading == 0 && queued == 0 && !finished }

        var title: String {
            if finished { return "Transfers finished" }
            if isIdleSeeding { return "Seeding \(seeding) songs" }
            var parts: [String] = []
            if downloading > 0 { parts.append("\(downloading) down") }
            if uploading > 0 { parts.append("\(uploading) up") }
            if parts.isEmpty, queued > 0 { return "\(queued) waiting in queues" }
            return parts.joined(separator: " · ")
        }

        var percentText: String { "\(Int((fraction * 100).rounded()))%" }

        /// Compact island text: progress while transferring, total sent while seeding.
        var compactText: String {
            guard isIdleSeeding else { return percentText }
            return sessionUploaded > 0 ? "↑" + ByteCountFormatter.string(fromByteCount: Int64(sessionUploaded), countStyle: .file) : "On"
        }

        var speedText: String {
            guard bytesPerSecond > 0 else { return "" }
            return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
        }

        var symbol: String {
            if finished { return "checkmark.circle.fill" }
            if isIdleSeeding { return "leaf.circle.fill" }
            if downloading > 0 && uploading > 0 { return "arrow.up.arrow.down.circle.fill" }
            return uploading > 0 ? "arrow.up.circle.fill" : "arrow.down.circle.fill"
        }
    }

    /// The app's accent colour at the time the activity started.
    var accentHex: String
}
