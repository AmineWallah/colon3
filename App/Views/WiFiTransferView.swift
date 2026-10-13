import SwiftUI
import UIKit

struct WiFiTransferView: View {
    @EnvironmentObject private var server: WiFiTransferServer

    var body: some View {
        List {
            Section {
                Toggle("Wi-Fi Transfer", isOn: Binding(get: { server.isRunning }, set: { $0 ? server.start() : server.stop() }))
            } footer: {
                Text("Open the address in a browser on a computer on the same Wi-Fi to add music or download files. Keep this screen open while transferring.")
            }

            if server.isRunning, let address = server.address {
                Section("On your computer, open") {
                    Text(address)
                        .font(.title3.monospaced().weight(.semibold))
                        .textSelection(.enabled)
                    LabeledContent("Access Code") {
                        Text(server.accessCode)
                            .font(.title3.monospaced().weight(.bold))
                            .foregroundStyle(.tint)
                            .textSelection(.enabled)
                    }
                    if let url = server.url {
                        Button {
                            UIPasteboard.general.string = url
                        } label: {
                            Label("Copy Link with Code", systemImage: "doc.on.doc")
                        }
                        ShareLink(item: url) {
                            Label("Send Link to Computer…", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button("New Access Code") { server.newCode() }
                }
            }

            if let error = server.lastError {
                Section {
                    Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.orange)
                }
            }

            if !server.log.isEmpty {
                Section("Activity") {
                    ForEach(server.log, id: \.self) { line in
                        Text(line).font(.caption.monospaced()).lineLimit(2)
                    }
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("colon3's Music folder is also shared over a cable:")
                    Text("• Mac: Finder › iPhone › Files › colon3\n• Windows: Apple Devices app › Files\n• Linux: libimobiledevice + ifuse")
                        .foregroundStyle(.secondary)
                    Text("ifuse --documents com.aminewallah.colon3 ~/iphone")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
                .font(.subheadline)
                .padding(.vertical, 4)
            } header: {
                Text("Wired")
            } footer: {
                Text("Wired needs the iPhone to trust the computer. After copying files in, pull down on the library or tap Rescan.")
            }
        }
        .navigationTitle("Wi-Fi Transfer")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            server.start()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}
