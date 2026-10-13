import SoulseekKit
import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var soulseek: SoulseekModel
    @State private var query = ""
    @State private var showFilters = false

    var body: some View {
        NavigationStack {
            List {
                if !soulseek.isLoggedIn {
                    Section { ConnectionBanner() }
                }
                if !soulseek.currentQuery.isEmpty {
                    Section {
                        FilterChips(showAll: $showFilters)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                    Section {
                        HStack {
                            Text("\(soulseek.responseCount) users · \(soulseek.results.count) folders")
                            if soulseek.hiddenCount > 0 {
                                Text("· \(soulseek.hiddenCount) filtered out")
                            }
                            Spacer()
                            if soulseek.filters.activeCount > 0 {
                                Button("Clear Filters") { soulseek.filters = ResultFilters(sort: soulseek.filters.sort) }
                                    .font(.footnote.weight(.semibold))
                            }
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }
                ForEach(soulseek.results) { folder in
                    NavigationLink(value: folder.id) {
                        FolderRow(folder: folder)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Artist, album or track")
            .onSubmit(of: .search) { soulseek.search(query) }
            .navigationDestination(for: String.self) { id in
                FolderDetailView(folderID: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showFilters = true
                    } label: {
                        Image(systemName: soulseek.filters.activeCount > 0
                              ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .sheet(isPresented: $showFilters) {
                SearchFiltersView()
                    .presentationDetents([.medium, .large])
            }
            .overlay {
                if soulseek.currentQuery.isEmpty && soulseek.isLoggedIn {
                    EmptyStateView(title: "Search Soulseek",
                                   message: "Results arrive over about 30 seconds as people answer.",
                                   systemImage: "magnifyingglass")
                }
            }
        }
    }
}

struct FolderRow: View {
    let folder: FolderResult

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ArtworkView(source: .remote(folder.coverQuery), size: 60, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 3) {
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
                        .lineLimit(1)
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
        }
        .padding(.vertical, 2)
    }
}

struct FolderDetailView: View {
    let folderID: String
    @EnvironmentObject private var soulseek: SoulseekModel

    var body: some View {
        if let folder = soulseek.folder(withID: folderID) {
            List {
                Section {
                    HStack(spacing: 16) {
                        ArtworkView(source: .remote(folder.coverQuery), size: 110, cornerRadius: 10)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(folder.name).font(.headline)
                            Text(folder.formatSummary).font(.subheadline).foregroundStyle(.secondary)
                            Text("\(folder.files.count) files · \(Formatting.bytes(folder.totalSize))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(Color.clear)
                }

                Section {
                    Button {
                        soulseek.downloadFolder(folder)
                    } label: {
                        Label("Download All", systemImage: "arrow.down.circle.fill")
                    }
                    .disabled(!soulseek.isLoggedIn)
                } footer: {
                    Text("From \(folder.username) · \(folder.folder). The album cover is fetched too when the folder has one; otherwise it's looked up online.")
                }

                Section {
                    ForEach(folder.files, id: \.path) { file in
                        FileRow(file: file, username: folder.username, folderImages: folder.images)
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
    let file: SharedFile
    let username: String
    let folderImages: [SharedFile]
    @EnvironmentObject private var soulseek: SoulseekModel

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
        switch soulseek.state(of: file, from: username) {
        case .none, .some(.failed):
            Button {
                soulseek.download(file, from: username, knownImages: folderImages)
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .disabled(!soulseek.isLoggedIn)
        case .some(.completed):
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        default:
            ProgressView()
        }
    }
}

struct SearchFiltersView: View {
    @EnvironmentObject private var soulseek: SoulseekModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Sort By", selection: $soulseek.filters.sort) {
                        ForEach(ResultFilters.Sort.allCases) { sort in
                            Label(sort.rawValue, systemImage: sort.systemImage).tag(sort)
                        }
                    }
                }

                Section("Quality") {
                    Picker("File Type", selection: $soulseek.filters.fileType) {
                        ForEach(ResultFilters.FileType.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Minimum Bitrate", selection: $soulseek.filters.minBitrate) {
                        ForEach(ResultFilters.bitrateChoices, id: \.self) { kbps in
                            Text(kbps == 0 ? "Any" : "\(kbps) kbps").tag(kbps)
                        }
                    }
                    Toggle("Playable Formats Only", isOn: $soulseek.audioOnly)
                }

                Section {
                    Toggle("Free Upload Slot Only", isOn: $soulseek.filters.freeSlotOnly)
                    Stepper(value: $soulseek.filters.minFiles, in: 1...30) {
                        LabeledContent("Minimum Files", value: soulseek.filters.minFiles == 1 ? "Any" : "\(soulseek.filters.minFiles)")
                    }
                } header: {
                    Text("Availability")
                } footer: {
                    Text("A minimum of around 6 files skips loose singles and finds complete albums.")
                }

                Section {
                    TextField("live, remix, karaoke", text: $soulseek.filters.excludeWords)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Exclude Words")
                } footer: {
                    Text("Hides folders whose path contains any of these.")
                }

                if !soulseek.filters.isDefault {
                    Section {
                        Button("Reset Filters", role: .destructive) { soulseek.filters = ResultFilters() }
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// One-tap sort and filter controls above the results.
struct FilterChips: View {
    @Binding var showAll: Bool
    @EnvironmentObject private var soulseek: SoulseekModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    Picker("Sort By", selection: $soulseek.filters.sort) {
                        ForEach(ResultFilters.Sort.allCases) { sort in
                            Label(sort.rawValue, systemImage: sort.systemImage).tag(sort)
                        }
                    }
                } label: {
                    chip(soulseek.filters.sort.rawValue, systemImage: "arrow.up.arrow.down", active: true)
                }

                Menu {
                    Picker("File Type", selection: $soulseek.filters.fileType) {
                        ForEach(ResultFilters.FileType.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    chip(soulseek.filters.fileType.shortLabel, systemImage: "doc", active: soulseek.filters.fileType != .any)
                }

                Button {
                    soulseek.filters.freeSlotOnly.toggle()
                } label: {
                    chip("Free Slot", systemImage: "checkmark.circle", active: soulseek.filters.freeSlotOnly)
                }

                Button {
                    soulseek.filters.minFiles = soulseek.filters.minFiles > 1 ? 1 : 6
                } label: {
                    chip("Albums", systemImage: "square.stack", active: soulseek.filters.minFiles > 1)
                }

                Button {
                    showAll = true
                } label: {
                    chip("More", systemImage: "slider.horizontal.3", active: false)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private func chip(_ title: String, systemImage: String, active: Bool) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(active ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary.opacity(0.15)), in: Capsule())
    }
}
