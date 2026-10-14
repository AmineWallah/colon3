import SwiftUI

/// Settings › Diagnostics & Logs: the live session log and any crash reports, with share and clear.
struct DiagnosticsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case log = "Log", crashes = "Crashes"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .log
    @State private var lines: [String] = []
    @State private var crashes: [Diagnostics.CrashReport] = []
    @State private var share: ExportFile?
    @State private var confirmClear = false

    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab == .crashes && !crashes.isEmpty ? "Crashes (\(crashes.count))" : tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            switch tab {
            case .log: logList
            case .crashes: crashList
            }
        }
        .navigationTitle("Diagnostics & Logs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    shareCurrent()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                Menu {
                    Button(role: .destructive) { confirmClear = true } label: {
                        Label(tab == .log ? "Clear Log" : "Delete Crash Reports", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog(tab == .log ? "Clear the session log?" : "Delete all crash reports?",
                            isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if tab == .log { Diagnostics.shared.clearSession() } else { Diagnostics.shared.clearCrashes() }
                reload()
            }
        }
        .sheet(item: $share) { file in
            ActivityView(items: [file.url]).presentationDetents([.medium, .large])
        }
        .onReceive(refresh) { _ in if tab == .log { lines = Diagnostics.shared.lines } }
        .onAppear(perform: reload)
        .onChange(of: tab) { _, _ in reload() }
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    Text(line)
                        .font(.caption2.monospaced())
                        .foregroundStyle(color(for: line))
                        .textSelection(.enabled)
                        .listRowSeparator(.hidden)
                        .id(index)
                }
                Color.clear.frame(height: 1).id(-1)
            }
            .listStyle(.plain)
            .overlay {
                if lines.isEmpty {
                    Text("No log yet.").foregroundStyle(.secondary)
                }
            }
            .onChange(of: lines.count) { _, _ in
                withAnimation { proxy.scrollTo(-1, anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo(-1, anchor: .bottom) }
        }
    }

    private var crashList: some View {
        List {
            if crashes.isEmpty {
                Text("No crashes recorded. 🎉").foregroundStyle(.secondary)
            }
            ForEach(crashes) { report in
                NavigationLink {
                    CrashDetailView(report: report)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(report.title)
                        Text(report.kind == "MetricKit" ? "Full diagnostic from iOS" : "Captured in-app")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func color(for line: String) -> Color {
        let lower = line.lowercased()
        if lower.contains("error") || lower.contains("failed") || lower.contains("[crash]") { return .red }
        if lower.contains("warning") { return .orange }
        return .primary
    }

    private func reload() {
        lines = Diagnostics.shared.lines
        crashes = Diagnostics.shared.crashReports()
    }

    private func shareCurrent() {
        if tab == .log {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("colon3-log.txt")
            try? Diagnostics.shared.exportSessionText().data(using: .utf8)?.write(to: url)
            share = ExportFile(url: url)
        } else if let first = crashes.first {
            share = ExportFile(url: first.url)
        }
    }
}

struct CrashDetailView: View {
    let report: Diagnostics.CrashReport
    @State private var share: ExportFile?

    var body: some View {
        ScrollView {
            Text(Diagnostics.shared.readCrash(report))
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .navigationTitle(report.kind)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    share = ExportFile(url: report.url)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .sheet(item: $share) { file in
            ActivityView(items: [file.url]).presentationDetents([.medium, .large])
        }
    }
}
