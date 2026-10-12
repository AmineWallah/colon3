import SwiftUI

/// Compact now-playing controls. On iOS 26+ this sits in the tab bar's bottom accessory (the
/// Liquid Glass pill Apple Music uses); earlier systems get a floating capsule instead.
struct MiniPlayerContent: View {
    let compact: Bool
    let open: () -> Void

    @EnvironmentObject private var player: Player

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if let image = player.artwork {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    ArtworkPlaceholder()
                }
            }
            .frame(width: compact ? 28 : 36, height: compact ? 28 : 36)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 0) {
                Text(player.current?.title ?? "Not Playing")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if !compact, let artist = player.current?.artist {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 36, height: 36)
                    .contentTransition(.symbolEffect(.replace))
            }
            .disabled(player.current == nil)

            if !compact {
                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                        .frame(width: 36, height: 36)
                }
                .disabled(player.current == nil)
            }
        }
        .buttonStyle(.plain)
        .padding(.leading, compact ? 8 : 10)
        .padding(.trailing, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
    }
}

#if compiler(>=6.2)
@available(iOS 26, *)
struct AccessoryMiniPlayer: View {
    let open: () -> Void
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        MiniPlayerContent(compact: placement == .inline, open: open)
    }
}
#endif

/// Pre-iOS 26 stand-in: a floating material capsule above the tab bar.
struct FloatingMiniPlayer: View {
    let open: () -> Void

    var body: some View {
        MiniPlayerContent(compact: false, open: open)
            .frame(height: 56)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
    }
}

enum MiniPlayerStyle {
    static var usesTabAccessory: Bool {
        #if compiler(>=6.2)
        if #available(iOS 26, *) { return true }
        #endif
        return false
    }
}

/// Adds the floating pill to a tab's content when the native accessory isn't available.
struct FallbackMiniPlayer: ViewModifier {
    let open: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if MiniPlayerStyle.usesTabAccessory {
            content
        } else {
            content.safeAreaInset(edge: .bottom, spacing: 0) { FloatingMiniPlayer(open: open) }
        }
    }
}

/// Native bottom accessory on iOS 26+.
struct TabAccessoryMiniPlayer: ViewModifier {
    let open: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            content
                .tabViewBottomAccessory { AccessoryMiniPlayer(open: open) }
                .tabBarMinimizeBehavior(.onScrollDown)
        } else {
            content
        }
        #else
        content
        #endif
    }
}
