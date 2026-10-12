import SwiftUI

/// Square cover art that loads asynchronously. Pass `size` for a fixed square, or leave it nil
/// to fill the available width.
struct ArtworkView: View {
    let source: ArtworkSource?
    var size: CGFloat?
    var cornerRadius: CGFloat = 8

    @EnvironmentObject private var library: LibraryStore
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var loadedKey: String?

    private var taskID: String { "\(source?.key ?? "none")#\(library.artworkRevision)" }

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .frame(width: size, height: size)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else {
                    ArtworkPlaceholder()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
            .task(id: taskID) {
                guard let source else {
                    image = nil
                    return
                }
                if loadedKey != source.key { image = nil }
                let pixels = Int((size ?? 220) * displayScale)
                let loaded = await ArtworkStore.shared.image(for: source, maxPixel: pixels)
                guard !Task.isCancelled else { return }
                if loaded != nil || loadedKey != source.key {
                    withAnimation(.easeOut(duration: 0.2)) { image = loaded }
                }
                loadedKey = source.key
            }
    }
}

struct ArtworkPlaceholder: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.55), Color(white: 0.4)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .opacity(0.35)
            Image(systemName: "music.note")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.secondary)
                .minimumScaleFactor(0.3)
                .padding(8)
        }
    }
}

/// Contacts-style A–Z scrubber. Drag or tap to jump between sections.
struct SectionIndexBar: View {
    let available: [String]
    let onSelect: (String) -> Void

    @State private var current: String?
    private let rowHeight: CGFloat = 14

    var body: some View {
        VStack(spacing: 0) {
            ForEach(SortKey.alphabet, id: \.self) { letter in
                Text(letter)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(available.contains(letter) ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary.opacity(0.4)))
                    .frame(width: 18, height: rowHeight)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in select(at: value.location.y) }
                .onEnded { _ in current = nil }
        )
        .sensoryFeedback(.selection, trigger: current)
        .accessibilityHidden(true)
    }

    private func select(at y: CGFloat) {
        let letters = SortKey.alphabet
        let index = min(max(Int((y - 6) / rowHeight), 0), letters.count - 1)
        // Jump to the nearest letter that actually has entries.
        let target = letters[index...].first(where: { available.contains($0) })
            ?? letters[..<index].last(where: { available.contains($0) })
        guard let target, target != current else { return }
        current = target
        onSelect(target)
    }
}

/// One song in a list: optional cover, title, subtitle, duration.
struct TrackRow: View {
    let track: Track
    var number: Int?
    var showArtwork = true
    var subtitle: String?
    var isSelected: Bool?

    @EnvironmentObject private var player: Player
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        HStack(spacing: 12) {
            if let isSelected {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary))
            }
            if showArtwork {
                ArtworkView(source: library.artwork(for: track), size: 48, cornerRadius: 6)
            } else if let number {
                Text("\(number)")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 24, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if player.current?.id == track.id {
                        Image(systemName: player.isPlaying ? "waveform" : "speaker.fill")
                            .font(.caption)
                            .foregroundStyle(.tint)
                            .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                    }
                    Text(track.title)
                        .lineLimit(1)
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if favorites.isFavorite(track) {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
            if track.isSpatial {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(Formatting.duration(track.duration))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

/// Play next / queue / favourite / delete, shared by every list of songs.
struct TrackMenuItems: View {
    let tracks: [Track]
    var album: Album?
    let onDelete: ([Track]) -> Void

    @EnvironmentObject private var player: Player
    @EnvironmentObject private var favorites: FavoritesStore

    var body: some View {
        Button {
            player.playNext(tracks)
        } label: {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        Button {
            player.addToQueue(tracks)
        } label: {
            Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
        }
        if let album {
            Button {
                favorites.toggle(album)
            } label: {
                favorites.isFavorite(album)
                    ? Label("Unfavorite Album", systemImage: "star.slash")
                    : Label("Favorite Album", systemImage: "star")
            }
        } else if tracks.count == 1, let track = tracks.first {
            Button {
                favorites.toggle(track)
            } label: {
                favorites.isFavorite(track)
                    ? Label("Unfavorite", systemImage: "star.slash")
                    : Label("Favorite", systemImage: "star")
            }
        }
        if tracks.count == 1, let track = tracks.first {
            ShareLink(item: track.url) {
                Label("Share File", systemImage: "square.and.arrow.up")
            }
        }
        Divider()
        Button(role: .destructive) {
            onDelete(tracks)
        } label: {
            Label(tracks.count == 1 ? "Delete from Library" : "Delete \(tracks.count) Songs", systemImage: "trash")
        }
    }
}

/// Asks before deleting files from the phone, then cleans up the queue and favourites.
struct DeleteConfirmation: ViewModifier {
    @Binding var pending: [Track]?
    var onDeleted: (([Track]) -> Void)?

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var favorites: FavoritesStore

    func body(content: Content) -> some View {
        content.confirmationDialog(
            title,
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let tracks = pending else { return }
                player.remove(tracks)
                favorites.forget(tracks)
                library.delete(tracks)
                pending = nil
                onDeleted?(tracks)
            }
        } message: {
            Text("The files are removed from this iPhone.")
        }
    }

    private var title: String {
        let count = pending?.count ?? 0
        return count == 1 ? "Delete this song?" : "Delete \(count) songs?"
    }
}

extension View {
    func confirmDelete(_ pending: Binding<[Track]?>, onDeleted: (([Track]) -> Void)? = nil) -> some View {
        modifier(DeleteConfirmation(pending: pending, onDeleted: onDeleted))
    }
}

/// Small rounded label used for "Lossless", "Spatial" and similar.
struct BadgeLabel: View {
    let text: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1))
        .foregroundStyle(.secondary)
    }
}

struct EmptyStateView: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
    }
}
