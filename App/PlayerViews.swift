import SwiftUI

extension View {
    /// Pins the mini player above the tab bar on screens that play music.
    func miniPlayer(showingPlayer: Binding<Bool>) -> some View {
        modifier(MiniPlayerInset(showingPlayer: showingPlayer))
    }
}

private struct MiniPlayerInset: ViewModifier {
    @EnvironmentObject private var player: Player
    @Binding var showingPlayer: Bool

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if player.current != nil {
                MiniPlayerBar(showingPlayer: $showingPlayer)
            }
        }
    }
}

struct MiniPlayerBar: View {
    @EnvironmentObject private var player: Player
    @Binding var showingPlayer: Bool

    var body: some View {
        if let track = player.current {
            HStack(spacing: 12) {
                ArtworkView(image: player.artwork, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 36, height: 36)
                }
                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                        .frame(width: 36, height: 36)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
            .contentShape(Rectangle())
            .onTapGesture { showingPlayer = true }
        }
    }
}

struct NowPlayingView: View {
    @EnvironmentObject private var player: Player
    @Environment(\.dismiss) private var dismiss
    @State private var scrubbing: Double?

    var body: some View {
        VStack(spacing: 24) {
            Capsule()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 40, height: 5)
                .padding(.top, 8)

            Spacer(minLength: 0)

            ArtworkView(image: player.artwork, size: 300)

            VStack(spacing: 6) {
                Text(player.current?.title ?? "Not playing")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text([player.current?.artist, player.current?.album].compactMap { $0 }.joined(separator: " — "))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .padding(.horizontal)

            VStack(spacing: 4) {
                Slider(value: Binding(
                    get: { scrubbing ?? player.position },
                    set: { scrubbing = $0 }
                ), in: 0...max(player.duration, 1)) { editing in
                    if !editing, let target = scrubbing {
                        player.seek(to: target)
                        scrubbing = nil
                    }
                }
                HStack {
                    Text(Formatting.duration(scrubbing ?? player.position))
                    Spacer()
                    Text(Formatting.duration(player.duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)

            HStack(spacing: 48) {
                Button { player.previous() } label: {
                    Image(systemName: "backward.fill").font(.title)
                }
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 64))
                }
                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.title)
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
        .padding(.bottom, 24)
        .presentationDragIndicator(.hidden)
    }
}

struct ArtworkView: View {
    let image: UIImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.35))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.08, style: .continuous))
    }
}
