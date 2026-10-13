import Charts
import SwiftUI

struct StatsView: View {
    @EnvironmentObject private var stats: StatsStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var soulseek: SoulseekModel
    @State private var range = 14
    @State private var confirmReset = false

    var body: some View {
        // Read revision so the view refreshes when stats are saved.
        let _ = stats.revision
        let days = stats.lastDays(range)
        let totals = stats.totals
        List {
            Section {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    tile("Listened", Formatting.hours(stats.totalSeconds), "headphones")
                    tile("Plays", "\(stats.totalPlays)", "play.circle")
                    tile("Downloaded", Formatting.bytes(totals.downloadedBytes), "arrow.down.circle")
                    tile("Uploaded", Formatting.bytes(totals.uploadedBytes), "arrow.up.circle")
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section {
                Picker("Range", selection: $range) {
                    Text("7 Days").tag(7)
                    Text("14 Days").tag(14)
                    Text("30 Days").tag(30)
                }
                .pickerStyle(.segmented)
                Chart(days) { day in
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value("Minutes", day.minutes))
                        .foregroundStyle(.tint)
                        .cornerRadius(3)
                }
                .chartYAxisLabel("min")
                .frame(height: 170)
                LabeledContent("This period", value: Formatting.hours(days.reduce(0) { $0 + $1.minutes * 60 }))
                LabeledContent("Daily average", value: Formatting.hours(days.reduce(0) { $0 + $1.minutes * 60 } / Double(max(range, 1))))
            } header: {
                Text("Listening")
            }

            ranked("Top Songs", stats.topSongs(limit: 10), detail: true)
            ranked("Top Artists", stats.topArtists(limit: 10), detail: false)
            ranked("Top Albums", stats.topAlbums(limit: 10), detail: true)

            Section {
                LabeledContent("Songs downloaded", value: "\(totals.downloadedFiles)")
                LabeledContent("Songs uploaded", value: "\(totals.uploadedFiles)")
                LabeledContent("People you've shared with", value: "\(totals.peers.count)")
                LabeledContent("Share ratio", value: ratio(totals))
                LabeledContent("Shared right now", value: "\(library.tracks.count) songs")
                LabeledContent("Uploaded this session", value: Formatting.bytes(stats.sessionUploadedBytes))
                LabeledContent("Counting since", value: totals.since.formatted(date: .abbreviated, time: .omitted))
            } header: {
                Text("Soulseek")
            }

            Section {
                Button("Reset Stats", role: .destructive) { confirmReset = true }
            } footer: {
                Text("Stats stay on this iPhone. A play counts after 30 seconds (or half of a shorter song).")
            }
        }
        .navigationTitle("Stats")
        .confirmationDialog("Reset all stats?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { stats.reset() }
        }
    }

    private func ratio(_ totals: StatsStore.Totals) -> String {
        guard totals.downloadedBytes > 0 else { return totals.uploadedBytes > 0 ? "∞" : "–" }
        return String(format: "%.2f", Double(totals.uploadedBytes) / Double(totals.downloadedBytes))
    }

    private func tile(_ title: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(.tint)
            Text(value).font(.title2.weight(.bold)).lineLimit(1).minimumScaleFactor(0.6)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func ranked(_ title: String, _ items: [StatsStore.Ranked], detail: Bool) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name).lineLimit(1)
                            if detail, !item.detail.isEmpty {
                                Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("\(item.plays) plays").font(.caption.monospacedDigit())
                            Text(Formatting.hours(item.seconds)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

/// Compact numbers for the Settings row.
struct StatsPreview: View {
    @EnvironmentObject private var stats: StatsStore

    var body: some View {
        let _ = stats.revision
        HStack(spacing: 14) {
            Image(systemName: "chart.bar.xaxis")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("Stats")
                Text("\(Formatting.hours(stats.seconds(inLast: 7))) this week · ↑ \(Formatting.bytes(stats.totals.uploadedBytes)) shared")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
