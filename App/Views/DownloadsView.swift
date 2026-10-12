import SoulseekKit
import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var soulseek: SoulseekModel

    var body: some View {
        NavigationStack {
            List {
                if !soulseek.isLoggedIn {
                    Section { ConnectionBanner() }
                }
                ForEach(soulseek.visibleDownloads) { item in
                    DownloadRow(item: item)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                soulseek.cancel(item)
                            } label: {
                                Label(item.isActive ? "Cancel" : "Remove", systemImage: "xmark")
                            }
                            if case .failed = item.state {
                                Button {
                                    soulseek.retry(item)
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear Finished") { soulseek.clearFinished() }
                        .disabled(soulseek.downloads.allSatisfy(\.isActive))
                }
            }
            .overlay {
                if soulseek.visibleDownloads.isEmpty {
                    EmptyStateView(title: "No Downloads",
                                   message: "Tap the download button on a search result.",
                                   systemImage: "arrow.down.circle")
                }
            }
        }
    }
}

struct DownloadRow: View {
    let item: DownloadItem
    @EnvironmentObject private var library: LibraryStore

    /// Finished files show their real cover; others a best guess from the folder name.
    private var artwork: ArtworkSource {
        if case let .completed(url) = item.state, let track = libraryTrack(at: url) {
            return library.artwork(for: track)
        }
        return .remote(CoverLookup.query(forFolderPath: item.folderPath))
    }

    private func libraryTrack(at url: URL) -> Track? {
        let root = library.root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root) else { return nil }
        var relative = String(path.dropFirst(root.count))
        if relative.hasPrefix("/") { relative.removeFirst() }
        return library.track(id: relative)
    }

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(source: artwork, size: 46, cornerRadius: 6)
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
