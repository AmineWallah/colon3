import SoulseekKit
import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var soulseek: SoulseekModel
    @State private var collapsed = Set<String>()

    private struct UserGroup: Identifiable {
        let username: String
        let items: [DownloadItem]
        var id: String { username }

        var active: Int { items.filter(\.isActive).count }
        var failed: Int { items.filter { if case .failed = $0.state { return true } else { return false } }.count }
        var done: Int { items.filter { if case .completed = $0.state { return true } else { return false } }.count }
        var progress: Double {
            let size = items.reduce(UInt64(0)) { $0 + $1.size }
            let received = items.reduce(UInt64(0)) { total, item in
                if case .completed = item.state { return total + item.size }
                return total + item.received
            }
            return size > 0 ? min(1, Double(received) / Double(size)) : 0
        }
    }

    /// Users with active transfers first, then most recent.
    private var groups: [UserGroup] {
        var order: [String] = []
        var byUser: [String: [DownloadItem]] = [:]
        for item in soulseek.visibleDownloads {
            if byUser[item.id.username] == nil { order.append(item.id.username) }
            byUser[item.id.username, default: []].append(item)
        }
        let groups = order.map { UserGroup(username: $0, items: byUser[$0] ?? []) }
        return groups.sorted { ($0.active > 0 ? 0 : 1) < ($1.active > 0 ? 0 : 1) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !soulseek.isLoggedIn {
                    Section { ConnectionBanner() }
                }
                ForEach(groups) { group in
                    Section {
                        if !collapsed.contains(group.username) {
                            ForEach(group.items) { item in
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
                    } header: {
                        groupHeader(group)
                    }
                }

                if !soulseek.uploads.isEmpty {
                    Section {
                        if !collapsed.contains(uploadsKey) {
                            ForEach(soulseek.uploads) { item in UploadRow(item: item) }
                        }
                    } header: {
                        collapsibleHeader(key: uploadsKey) {
                            Label("Uploads", systemImage: "arrow.up.circle")
                            Spacer()
                            Text(soulseek.activeUploadCount > 0 ? "\(soulseek.activeUploadCount) active" : "\(soulseek.uploads.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Downloads")
            .animation(.default, value: collapsed)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(collapsed.isEmpty ? "Collapse All" : "Expand All") {
                        collapsed = collapsed.isEmpty ? Set(groups.map(\.username) + [uploadsKey]) : []
                    }
                    .disabled(groups.isEmpty && soulseek.uploads.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear Finished") { soulseek.clearFinished() }
                        .disabled(soulseek.downloads.allSatisfy(\.isActive) && soulseek.uploads.allSatisfy(\.isActive))
                }
            }
            .overlay {
                if soulseek.visibleDownloads.isEmpty && soulseek.uploads.isEmpty {
                    EmptyStateView(title: "No Downloads",
                                   message: "Tap the download button on a search result.",
                                   systemImage: "arrow.down.circle")
                }
            }
        }
    }

    private let uploadsKey = "\u{0}uploads"

    private func groupHeader(_ group: UserGroup) -> some View {
        collapsibleHeader(key: group.username) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label(group.username, systemImage: "person.fill")
                        .textCase(nil)
                        .lineLimit(1)
                    Spacer()
                    Text(summary(group)).foregroundStyle(.secondary)
                }
                if group.active > 0 {
                    ProgressView(value: group.progress)
                }
            }
        }
        .contextMenu {
            if group.failed > 0 {
                Button { soulseek.retryFailed(from: group.username) } label: {
                    Label("Retry Failed", systemImage: "arrow.clockwise")
                }
            }
            Button(role: .destructive) { soulseek.cancelAll(from: group.username) } label: {
                Label("Cancel and Remove All", systemImage: "xmark")
            }
        }
    }

    private func summary(_ group: UserGroup) -> String {
        var parts: [String] = []
        if group.active > 0 { parts.append("\(group.active) active") }
        if group.done > 0 { parts.append("\(group.done) done") }
        if group.failed > 0 { parts.append("\(group.failed) failed") }
        return parts.joined(separator: " · ")
    }

    private func collapsibleHeader<Content: View>(key: String, @ViewBuilder content: () -> Content) -> some View {
        Button {
            if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .rotationEffect(.degrees(collapsed.contains(key) ? 0 : 90))
                content()
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .textCase(nil)
    }
}

struct UploadRow: View {
    let item: UploadItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.filename).lineLimit(1)
            if item.state == .transferring {
                ProgressView(value: item.progress)
            }
            HStack {
                Text(status)
                Spacer()
                Text("to \(item.id.username)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var status: String {
        switch item.state {
        case .queued: return "Queued"
        case .transferring: return "\(Formatting.bytes(item.sent)) of \(Formatting.bytes(item.size))"
        case .completed: return "Sent"
        case .failed: return "Stopped"
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
