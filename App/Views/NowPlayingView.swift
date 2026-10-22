import AVKit
import MediaPlayer
import SwiftUI

/// Full-screen player modelled on Apple Music: big artwork, or lyrics / queue with a compact
/// header, over a blurred copy of the artwork.
struct NowPlayingView: View {
    enum Mode {
        case artwork, lyrics, queue
    }

    @EnvironmentObject private var player: Player
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var router: AppRouter
    @State private var mode: Mode = .artwork
    @State private var showEqualizer = false
    @State private var showSpeed = false

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(.white.opacity(0.35))
                .frame(width: 38, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 14)

            if let track = player.current {
                switch mode {
                case .artwork:
                    largeArtwork
                    Spacer(minLength: 16)
                    titleRow(track, compact: false)
                        .padding(.bottom, 18)
                case .lyrics:
                    titleRow(track, compact: true)
                    ClockedLyrics(track: track, albumTitle: library.album(containing: track)?.title ?? track.album)
                        .padding(.horizontal, -28)
                case .queue:
                    titleRow(track, compact: true)
                    QueueView()
                        .padding(.horizontal, -28)
                }
                ScrubBar()
                    .padding(.top, mode == .artwork ? 0 : 8)
                transport
                    .padding(.vertical, 22)
                if showSpeed {
                    SpeedControl()
                        .padding(.bottom, 14)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                VolumeRow()
                bottomBar
                    .padding(.top, 22)
                    .padding(.bottom, 6)
            } else {
                Spacer()
                Text("Not Playing").font(.title2.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                Spacer()
            }
        }
        .padding(.horizontal, 28)
        .foregroundStyle(.white)
        .background { PlayerBackground(image: player.artwork) }
        .environment(\.colorScheme, .dark)
        .presentationDragIndicator(.hidden)
        .presentationBackground(.black)
        .sheet(isPresented: $showEqualizer) {
            NavigationStack { EqualizerView(equalizer: player.equalizer) }
                .presentationDetents([.medium, .large])
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: mode)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showSpeed)
    }

    private var largeArtwork: some View {
        // The square comes from Color.clear; the image sits in an overlay so an odd-shaped one
        // can never make the layout wider than the screen.
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image = player.artwork {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    ArtworkPlaceholder()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: player.isPlaying ? 24 : 10, y: 12)
            .scaleEffect(player.isPlaying ? 1 : 0.82)
            .animation(.spring(response: 0.45, dampingFraction: 0.7), value: player.isPlaying)
            .frame(maxHeight: .infinity)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
    }

    @ViewBuilder
    private func titleRow(_ track: Track, compact: Bool) -> some View {
        HStack(spacing: 14) {
            if compact {
                ZStack {
                    if let image = player.artwork {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        ArtworkPlaceholder()
                    }
                }
                .frame(width: 66, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                .onTapGesture { mode = .artwork }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(compact ? .headline : .title3.weight(.bold))
                    .lineLimit(1)
                Text(track.artist)
                    .font(compact ? .subheadline : .title3)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                favorites.toggle(track)
            } label: {
                Image(systemName: favorites.isFavorite(track) ? "star.fill" : "star")
                    .font(.title3.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .contentTransition(.symbolEffect(.replace))
            }
            .sensoryFeedback(.success, trigger: favorites.isFavorite(track))
            moreMenu(track)
        }
        .padding(.bottom, compact ? 12 : 0)
    }

    private func moreMenu(_ track: Track) -> some View {
        Menu {
            Button {
                showEqualizer = true
            } label: {
                Label("Equalizer", systemImage: "slider.vertical.3")
            }
            Button {
                router.addToPlaylist([track])
            } label: {
                Label("Add to Playlist…", systemImage: "text.badge.plus")
            }
            Divider()
            Button {
                mode = .lyrics
                Task {
                    await LyricsService.shared.forget(cacheKey: track.id)
                    router.lyricsChanged()
                }
            } label: {
                Label("Search Lyrics Again", systemImage: "quote.bubble")
            }
            Button {
                mode = .lyrics
                router.importLyrics(for: track)
            } label: {
                Label("Import Lyrics (.lrc)…", systemImage: "doc.text")
            }
            if FileManager.default.fileExists(atPath: LibraryStore.lyricsURL(for: track).path) {
                Button(role: .destructive) {
                    library.removeLyricsFile(for: track)
                    router.lyricsChanged()
                } label: {
                    Label("Remove Lyrics File", systemImage: "doc.badge.minus")
                }
            }
            ArtworkMenu(target: library.album(containing: track).map(ArtworkTarget.album) ?? .track(track))
            Divider()
            ShareLink(item: track.url) {
                Label("Share File", systemImage: "square.and.arrow.up")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.title3.weight(.semibold))
                .frame(width: 34, height: 34)
                .background(.white.opacity(0.12), in: Circle())
        }
    }

    private var transport: some View {
        HStack {
            Spacer()
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 32))
            }
            Spacer()
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 46))
                    .frame(width: 60, height: 60)
                    .contentTransition(.symbolEffect(.replace.downUp))
            }
            Spacer()
            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 32))
            }
            Spacer()
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: player.isPlaying)
    }

    private var bottomBar: some View {
        HStack {
            modeButton(.lyrics, symbol: "quote.bubble")
            Spacer()
            speedButton
            Spacer()
            AirPlayButton()
                .frame(width: 44, height: 44)
            Spacer()
            modeButton(.queue, symbol: "list.bullet")
        }
        .padding(.horizontal, 24)
    }

    private var speedButton: some View {
        let changed = abs(player.playbackRate - 1) >= 0.001
        return Button {
            showSpeed.toggle()
        } label: {
            Text(SpeedControl.label(player.playbackRate))
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(showSpeed ? Color.black.opacity(0.75) : Color.white.opacity(changed ? 1 : 0.7))
                .frame(minWidth: 44, minHeight: 44)
                .padding(.horizontal, 4)
                .background(showSpeed ? Color.white.opacity(0.8) : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Playback speed")
    }

    private func modeButton(_ target: Mode, symbol: String) -> some View {
        Button {
            mode = mode == target ? .artwork : target
        } label: {
            Image(systemName: mode == target ? symbol + (symbol == "quote.bubble" ? ".fill" : "") : symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(mode == target ? Color.black.opacity(0.75) : Color.white.opacity(0.7))
                .frame(width: 44, height: 44)
                .background(mode == target ? Color.white.opacity(0.8) : Color.clear, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

/// Lyrics fed by the playback clock, so only this view redraws as the song plays.
struct ClockedLyrics: View {
    let track: Track
    let albumTitle: String?
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var clock: PlaybackClock

    var body: some View {
        LyricsView(track: track, albumTitle: albumTitle, position: clock.position) { player.seek(to: $0) }
    }
}

/// Blurred, darkened artwork filling the screen.
struct PlayerBackground: View {
    let image: UIImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(white: 0.18)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .blur(radius: 70, opaque: true)
                        .saturation(1.4)
                        .transition(.opacity)
                }
                LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: image)
    }
}

/// Thin progress bar that grows while dragging, with elapsed / remaining times and format badges.
struct ScrubBar: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var clock: PlaybackClock
    @State private var dragValue: Double?

    var body: some View {
        let duration = max(player.duration, 1)
        let value = dragValue ?? clock.position
        VStack(spacing: 6) {
            GeometryReader { geometry in
                let width = geometry.size.width
                let height: CGFloat = dragValue == nil ? 7 : 12
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule()
                        .fill(.white.opacity(dragValue == nil ? 0.75 : 0.95))
                        .frame(width: max(height, width * CGFloat(min(value / duration, 1))))
                }
                .frame(height: height)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            let fraction = min(max(gesture.location.x / max(width, 1), 0), 1)
                            dragValue = Double(fraction) * duration
                        }
                        .onEnded { _ in
                            if let target = dragValue { player.seek(to: target) }
                            dragValue = nil
                        }
                )
                .animation(.spring(response: 0.3), value: dragValue == nil)
            }
            .frame(height: 20)

            HStack {
                Text(Formatting.duration(value))
                Spacer()
                badge
                Spacer()
                Text("-" + Formatting.duration(max(player.duration - value, 0)))
            }
            .font(.caption.weight(.medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
        }
    }

    @ViewBuilder
    private var badge: some View {
        if player.isSpatialPlayback {
            Label("Spatial", systemImage: "dot.radiowaves.left.and.right").font(.caption2.weight(.semibold))
        } else if player.bitPerfect, player.output.isBitPerfect(enabled: true) {
            Label("Bit-Perfect · \(Formatting.sampleRate(player.output.hardwareRate))", systemImage: "checkmark.seal.fill")
                .font(.caption2.weight(.semibold))
        } else if player.bitPerfect, let reason = player.output.blocker(enabled: true) {
            Label(reason, systemImage: "exclamationmark.triangle")
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        } else if let ext = player.current?.fileExtension, ["flac", "alac", "wav", "aif", "aiff"].contains(ext) {
            Label("Lossless", systemImage: "waveform").font(.caption2.weight(.semibold))
        } else if player.equalizer.isEnabled {
            Label("EQ", systemImage: "slider.vertical.3").font(.caption2.weight(.semibold))
        }
    }
}

struct VolumeRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill").font(.footnote)
            SystemVolumeSlider().frame(height: 34)
            Image(systemName: "speaker.wave.3.fill").font(.footnote)
        }
        .foregroundStyle(.white.opacity(0.6))
    }
}

