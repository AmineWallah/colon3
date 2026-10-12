import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: Library
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                    Button(model.isLoggedIn ? "Reconnect" : "Log In") {
                        model.logIn(username: username, password: password)
                        password = ""
                    }
                    .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
                    if model.isLoggedIn {
                        Button("Disconnect", role: .destructive) { model.logOut() }
                    }
                } header: {
                    Text("Soulseek account")
                } footer: {
                    Text("Logging in with an unused username registers it. There's no password reset, so pick something you'll remember.")
                }

                Section("Status") {
                    if model.isLoggedIn {
                        Label("Logged in as \(model.username)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        ConnectionBanner()
                    }
                }

                Section {
                    LabeledContent("Shared files", value: "\(library.tracks.count)")
                } header: {
                    Text("Sharing")
                } footer: {
                    Text("Your downloaded music is shared back while the app is running, so other users don't treat you as a leecher. Uploads only work with peers that have an open port.")
                }

                Section {
                    NavigationLink("Connection log") { LogView() }
                }
            }
            .navigationTitle("Account")
            .onAppear { username = model.username }
        }
    }
}

struct LogView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List(Array(model.logLines.indices.reversed()), id: \.self) { index in
            Text(model.logLines[index])
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
        .navigationTitle("Log")
        .navigationBarTitleDisplayMode(.inline)
    }
}
