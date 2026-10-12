import SoulseekKit
import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                if !model.isLoggedIn {
                    Section { ConnectionBanner() }
                }
                ForEach(model.downloads) { item in
                    DownloadRow(item: item)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                model.cancel(item)
                            } label: {
                                Label(item.isActive ? "Cancel" : "Remove", systemImage: "xmark")
                            }
                            if case .failed = item.state {
                                Button {
                                    model.retry(item)
                                } label: {
                                    Label("Retry", systemImage: "arrow.clockwise")
                                }
                                .tint(.blue)
                            }
                        }
                }
            }
            .navigationTitle("Downloads")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Clear Finished") { model.clearFinished() }
                        .disabled(model.downloads.allSatisfy(\.isActive))
                }
            }
            .overlay {
                if model.downloads.isEmpty {
                    ContentUnavailableHint(title: "No downloads",
                                           message: "Tap the download button on a search result.",
                                           systemImage: "arrow.down.circle")
                }
            }
        }
    }
}

struct DownloadRow: View {
    let item: DownloadItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.filename)
                .lineLimit(2)
            if item.state == .transferring {
                ProgressView(value: item.progress)
            }
            HStack {
                Text(status)
                Spacer()
                Text(item.id.username)
            }
            .font(.caption)
            .foregroundStyle(statusColor)
        }
        .padding(.vertical, 2)
    }

    private var status: String {
        switch item.state {
        case .requesting:
            return "Contacting peer…"
        case let .queued(place):
            return place.map { "Queued (#\($0))" } ?? "Queued"
        case .starting:
            return "Starting…"
        case .transferring:
            return "\(Formatting.bytes(item.received)) of \(Formatting.bytes(item.size))"
        case .completed:
            return "Done · \(Formatting.bytes(item.size))"
        case let .failed(reason):
            return reason
        }
    }

    private var statusColor: Color {
        switch item.state {
        case .completed: return .green
        case .failed: return .red
        default: return .secondary
        }
    }
}