/// The system volume slider (MPVolumeView), restyled to match.
struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.tintColor = .white
        style(view)
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {
        style(view)
    }

    private func style(_ view: MPVolumeView) {
        for case let slider as UISlider in view.subviews {
            slider.minimumTrackTintColor = UIColor.white.withAlphaComponent(0.75)
            slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.22)
            slider.setThumbImage(Self.thumb, for: .normal)
        }
    }

    private static let thumb: UIImage = {
        let size = CGSize(width: 14, height: 14)
        return UIGraphicsImageRenderer(size: size).image { _ in
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).fill()
        }
    }()
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = UIColor.white.withAlphaComponent(0.7)
        view.activeTintColor = .white
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

struct QueueView: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var library: LibraryStore
    /// The suggestion whose Download button was tapped, waiting for confirmation.
    @State private var confirming: AutoplayItem?

    private var showsAutoplay: Bool { player.autoplay && player.repeatMode == .off }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Up Next").font(.headline)
                Spacer()
                toggle(symbol: "shuffle", active: player.shuffle) { player.toggleShuffle() }
                toggle(symbol: player.repeatMode == .one ? "repeat.1" : "repeat", active: player.repeatMode != .off) {
                    player.cycleRepeat()
                }
                toggle(symbol: "infinity", active: player.autoplay) { player.autoplay.toggle() }
                    .accessibilityLabel("Autoplay")
            }
            .padding(.horizontal, 28)

            if player.upNext.isEmpty, !showsAutoplay || player.autoplayUpcoming.isEmpty {
                Spacer()
                Group {
                    if player.repeatMode == .all {
                        Text("The queue will repeat.")
                    } else if showsAutoplay, player.isFindingAutoplay {
                        HStack(spacing: 8) {
                            ProgressView().tint(.white)
                            Text("Finding songs for Autoplay…")
                        }
                    } else if showsAutoplay, let note = player.autoplayNote {
                        Text(note).multilineTextAlignment(.center).padding(.horizontal, 28)
                    } else {
                        Text("Nothing else queued.")
                    }
                }
                .foregroundStyle(.white.opacity(0.6))
                Spacer()
            } else {
                List {
                    ForEach(Array(player.upNext.enumerated()), id: \.offset) { offset, track in
                        Button {
                            player.jump(to: player.index + 1 + offset)
                        } label: {
                            row(track)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(.white.opacity(0.15))
                        .listRowInsets(EdgeInsets(top: 6, leading: 28, bottom: 6, trailing: 20))
                    }
                    .onMove { player.moveInQueue(from: $0, to: $1) }
                    .onDelete { player.removeFromQueue(at: $0) }

                    if showsAutoplay, !player.autoplayUpcoming.isEmpty {
                        Section {
                            ForEach(Array(player.autoplayUpcoming.enumerated()), id: \.element.id) { offset, item in
                                Group {
                                    if let track = item.track {
                                        Button {
                                            player.playAutoplay(at: offset)
                                        } label: {
                                            row(track, badge: item.isDiscovery ? "arrow.down.circle.fill" : nil).opacity(0.75)
                                        }
                                        .buttonStyle(.plain)
                                    } else {
                                        discoveryRow(item)
                                    }
                                }
                                .listRowBackground(Color.clear)
                                .listRowSeparatorTint(.white.opacity(0.15))
                                .listRowInsets(EdgeInsets(top: 6, leading: 28, bottom: 6, trailing: 20))
                            }
                            .onDelete { player.removeAutoplay(at: $0) }
                        } header: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Image(systemName: "infinity")
                                    Text("Autoplay")
                                    Spacer()
                                    if player.isFindingAutoplay { ProgressView().controlSize(.small).tint(.white) }
                                }
                                .font(.subheadline.weight(.semibold))
                                if let note = player.autoplayNote {
                                    Text(note).font(.caption)
                                }
                            }
                            .foregroundStyle(.white.opacity(0.7))
                            .textCase(nil)
                            .padding(.leading, 12)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.editMode, .constant(.active))
                .confirmationDialog(confirming.map { "Download \u{201C}\($0.song.title)\u{201D}?" } ?? "",
                                    isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                                    titleVisibility: .visible, presenting: confirming) { item in
                    Button("Download") { player.confirmAutoplayDownload(item.id) }
                    Button("Cancel", role: .cancel) {}
                } message: { item in
                    Text("\(item.song.primaryArtist): found on Soulseek and saved to your library and the \u{201C}Found by Autoplay\u{201D} playlist. If it isn't ready when its turn comes, the next song plays and this one follows once it's done.")
                }
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.92),
                                             .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            }
        }
    }

    private func row(_ track: Track, badge: String? = nil) -> some View {
        HStack(spacing: 12) {
            ArtworkView(source: library.artwork(for: track), size: 44, cornerRadius: 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).lineLimit(1)
                HStack(spacing: 4) {
                    if let badge {
                        // Downloaded by autoplay from Soulseek.
                        Image(systemName: badge).font(.caption2)
                    }
                    Text(track.artist).lineLimit(1)
                }
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
        }
    }

    /// A Last.fm pick that isn't in the library yet: shown while it's found and downloaded.
    private func discoveryRow(_ item: AutoplayItem) -> some View {
        HStack(spacing: 12) {
            ArtworkView(source: .remote(item.song.primaryArtist + " " + item.song.title), size: 44, cornerRadius: 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.song.title).lineLimit(1)
                Text(item.song.primaryArtist + " · " + discoveryStatus(item.state))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            .opacity(0.6)
            Spacer()
            switch item.state {
            case .offered:
                Button {
                    confirming = item
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Download \(item.song.title)")
            case .waiting, .searching, .downloading:
                // The percentage is in the line under the title.
                ProgressView()
                    .tint(.white)
                    .frame(width: 44, height: 44)
            case .ready:
                EmptyView()
            }
        }
    }

    private func discoveryStatus(_ state: AutoplayItem.State) -> String {
        switch state {
        case .ready: return "Ready"
        case .offered: return "Not downloaded"
        case .waiting: return "Waiting to download"
        case .searching: return "Searching Soulseek…"
        case let .downloading(fraction): return "Downloading \(Int(fraction * 100))%"
        }
    }

    private func toggle(symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(active ? Color.black.opacity(0.75) : Color.white.opacity(0.75))
                .frame(width: 38, height: 30)
                .background(active ? Color.white.opacity(0.8) : Color.white.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Draggable speed bar, 0.5× to 2×. Snaps to 0.5, 0.75, 1, 1.5 and 2 when you pass near them,
/// stops anywhere in between in 0.05 steps, and the preset labels underneath are tappable.
struct SpeedControl: View {
    @EnvironmentObject private var player: Player

    private let lower = Player.rateRange.lowerBound
    private let upper = Player.rateRange.upperBound

    static func label(_ rate: Float) -> String {
        var text = String(format: "%.2f", rate)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + "×"
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Speed").font(.caption.weight(.semibold))
                Spacer()
                Text(Self.label(player.playbackRate))
                    .font(.caption.weight(.bold).monospacedDigit())
                if abs(player.playbackRate - 1) >= 0.001 {
                    Button("Reset") { player.playbackRate = 1 }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.plain)
                        .padding(.leading, 8)
                }
            }
            .foregroundStyle(.white.opacity(0.75))

            GeometryReader { geometry in
                let width = max(geometry.size.width, 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22)).frame(height: 6)
                    Capsule().fill(.white.opacity(0.8)).frame(width: max(6, position(player.playbackRate, width)), height: 6)
                    ForEach(Player.ratePresets, id: \.self) { preset in
                        Circle()
                            .fill(.white.opacity(0.55))
                            .frame(width: 4, height: 4)
                            .offset(x: position(preset, width) - 2)
                    }
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                        .frame(width: 18, height: 18)
                        .offset(x: position(player.playbackRate, width) - 9)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            let fraction = Float(min(max(gesture.location.x / width, 0), 1))
                            var value = lower + fraction * (upper - lower)
                            value = (value / 0.05).rounded() * 0.05
                            if let preset = Player.ratePresets.first(where: { abs($0 - value) <= 0.04 }) { value = preset }
                            if abs(value - player.playbackRate) > 0.001 { player.playbackRate = value }
                        }
                )
            }
            .frame(height: 26)

            GeometryReader { geometry in
                let width = max(geometry.size.width, 1)
                ForEach(Player.ratePresets, id: \.self) { preset in
                    Text(Self.label(preset))
                        .font(.caption2.weight(abs(preset - player.playbackRate) < 0.001 ? .bold : .regular).monospacedDigit())
                        .foregroundStyle(.white.opacity(abs(preset - player.playbackRate) < 0.001 ? 1 : 0.55))
                        .fixedSize()
                        .position(x: min(max(position(preset, width), 12), width - 12), y: 8)
                        .onTapGesture { player.playbackRate = preset }
                }
            }
            .frame(height: 16)
        }
        .sensoryFeedback(.selection, trigger: player.playbackRate) { _, new in
            Player.ratePresets.contains { abs($0 - new) < 0.001 }
        }
    }

    private func position(_ rate: Float, _ width: CGFloat) -> CGFloat {
        CGFloat((rate - lower) / (upper - lower)) * width
    }
}
