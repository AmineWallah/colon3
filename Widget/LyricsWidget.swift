import ActivityKit
import SwiftUI
import WidgetKit

/// The current lyric line on the Lock Screen (and in the Dynamic Island when it's expanded).
struct LyricsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LyricsActivityAttributes.self) { context in
            LockScreenLyrics(state: context.state, accent: Self.accent(context.attributes.accentHex))
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .widgetURL(URL(string: "colon3://player"))
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            let tint = Self.accent(context.attributes.accentHex)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "quote.bubble.fill")
                        .foregroundStyle(tint)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.line.isEmpty ? "\u{266A}" : state.line)
                            .font(.headline)
                            .lineLimit(2)
                        if let romanized = state.romanized, !romanized.isEmpty {
                            Text(romanized).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: "quote.bubble.fill").foregroundStyle(tint)
            } compactTrailing: {
                Image(systemName: state.isPlaying ? "waveform" : "pause.fill").foregroundStyle(tint)
            } minimal: {
                Image(systemName: "quote.bubble.fill").foregroundStyle(tint)
            }
            .widgetURL(URL(string: "colon3://player"))
            .keylineTint(tint)
        }
    }

    static func accent(_ hex: String) -> Color {
        var text = hex
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return .pink }
        return Color(red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }
}

struct LockScreenLyrics: View {
    let state: LyricsActivityAttributes.ContentState
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "quote.bubble.fill")
                    .foregroundStyle(accent)
                Text(state.title + " \u{00B7} " + state.artist)
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .font(.caption.weight(.semibold))

            Text(state.line.isEmpty ? "\u{266A}" : state.line)
                .font(.title3.weight(.bold))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .contentTransition(.opacity)
            if let romanized = state.romanized, !romanized.isEmpty {
                Text(romanized)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
            if !state.next.isEmpty {
                Text(state.next)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.white)
    }
}
