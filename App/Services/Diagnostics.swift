import Combine
import Foundation
import MetricKit
import UIKit

/// App-wide logging and crash capture, all kept on the phone. A rolling in-memory buffer feeds
/// the Logs screen; the same lines are appended to a session file. Crashes are caught two ways:
/// MetricKit delivers a full diagnostic on the next launch (the reliable path), and lightweight
/// exception/signal handlers leave a short report immediately (best-effort).
final class Diagnostics: NSObject, @unchecked Sendable {
    static let shared = Diagnostics()

    /// Fires (coalesced) when new lines arrive, so an open Logs screen can refresh.
    let didLog = PassthroughSubject<Void, Never>()

    private let lock = NSLock()
    private var buffer: [String] = []
    private let maxLines = 3000
    private let writeQueue = DispatchQueue(label: "colon3.diagnostics")
    private var sessionHandle: FileHandle?

    let logsDirectory: URL
    let crashesDirectory: URL
    private let sessionFile: URL

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private override init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Diagnostics", isDirectory: true)
        logsDirectory = base
        crashesDirectory = base.appendingPathComponent("Crashes", isDirectory: true)
        try? FileManager.default.createDirectory(at: crashesDirectory, withIntermediateDirectories: true)
        sessionFile = base.appendingPathComponent("session.log")
        super.init()
    }

    /// Call once, early. Opens the session file, installs crash handlers and MetricKit.
    func start() {
        // Keep the previous session's log so a crash's lead-up survives the relaunch.
        let previous = logsDirectory.appendingPathComponent("session-previous.log")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: sessionFile, to: previous)
        FileManager.default.createFile(atPath: sessionFile.path, contents: nil)
        sessionHandle = try? FileHandle(forWritingTo: sessionFile)

        let device = UIDevice.current
        log("colon3 \(Bundle.appVersion) on \(device.systemName) \(device.systemVersion)", category: "app")
        installCrashHandlers()
        MXMetricManager.shared.add(self)
    }

    // MARK: Logging

    func log(_ message: String, category: String = "app") {
        let line = "\(Self.stamp.string(from: Date())) [\(category)] \(message)"
        lock.lock()
        buffer.append(line)
        if buffer.count > maxLines { buffer.removeFirst(buffer.count - maxLines) }
        lock.unlock()

        writeQueue.async { [weak self] in
            guard let self, let data = (line + "\n").data(using: .utf8) else { return }
            self.sessionHandle?.write(data)
        }
        didLog.send()
    }

    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }

    func clearSession() {
        lock.lock(); buffer.removeAll(); lock.unlock()
        writeQueue.async { [weak self] in
            self?.sessionHandle?.truncateFile(atOffset: 0)
        }
        didLog.send()
    }

    /// The whole session log as text, for sharing.
    func exportSessionText() -> String {
        lines.joined(separator: "\n")
    }

    // MARK: Crash reports

    struct CrashReport: Identifiable {
        let url: URL
        let date: Date
        let kind: String
        var id: String { url.lastPathComponent }
        var title: String {
            DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short) + " · " + kind
        }
    }

    func crashReports() -> [CrashReport] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: crashesDirectory, includingPropertiesForKeys: keys)) ?? []
        return files
            .filter { $0.pathExtension == "txt" || $0.pathExtension == "json" }
            .map { url in
                let date = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
                let kind = url.pathExtension == "json" ? "MetricKit" : "Signal"
                return CrashReport(url: url, date: date, kind: kind)
            }
            .sorted { $0.date > $1.date }
    }

    func readCrash(_ report: CrashReport) -> String {
        (try? String(contentsOf: report.url, encoding: .utf8)) ?? "Couldn't read this report."
    }

    func clearCrashes() {
        for file in (try? FileManager.default.contentsOfDirectory(at: crashesDirectory, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: Crash capture

    private func installCrashHandlers() {
        NSSetUncaughtExceptionHandler { exception in
            let text = """
            Uncaught exception
            Name: \(exception.name.rawValue)
            Reason: \(exception.reason ?? "–")

            \(exception.callStackSymbols.joined(separator: "\n"))
            """
            Diagnostics.shared.writeCrash(text)
        }
        for signalNumber in [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGTRAP] {
            signal(signalNumber) { received in
                let text = "Signal \(received)\n\n" + Thread.callStackSymbols.joined(separator: "\n")
                Diagnostics.shared.writeCrash(text)
                // Restore the default handler and re-raise so the OS still records it.
                signal(received, SIG_DFL)
                raise(received)
            }
        }
    }

    /// Best-effort synchronous write from a crash context.
    fileprivate func writeCrash(_ text: String) {
        // The signal may have landed while the lock was held; don't block, just skip the tail.
        var recent = ""
        if lock.try() {
            recent = buffer.suffix(80).joined(separator: "\n")
            lock.unlock()
        }
        let full = text + "\n\n--- recent log ---\n" + recent + "\n"
        let url = crashesDirectory.appendingPathComponent("crash-\(Int(Date().timeIntervalSince1970)).txt")
        try? full.data(using: .utf8)?.write(to: url)
    }
}

extension Diagnostics: MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXMetricPayload]) {}

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads where !payload.crashDiagnostics.isNilOrEmpty {
            let date = payload.timeStampEnd
            let name = "metrickit-\(Int(date.timeIntervalSince1970)).json"
            try? payload.jsonRepresentation().write(to: crashesDirectory.appendingPathComponent(name))
        }
    }
}

private extension Optional where Wrapped == [MXCrashDiagnostic] {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}

extension Bundle {
    static var appVersion: String {
        let version = main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(version) (\(build))"
    }
}
