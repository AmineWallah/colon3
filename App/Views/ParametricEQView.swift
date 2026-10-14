import SwiftUI
import UIKit

/// Parametric EQ editor: up to 16 bands with free frequency, gain and Q, plus AutoEQ headphone
/// profiles and Equalizer APO text import/export.
struct ParametricEQEditor: View {
    @ObservedObject var equalizer: Equalizer

    @State private var showSearch = false
    @State private var naming = false
    @State private var newName = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Profile")
                Spacer()
                profileMenu
            }

            PEQCurveView(bands: equalizer.peqBands, preamp: equalizer.peqPreamp, enabled: equalizer.isEnabled)
                .frame(height: 150)

            preampRow

            ForEach($equalizer.peqBands) { $band in
                let number = (equalizer.peqBands.firstIndex { $0.id == band.id } ?? 0) + 1
                PEQBandCard(band: $band, number: number) {
                    equalizer.peqBands.removeAll { $0.id == band.id }
                }
            }
            .disabled(!equalizer.isEnabled)
            .opacity(equalizer.isEnabled ? 1 : 0.45)

            if equalizer.peqBands.isEmpty {
                VStack(spacing: 10) {
                    Text("No bands yet").font(.headline)
                    Text("Load your headphones' AutoEQ profile, paste one, or add bands by hand.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button {
                        showSearch = true
                    } label: {
                        Label("Find My Headphones", systemImage: "headphones")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            HStack {
                Button {
                    equalizer.addPEQBand()
                } label: {
                    Label("Add Band", systemImage: "plus")
                }
                .disabled(equalizer.peqBands.count >= Equalizer.maxBands || !equalizer.isEnabled)
                Spacer()
                Button("Save as Profile…") {
                    newName = equalizer.peqName == "Custom" ? "" : equalizer.peqName
                    naming = true
                }
                .disabled(equalizer.peqBands.isEmpty)
            }
            .buttonStyle(.bordered)
        }
        .sheet(isPresented: $showSearch) {
            AutoEqSearchSheet(equalizer: equalizer)
        }
        .alert("Save Profile", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Save") { equalizer.savePEQ(as: newName) }
            Button("Cancel", role: .cancel) {}
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    private var preampRow: some View {
        let peak = PEQMath.curve(equalizer.peqBands, preamp: equalizer.peqPreamp).map { $0.gain }.max() ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Preamp")
                Spacer()
                Text(String(format: "%+.1f dB", equalizer.peqPreamp))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button("Auto") { equalizer.peqPreamp = PEQMath.safePreamp(equalizer.peqBands) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Slider(value: $equalizer.peqPreamp, in: -24...6, step: 0.1)
            if equalizer.isEnabled, peak > 0.1 {
                Label(String(format: "Peaks at %+.1f dB and may clip. Tap Auto.", peak), systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .disabled(!equalizer.isEnabled)
    }

    private var profileMenu: some View {
        Menu {
            Button {
                showSearch = true
            } label: {
                Label("Find Headphones (AutoEQ)…", systemImage: "headphones")
            }
            Button {
                paste()
            } label: {
                Label("Paste Equalizer APO Text", systemImage: "doc.on.clipboard")
            }
            Button {
                UIPasteboard.general.string = PEQText.export(equalizer.peqBands, preamp: equalizer.peqPreamp)
                message = "Copied in Equalizer APO format."
            } label: {
                Label("Copy as Text", systemImage: "doc.on.doc")
            }
            .disabled(equalizer.peqBands.isEmpty)
            if !equalizer.peqProfiles.isEmpty {
                Divider()
                ForEach(equalizer.peqProfiles) { profile in
                    Menu(profile.name) {
                        Button("Use") { equalizer.applyPEQ(profile) }
                        Button("Delete", role: .destructive) { equalizer.deletePEQ(profile) }
                    }
                }
            }
            Divider()
            Button(role: .destructive) {
                equalizer.resetPEQ()
            } label: {
                Label("Clear All Bands", systemImage: "trash")
            }
        } label: {
            HStack(spacing: 4) {
                Text(equalizer.peqName).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.caption)
            }
        }
    }

    private func paste() {
        guard let text = UIPasteboard.general.string,
              let profile = PEQText.parse(text, name: "Pasted Profile") else {
            message = "The clipboard has no filters like “Filter 1: ON PK Fc 1000 Hz Gain -3 dB Q 1.4”."
            return
        }
        equalizer.applyPEQ(profile)
    }
}

/// One band: type, frequency, gain and Q.
struct PEQBandCard: View {
    @Binding var band: PEQBand
    let number: Int
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Toggle("Band \(number)", isOn: $band.isOn)
                    .labelsHidden()
                Text("\(number)")
                    .font(.headline.monospacedDigit())
                Picker("Type", selection: $band.filter) {
                    ForEach(PEQFilter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }

            row("Freq", value: frequencyText) {
                Slider(value: logBinding(\.frequency, range: 20...20_000), in: log10(20)...log10(20_000))
            }
            row("Gain", value: band.filter.usesGain ? String(format: "%+.1f dB", band.gain) : "–") {
                Slider(value: $band.gain, in: -15...15, step: 0.1)
            }
            .disabled(!band.filter.usesGain)
            row("Q", value: String(format: "%.2f", band.q)) {
                Slider(value: logBinding(\.q, range: 0.1...10), in: log10(0.1)...log10(10))
            }
            .disabled(band.filter == .lowShelf || band.filter == .highShelf)
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .opacity(band.isOn ? 1 : 0.55)
    }

    private var frequencyText: String {
        band.frequency >= 1000 ? String(format: "%.2f kHz", band.frequency / 1000) : String(format: "%.0f Hz", band.frequency)
    }

    private func row<Content: View>(_ title: String, value: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.subheadline)
                .frame(width: 40, alignment: .leading)
            content()
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .trailing)
        }
    }

    /// Sliders move in log space, so 20 Hz–200 Hz gets as much room as 2–20 kHz.
    private func logBinding(_ keyPath: WritableKeyPath<PEQBand, Float>, range: ClosedRange<Float>) -> Binding<Float> {
        Binding(
            get: { log10(min(max(band[keyPath: keyPath], range.lowerBound), range.upperBound)) },
            set: { newValue in
                var value = pow(10, newValue)
                value = value >= 100 ? value.rounded() : value.roundedTo(value >= 1 ? 0.01 : 0.001)
                band[keyPath: keyPath] = value
            }
        )
    }
}

/// The real frequency response of the bands (log frequency axis, ±15 dB).
struct PEQCurveView: View {
    let bands: [PEQBand]
    let preamp: Float
    let enabled: Bool

    private let range: Double = 15

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let points = PEQMath.curve(bands, preamp: preamp, points: 120)
            let x = { (frequency: Double) -> CGFloat in
                CGFloat(log10(frequency / 20) / 3) * size.width
            }
            let y = { (gain: Double) -> CGFloat in
                let clamped = min(max(gain, -range), range)
                return size.height / 2 - CGFloat(clamped / range) * (size.height / 2 - 2)
            }
            ZStack(alignment: .topLeading) {
                // Grid: 0 dB, ±6/12 dB, 100 Hz / 1 kHz / 10 kHz.
                Path { path in
                    for gain in [-12.0, -6, 6, 12] {
                        path.move(to: CGPoint(x: 0, y: y(gain)))
                        path.addLine(to: CGPoint(x: size.width, y: y(gain)))
                    }
                    for frequency in [100.0, 1000, 10_000] {
                        path.move(to: CGPoint(x: x(frequency), y: 0))
                        path.addLine(to: CGPoint(x: x(frequency), y: size.height))
                    }
                }
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                Path { path in
                    path.move(to: CGPoint(x: 0, y: y(0)))
                    path.addLine(to: CGPoint(x: size.width, y: y(0)))
                }
                .stroke(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                ForEach(Array(["100", "1k", "10k"].enumerated()), id: \.offset) { index, label in
                    Text(label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .position(x: x([100.0, 1000, 10_000][index]) + 10, y: size.height - 7)
                }

                Path { path in
                    for (index, point) in points.enumerated() {
                        let location = CGPoint(x: x(point.frequency), y: y(point.gain))
                        if index == 0 { path.move(to: location) } else { path.addLine(to: location) }
                    }
                }
                .stroke(enabled ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

                ForEach(bands.filter(\.isOn)) { band in
                    let total = bands.reduce(Double(preamp)) { $0 + PEQMath.response(of: $1, at: Double(band.frequency)) }
                    Circle()
                        .fill(enabled ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary))
                        .frame(width: 7, height: 7)
                        .position(x: x(Double(min(max(band.frequency, 20), 20_000))), y: y(total))
                }
            }
        }
        .background(Color(.secondarySystemBackground).opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// Search the AutoEq database by headphone name and load its parametric profile.
struct AutoEqSearchSheet: View {
    @ObservedObject var equalizer: Equalizer
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [AutoEqIndex.Entry] = []
    @State private var loading = true
    @State private var error: String?
    @State private var query = ""
    @State private var fetching: String?

    private var results: [AutoEqIndex.Entry] {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return Array(entries.prefix(80)) }
        return Array(entries.lazy.filter { entry in
            let name = entry.name.lowercased()
            return words.allSatisfy { name.contains($0) }
        }.prefix(200))
    }

    var body: some View {
        NavigationStack {
            List {
                if loading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading the AutoEq database…").foregroundStyle(.secondary)
                    }
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                ForEach(results) { entry in
                    Button {
                        load(entry)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name).foregroundStyle(.primary)
                                if !entry.source.isEmpty {
                                    Text("by " + entry.source).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if fetching == entry.id { ProgressView() }
                        }
                    }
                    .disabled(fetching != nil)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Headphone or IEM model")
            .navigationTitle("AutoEQ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                Text("Profiles from the AutoEq project, measured by oratory1990, crinacle and others. Bluetooth headphones' own processing can change the result.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
            .task {
                do {
                    entries = try await AutoEqIndex.shared.entries()
                } catch {
                    self.error = "Couldn't load the AutoEq list. Check your connection."
                }
                loading = false
            }
        }
    }

    private func load(_ entry: AutoEqIndex.Entry) {
        fetching = entry.id
        Task {
            do {
                let profile = try await AutoEqIndex.shared.profile(for: entry)
                equalizer.applyPEQ(profile)
                dismiss()
            } catch {
                self.error = "No parametric profile for \(entry.name)."
            }
            fetching = nil
        }
    }
}
