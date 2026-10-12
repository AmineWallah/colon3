import SwiftUI

struct EqualizerView: View {
    @ObservedObject var equalizer: Equalizer
    @EnvironmentObject private var player: Player
    @Environment(\.dismiss) private var dismiss
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Toggle("Equalizer", isOn: $equalizer.isEnabled)
                    .font(.headline)

                HStack {
                    Text("Preset")
                    Spacer()
                    presetMenu
                }

                ResponseCurve(gains: equalizer.gains, enabled: equalizer.isEnabled)
                    .frame(height: 90)

                HStack(alignment: .top, spacing: 0) {
                    ForEach(Equalizer.frequencies.indices, id: \.self) { index in
                        VStack(spacing: 6) {
                            Text(String(format: "%+.0f", equalizer.gains[index]))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            VerticalGainSlider(value: $equalizer.gains[index], range: Equalizer.gainRange)
                                .frame(height: 200)
                            Text(Equalizer.label(for: Equalizer.frequencies[index]))
                                .font(.caption2.weight(.medium))
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .disabled(!equalizer.isEnabled)
                .opacity(equalizer.isEnabled ? 1 : 0.4)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Preamp")
                        Spacer()
                        Text(String(format: "%+.1f dB", equalizer.preamp))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $equalizer.preamp, in: -12...6, step: 0.5)
                }
                .disabled(!equalizer.isEnabled)

                HStack {
                    Button("Save as Preset…") {
                        newName = ""
                        naming = true
                    }
                    Spacer()
                    Button("Reset", role: .destructive) { equalizer.reset() }
                }
                .buttonStyle(.bordered)

                if player.isSpatialPlayback {
                    Label("The current track is spatial audio, which plays without the EQ.", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Boosting bands can clip; lower the preamp if loud passages crackle.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .navigationTitle("Equalizer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .alert("Save Preset", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Save") { equalizer.saveCurrent(as: newName) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var presetMenu: some View {
        Menu {
            ForEach(Equalizer.builtIn) { preset in
                Button(preset.name) { equalizer.apply(preset) }
            }
            if !equalizer.customPresets.isEmpty {
                Divider()
                ForEach(equalizer.customPresets) { preset in
                    Menu(preset.name) {
                        Button("Use") { equalizer.apply(preset) }
                        Button("Delete", role: .destructive) { equalizer.deletePreset(preset) }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(equalizer.presetName)
                Image(systemName: "chevron.up.chevron.down").font(.caption)
            }
        }
    }
}

/// Drag up/down to set a band's gain; snaps to 0.5 dB, with a detent feel at 0.
struct VerticalGainSlider: View {
    @Binding var value: Float
    let range: ClosedRange<Float>

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let span = range.upperBound - range.lowerBound
            let fraction = CGFloat((value - range.lowerBound) / span)
            let knobY = height * (1 - fraction)
            let zeroY = height * (1 - CGFloat((0 - range.lowerBound) / span))

            ZStack(alignment: .top) {
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: 4)
                Rectangle()
                    .fill(.tint)
                    .frame(width: 4, height: abs(knobY - zeroY))
                    .offset(y: min(knobY, zeroY))
                Rectangle()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 12, height: 1)
                    .offset(y: zeroY)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .frame(width: 22, height: 22)
                    .offset(y: knobY - 11)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let clampedY = min(max(gesture.location.y, 0), height)
                        let raw = range.upperBound - Float(clampedY / max(height, 1)) * span
                        var snapped = (raw * 2).rounded() / 2
                        if abs(snapped) < 0.75 { snapped = 0 }
                        if snapped != value { value = snapped }
                    }
            )
            .sensoryFeedback(.selection, trigger: value == 0)
        }
    }
}

/// Smooth curve through the band gains, as a quick visual of the EQ shape.
struct ResponseCurve: View {
    let gains: [Float]
    let enabled: Bool

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let points = gains.enumerated().map { index, gain in
                CGPoint(x: size.width * (CGFloat(index) + 0.5) / CGFloat(gains.count),
                        y: size.height / 2 - CGFloat(gain / 12) * (size.height / 2 - 4))
            }
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: size.height / 2))
                    path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                }
                .stroke(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: CGPoint(x: 0, y: first.y))
                    path.addLine(to: first)
                    for index in 1..<points.count {
                        let previous = points[index - 1], point = points[index]
                        let middle = CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2)
                        path.addQuadCurve(to: middle, control: previous)
                        if index == points.count - 1 { path.addQuadCurve(to: point, control: point) }
                    }
                    if let last = points.last { path.addLine(to: CGPoint(x: size.width, y: last.y)) }
                }
                .stroke(enabled ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
        }
        .animation(.easeOut(duration: 0.15), value: gains)
    }
}
