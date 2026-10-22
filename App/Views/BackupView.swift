import SwiftUI

/// Settings › Backup: Google Drive backups, restoring, missing songs, and backup files.
struct BackupView: View {
    @EnvironmentObject private var drive: GoogleDrive
    @EnvironmentObject private var backup: BackupService
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var soulseek: SoulseekModel
    @State private var connectError: String?
    @State private var fileError: String?
    @State private var exportFile: ExportFile?
    @State private var confirmDisconnect = false

    var body: some View {
        Form {
            driveSection
            if drive.isConnected {
                backUpSection
                restoreSection
            }
            if !backup.pending.isEmpty || backup.search != nil {
                missingSection
            }
            fileSection
            if let error = backup.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Backup")
        .task(id: drive.isConnected) {
            if drive.isConnected, !backup.remoteChecked { await backup.checkRemote() }
        }
        .sheet(item: $exportFile) { file in
            ActivityView(items: [file.url])
        }
        .confirmationDialog("Disconnect Google Drive?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) {
                backup.cancel()
                drive.disconnect()
                backup.forgetUploads()
            }
        } message: {
            Text("Your backup stays in Google Drive. Connect again to use it.")
        }
    }

    // MARK: Google Drive

    private var driveSection: some View {
        Section {
            if drive.isConnected {
                Label(drive.account ?? "Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Disconnect", role: .destructive) { confirmDisconnect = true }
                    .disabled(backup.isWorking)
            } else {
                if !drive.hasBuiltInClient {
                    TextField("iOS Client ID", text: $drive.customClientID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                }
                Button {
                    connect()
                } label: {
                    if drive.isConnecting { ProgressView() } else { Text("Connect Google Drive") }
                }
                .disabled(drive.isConnecting || drive.clientID.isEmpty)
                if let connectError {
                    Text(connectError).font(.footnote).foregroundStyle(.red)
                }
            }
        } header: {
            Text("Google Drive")
        } footer: {
            if drive.isConnected {
                Text("colon3 can only see what it saves itself: the \u{201C}\(BackupService.folderName)\u{201D} folder. The rest of your Drive stays private. The sign-in is kept in the Keychain.")
            } else if drive.hasBuiltInClient {
                Text("Sign in with your Google account. colon3 only gets access to the files it creates, not the rest of your Drive.")
            } else {
                Text("This copy of colon3 has no Google client ID built in. Paste the iOS client ID from your Google Cloud project (the README explains how to make one).")
            }
        }
    }

    private func connect() {
        connectError = nil
        Task {
            do {
                try await drive.connect()
                await backup.checkRemote()
            } catch {
                connectError = error.localizedDescription
            }
        }
    }

    // MARK: Back up

    private var backUpSection: some View {
        Section {
            if let activity = backup.activity {
                VStack(alignment: .leading, spacing: 6) {
                    Text(activity.title)
                    if !activity.detail.isEmpty {
                        Text(activity.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let fraction = activity.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Button("Stop", role: .destructive) { backup.cancel() }
            } else {
                Button("Back Up Now") { backup.backUpNow() }
                    .disabled(!backup.isLibraryReady || backup.search?.isRunning == true)
            }
            LabeledContent("Last Backup", value: backup.lastBackup.map { $0.formatted(.relative(presentation: .named)) } ?? "Never")
            Toggle("Back Up Automatically", isOn: $backup.automatic)
            Toggle("Include Music", isOn: $backup.includeMusic)
            if backup.includeMusic {
                Toggle("Use Cellular Data", isOn: $backup.useCellular)
                LabeledContent("Songs on Google Drive", value: "\(backup.uploadedSongs)")
            }
        } header: {
            Text("Back Up")
        } footer: {
            Text("Saves your song list, playlists, favourites, listening stats and settings. Passwords and keys are never included. Automatic backups happen once a day when you open colon3.\n\nInclude Music uploads the song files too, with their covers and lyrics (only new ones each time), so a restore can download them instead of searching Soulseek again. They count towards your Google storage.")
        }
    }

    // MARK: Restore

    private var restoreSection: some View {
        Section {
            if backup.isCheckingRemote {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Looking for a backup…").foregroundStyle(.secondary)
                }
            } else if let remote = backup.remote {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Backup from \(remote.device)")
                    Text(summaryLine(remote))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("Restore\u{2026}") {
                    router.backupRestore = BackupRestoreRequest(backup: remote, source: "Google Drive")
                }
                .disabled(!backup.isLibraryReady || backup.isWorking)
            } else if backup.remoteChecked {
                Text("No backup on this Google account yet.").foregroundStyle(.secondary)
            }
            if !backup.isCheckingRemote {
                Button("Check Again") { Task { await backup.checkRemote() } }
                    .disabled(backup.isWorking)
            }
        } header: {
            Text("Restore")
        } footer: {
            Text("Restoring brings back playlists, favourites, stats and settings. Songs that aren't on this phone show up below, ready to download.")
        }
    }

    private func summaryLine(_ remote: BackupFile) -> String {
        var parts = [remote.created.formatted(date: .abbreviated, time: .shortened),
                     "\(remote.songs.count) songs",
                     "\(remote.playlists.count) playlists"]
        let onDrive = (remote.music ?? []).filter(\.isAudio).count
        if onDrive > 0 { parts.append("\(onDrive) on Drive") }
        return parts.joined(separator: " · ")
    }

    // MARK: Missing songs

    private var missingSection: some View {
        Section {
            let pending = backup.pending
            if !pending.songs.isEmpty {
                let songs = plural(pending.songs.count, "song")
                let verb = pending.songs.count == 1 ? "isn't" : "aren't"
                Text(songs + " from your backup " + verb + " on this phone yet. Playlists keep their place and fill in as songs arrive.")
            }
            if !pending.albums.isEmpty {
                let albums = plural(pending.albums.count, "favourite album")
                let pronoun = pending.albums.count == 1 ? "it's" : "they're"
                Text(albums + " will be favourited again once " + pronoun + " here.")
                    .foregroundStyle(.secondary)
            }

            if pending.driveSongCount > 0, drive.isConnected {
                let title = "Download " + plural(pending.driveSongCount, "Song") + " from Google Drive"
                Button(title) {
                    backup.restoreMusicFromDrive()
                }
                .disabled(backup.isWorking)
            }

            if let search = backup.search {
                VStack(alignment: .leading, spacing: 6) {
                    let status: String = search.isRunning ? "Searching Soulseek\u{2026}" : "Found \(search.found) of \(search.total) on Soulseek"
                    Text(status)
                    if search.isRunning {
                        Text("\(search.done) of \(search.total) · \(search.found) found")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let current = search.current {
                            Text(current)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    ProgressView(value: Double(search.done), total: Double(max(search.total, 1)))
                }
                if search.isRunning {
                    Button("Stop", role: .destructive) { backup.cancelSearch() }
                } else {
                    Button("Done") { backup.dismissSearch() }
                }
            } else if !pending.songs.isEmpty {
                let listed = backup.listedMissingSongs.count
                if listed > 0, listed < pending.songs.count {
                    Button("Find \(listed) from Playlists & Favourites on Soulseek") {
                        backup.findMissingOnSoulseek(onlyListed: true)
                    }
                    .disabled(!soulseek.isLoggedIn || backup.activity != nil)
                }
                let findAll: String = pending.songs.count == 1 ? "Find It on Soulseek" : "Find All \(pending.songs.count) on Soulseek"
                Button(findAll) {
                    backup.findMissingOnSoulseek(onlyListed: false)
                }
                .disabled(!soulseek.isLoggedIn || backup.activity != nil)
            }

            if backup.search?.isRunning != true {
                Button("Forget Missing Songs", role: .destructive) { backup.forgetMissing() }
                    .disabled(backup.activity != nil)
            }
        } header: {
            Text("Missing Songs")
        } footer: {
            Text(soulseek.isLoggedIn
                 ? "Soulseek searches share the queue with playlist imports (one every few seconds), so a long list takes a while. With Keep Transfers Running in Background on, it carries on while colon3 is in the background."
                 : "Log in to Soulseek to search for missing songs.")
        }
    }

    // MARK: File

    private var fileSection: some View {
        Section {
            Button("Export Backup File") { export() }
                .disabled(!backup.isLibraryReady)
            Button("Import Backup File") { router.importBackupFile() }
                .disabled(!backup.isLibraryReady || backup.isWorking)
            if let fileError {
                Text(fileError).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("Backup File")
        } footer: {
            Text("The same backup as a file (without the music), to keep anywhere or move to another phone. No Google account needed.")
        }
    }

    private func export() {
        fileError = nil
        do {
            let data = try backup.exportData()
            let day = Date().formatted(.iso8601.year().month().day())
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("colon3 Backup \(day).json")
            try data.write(to: url, options: .atomic)
            exportFile = ExportFile(url: url)
        } catch {
            fileError = error.localizedDescription
        }
    }
}

/// Shows what a backup holds, then restores it.
struct RestoreBackupSheet: View {
    let request: BackupRestoreRequest
    @EnvironmentObject private var backup: BackupService
    @Environment(\.dismiss) private var dismiss
    @State private var includeSettings = true
    @State private var summary: BackupService.RestoreSummary?

    private var file: BackupFile { request.backup }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Made On", value: file.device)
                    LabeledContent("Date", value: file.created.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Songs", value: "\(file.songs.count)")
                    LabeledContent("Playlists", value: "\(file.playlists.count)")
                    LabeledContent("Favourites", value: "\(file.favoriteSongs.count + file.favoriteAlbums.count)")
                    let onDrive = (file.music ?? []).filter(\.isAudio).count
                    if onDrive > 0 {
                        LabeledContent("Songs on Google Drive", value: "\(onDrive)")
                    }
                } header: {
                    Text(request.source)
                }

                if let summary {
                    Section {
                        Label("Restored", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(resultText(summary))
                    } footer: {
                        if summary.settings {
                            Text("Some settings (like the equalizer and autoplay) take effect the next time you open colon3.")
                        }
                    }
                } else {
                    Section {
                        Toggle("Restore Settings", isOn: $includeSettings)
                            .disabled(file.settings == nil)
                    } footer: {
                        Text("Playlists come back with their songs; one that's already here is replaced by the backup's version. Favourites and listening stats are added to what's here. Passwords aren't in backups, so log in to Soulseek, Last.fm and Spotify again.")
                    }
                    Section {
                        Button("Restore") {
                            summary = backup.restore(file, settings: includeSettings)
                        }
                        .disabled(!backup.isLibraryReady)
                    }
                }
            }
            .navigationTitle("Restore Backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(summary == nil ? "Cancel" : "Done") { dismiss() }
                }
            }
        }
    }

    private func resultText(_ summary: BackupService.RestoreSummary) -> String {
        let missing = summary.songs - summary.onPhone
        var text = plural(summary.playlists, "playlist") + " and " + plural(summary.favorites, "favourite")
            + " restored. \(summary.onPhone) of \(summary.songs) songs are on this phone."
        if missing > 0 {
            text += " The other \(missing) are listed under Settings › Backup › Missing Songs, where you can download them."
        }
        return text
    }
}

/// "1 song", "3 songs".
private func plural(_ count: Int, _ word: String) -> String {
    "\(count) \(word)\(count == 1 ? "" : "s")"
}
