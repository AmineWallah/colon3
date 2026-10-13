import ActivityKit
import SwiftUI
import WidgetKit

@main
struct TransfersWidgetBundle: WidgetBundle {
    var body: some Widget {
        TransfersLiveActivity()
    }
}

struct TransfersLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TransferActivityAttributes.self) { context in
            LockScreenTransfers(state: context.state, accent: accent(context.attributes))
                .padding(16)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            let tint = accent(context.attributes)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: state.symbol)
                        .font(.title2)
                        .foregroundStyle(tint)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(state.percentText).font(.title3.weight(.semibold).monospacedDigit())
                        if !state.speedText.isEmpty {
                            Text(state.speedText).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.title).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        if !state.currentFile.isEmpty {
                            Text(state.currentFile).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        ProgressView(value: state.fraction).tint(tint)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: state.symbol).foregroundStyle(tint)
            } compactTrailing: {
                Text(state.percentText)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(tint)
            } minimal: {
                ProgressView(value: state.fraction)
                    .progressViewStyle(.circular)
                    .tint(tint)
            }
            .keylineTint(tint)
        }
    }

    private func accent(_ attributes: TransferActivityAttributes) -> Color {
        var text = attributes.accentHex
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return .pink }
        return Color(red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }
}

struct LockScreenTransfers: View {
    let state: TransferActivityAttributes.ContentState
    let accent: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: state.symbol)
                .font(.largeTitle)
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("colon3 · " + state.title).font(.headline).lineLimit(1)
                    Spacer()
                    Text(state.percentText).font(.headline.monospacedDigit())
                }
                if !state.currentFile.isEmpty {
                    Text(state.currentFile).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                ProgressView(value: state.fraction).tint(accent)
                if !state.speedText.isEmpty {
                    Text(state.speedText).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .foregroundStyle(.white)
    }
}
