import SwiftUI

/// Apple Music-style lyrics: the current line bright, the rest dimmed and softly blurred,
/// auto-scrolling with playback. Tap a line to jump there.
struct LyricsView: View {
    let track: Track
    let albumTitle: String?
    let position: Double
    let onSeek: (Double) -> Void

    @State private var lyrics: Lyrics?
    @State private var isLoading = true
    @State private var userScrolledAt: Date?

    var body: some View {
        Group {
            if isLoading {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch lyrics {
                case let .synced(lines):
                    synced(lines)
                case let .plain(lines):
                    plain(lines)
                case .instrumental:
                    message("Instrumental", systemImage: "music.note")
                case .notFound:
                    message("No lyrics found on LRCLIB", systemImage: "quote.bubble")
                case nil:
                    VStack(spacing: 12) {
                        message("Couldn't load lyrics", systemImage: "wifi.exclamationmark")
                        Button("Try Again") { Task { await load() } }
                            .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: track.id) { await load() }
    }

    private func load() async {
        isLoading = true
        lyrics = await LyricsService.shared.lyrics(title: track.title, artist: track.artist, album: albumTitle,
                                                   duration: track.duration, cacheKey: track.id)
        isLoading = false
    }

    private func activeLine(in lines: [LyricLine]) -> Int {
        // Lead slightly so the highlight lands as the line starts.
        let now = position + 0.25
        var active = -1
        for line in lines {
            if line.time <= now { active = line.id } else { break }
        }
        return active
    }

    private func synced(_ lines: [LyricLine]) -> some View {
        let active = activeLine(in: lines)
        return ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 26) {
                    ForEach(lines) { line in
                        let distance = active < 0 ? 1 : abs(line.id - active)
                        Text(line.text)
                            .font(.system(size: 32, weight: .bold))
                            .foregroundStyle(.white.opacity(line.id == active ? 1 : 0.32))
                            .blur(radius: line.id == active ? 0 : min(Double(distance) * 0.6, 2.4))
                            .scaleEffect(line.id == active ? 1 : 0.97, anchor: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .id(line.id)
                            .onTapGesture { onSeek(line.time) }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 140)
                .animation(.easeOut(duration: 0.35), value: active)
            }
            .simultaneousGesture(DragGesture().onChanged { _ in userScrolledAt = Date() })
            .onChange(of: active) { _, newValue in
                // Don't yank the view while the user is reading ahead.
                if let userScrolledAt, Date().timeIntervalSince(userScrolledAt) < 4 { return }
                withAnimation(.spring(response: 0.6, dampingFraction: 0.9)) {
                    proxy.scrollTo(max(newValue, 0), anchor: UnitPoint(x: 0, y: 0.3))
                }
            }
            .onAppear { proxy.scrollTo(max(active, 0), anchor: UnitPoint(x: 0, y: 0.3)) }
        }
        .mask(fade)
    }

    private func plain(_ lines: [String]) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 40)
        }
        .mask(fade)
    }

    private func message(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.largeTitle)
            Text(text).font(.headline)
        }
        .foregroundStyle(.white.opacity(0.6))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fade: some View {
        LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: 0.1),
            .init(color: .black, location: 0.85),
            .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }
}
