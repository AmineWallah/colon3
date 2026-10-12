import SoulseekKit
import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                if !model.isLoggedIn {
                    Section { ConnectionBanner() }
                }
                if !model.currentQuery.isEmpty {
                    Section {
                        Text("\(model.responseCount) users answered · \(model.results.count) folders")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(model.results) { folder in
                    NavigationLink(value: folder.id) {
                        FolderRow(folder: folder)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Artist, album or track")
            .onSubmit(of: .search) { model.search(query) }
            .navigationDestination(for: String.self) { id in
                FolderDetailView(folderID: id)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Toggle("Playable formats only", isOn: $model.audioOnly)
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .overlay {
                if model.currentQuery.isEmpty && model.isLoggedIn {
                    ContentUnavailableHint(title: "Search Soulseek",
                                           message: "Results come in over ~30 seconds as peers answer.",
                                           systemImage: "magnifyingglass")
                }
            }
        }
    }
}

struct FolderRow: View {
    let folder: FolderResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(folder.name)
                .font(.headline)
                .lineLimit(2)
            if !folder.parentPath.isEmpty {
                Text(folder.parentPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 8) {
                Text(folder.formatSummary)
                Text("\(folder.files.count) files")
                Text(Formatting.bytes(folder.totalSize))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Label(folder.username, systemImage: "person")
                if folder.slotFree {
                    Label("Free slot", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Queue \(folder.queueLength)", systemImage: "hourglass")
                        .foregroundStyle(.orange)
                }
                Text(Formatting.speed(folder.speed))
            }
            .font(.caption2)
            .labelStyle(.titleAndIcon)
        }
        .padding(.vertical, 2)
    }
}

struct FolderDetailView: View {
    @EnvironmentObject private var model: AppModel
    let folderID: String

    var body: some View {
        if let folder = model.folder(withID: folderID) {
            List {
                Section {
                    Button {
                        model.downloadFolder(folder)
                    } label: {
                        Label("Download all \(folder.files.count) files (\(Formatting.bytes(folder.totalSize)))",
                              systemImage: "arrow.down.circle.fill")
                    }
                    .disabled(!model.isLoggedIn)
                } footer: {
                    Text("From \(folder.username) · \(folder.folder)")
                }

                Section {
                    ForEach(folder.files, id: \.path) { file in
                        FileRow(file: file, username: folder.username)
                    }
                }
            }
            .navigationTitle(folder.name)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            Text("This result is no longer available.")
                .foregroundStyle(.secondary)
        }
    }
}

struct FileRow: View {
    @EnvironmentObject private var model: AppModel
    let file: SharedFile
    let username: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.filename)
                    .lineLimit(2)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statusButton
        }
    }

    private var details: String {
        var parts = [Formatting.bytes(file.size)]
        if let duration = file.attributes.duration { parts.append(Formatting.duration(Double(duration))) }
        if let bitrate = file.attributes.bitrate { parts.append("\(bitrate) kbps") }
        if let depth = file.attributes.bitDepth, let rate = file.attributes.sampleRate {
            parts.append("\(depth)-bit/\(Formatting.kilohertz(rate)) kHz")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var statusButton: some View {
        switch model.state(of: file, from: username) {
        case .none, .some(.failed):
            Button {
                model.download(file, from: username)
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .disabled(!model.isLoggedIn)
        case .some(.completed):
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        default:
            ProgressView()
        }
    }
}

/// Small stand-in for ContentUnavailableView, which needs iOS 17.
struct ContentUnavailableHint: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}
