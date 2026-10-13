import Foundation
import Network
import UIKit

/// Wi-Fi Transfer: a small web server on the phone, like VLC's "Sharing via WiFi". Open the
/// address on a computer on the same network to drop music in or pull files out. Every request
/// needs the access code shown in the app, so other people on the network can't browse.
@MainActor
final class WiFiTransferServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var address: String?
    @Published private(set) var accessCode = WiFiTransferServer.makeCode()
    @Published private(set) var log: [String] = []
    @Published private(set) var lastError: String?

    /// Called (debounced) after files were added or removed.
    var onFilesChanged: (() -> Void)?

    private let root: URL
    private let queue = DispatchQueue(label: "colon3.wifi-transfer")
    private var listener: NWListener?
    private var rescanPending = false

    init(root: URL) {
        self.root = root
    }

    var url: String? {
        address.map { "\($0)/?k=\(accessCode)" }
    }

    func start() {
        guard listener == nil else { return }
        lastError = nil
        UIDeviceName.value = UIDevice.current.name
        openListener(port: NWEndpoint.Port(rawValue: 8080)!)
    }

    /// Tries 8080 first (easy to type), then any free port.
    private func openListener(port: NWEndpoint.Port?) {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let made: NWListener?
        if let port {
            made = try? NWListener(using: parameters, on: port)
        } else {
            made = try? NWListener(using: parameters)
        }
        guard let listener = made else {
            if port != nil { return openListener(port: nil) }
            lastError = "Couldn't open a port."
            return
        }
        self.listener = listener
        let root = self.root
        let code = accessCode
        let queue = self.queue

        listener.newConnectionHandler = { [weak self] connection in
            let session = HTTPSession(connection: connection, root: root, code: code, queue: queue) { event in
                Task { @MainActor in self?.handle(event) }
            }
            session.start()
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    self.isRunning = true
                    if let ip = Self.localIPv4(), let port = listener.port {
                        self.address = "http://\(ip):\(port.rawValue)"
                    } else {
                        self.address = nil
                        self.lastError = "Connect to Wi-Fi (or turn on Personal Hotspot) first."
                    }
                case let .failed(error):
                    listener.cancel()
                    self.listener = nil
                    if port != nil {
                        self.openListener(port: nil)  // 8080 taken: use any port
                    } else {
                        self.lastError = error.localizedDescription
                        self.isRunning = false
                    }
                case .cancelled:
                    if self.listener == nil { self.isRunning = false }
                default:
                    break
                }
            }
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        address = nil
    }

    func newCode() {
        accessCode = Self.makeCode()
        if listener != nil {
            stop()
            start()
        }
    }

    private func handle(_ event: HTTPSession.Event) {
        switch event {
        case let .log(line):
            log.insert(Formatting.time.string(from: Date()) + "  " + line, at: 0)
            if log.count > 30 { log.removeLast(log.count - 30) }
        case .filesChanged:
            guard !rescanPending else { return }
            rescanPending = true
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self.rescanPending = false
                self.onFilesChanged?()
            }
        }
    }

    private static func makeCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<6).map { _ in alphabet.randomElement()! })
    }

    /// The phone's address on Wi-Fi (en0) or its own hotspot (bridge*).
    nonisolated static func localIPv4() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        var found: [String: String] = [:]
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = entry.pointee
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                found[name] = String(cString: host)
            }
        }
        return found["en0"] ?? found.first(where: { $0.key.hasPrefix("bridge") })?.value
            ?? found.first(where: { $0.key.hasPrefix("en") })?.value
    }
}

/// One HTTP/1.1 request per connection (Connection: close keeps it simple).
private final class HTTPSession {
    enum Event {
        case log(String)
        case filesChanged
    }

    struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
    }

    private let connection: NWConnection
    private let root: URL
    private let code: String
    private let queue: DispatchQueue
    private let onEvent: (Event) -> Void
    private var buffer = Data()
    /// Keeps the session alive until the connection finishes.
    private var selfReference: HTTPSession?

    private static let allowedExtensions = LibraryStore.audioExtensions.union(LibraryStore.sidecarExtensions)

    init(connection: NWConnection, root: URL, code: String, queue: DispatchQueue, onEvent: @escaping (Event) -> Void) {
        self.connection = connection
        self.root = root
        self.code = code
        self.queue = queue
        self.onEvent = onEvent
    }

    func start() {
        selfReference = self
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.selfReference = nil
            default: break
            }
        }
        connection.start(queue: queue)
        readHead()
    }

    private func finish() {
        connection.cancel()
        selfReference = nil
    }

    // MARK: Parsing

    private func readHead() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            if let end = self.buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: self.buffer[..<end.lowerBound], as: UTF8.self)
                let rest = Data(self.buffer[end.upperBound...])
                self.buffer = Data()
                guard let request = Self.parse(head) else { return self.respond(400, text: "Bad request") }
                self.route(request, body: rest)
            } else if self.buffer.count > 32 * 1024 {
                self.respond(431, text: "Headers too large")
            } else if isComplete || error != nil {
                self.finish()
            } else {
                self.readHead()
            }
        }
    }

    private static func parse(_ head: String) -> Request? {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let target = String(parts[1])
        let pieces = target.split(separator: "?", maxSplits: 1).map(String.init)
        var query: [String: String] = [:]
        if pieces.count == 2 {
            for pair in pieces[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                let key = kv[0].removingPercentEncoding ?? kv[0]
                query[key] = kv.count > 1 ? (kv[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? kv[1]) : ""
            }
        }
        let path = pieces[0].removingPercentEncoding ?? pieces[0]
        return Request(method: String(parts[0]).uppercased(), path: path, query: query, headers: headers)
    }

    // MARK: Routing

    private func isAuthorized(_ request: Request) -> Bool {
        if request.query["k"]?.uppercased() == code { return true }
        let cookies = request.headers["cookie"] ?? ""
        return cookies.split(separator: ";").contains { $0.trimmingCharacters(in: .whitespaces) == "c3k=\(code)" }
    }

    private func route(_ request: Request, body: Data) {
        let authorized = isAuthorized(request)
        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            if authorized {
                respond(200, contentType: "text/html; charset=utf-8", body: Data(WebPage.html.utf8),
                        extraHeaders: ["Set-Cookie": "c3k=\(code); Path=/; SameSite=Strict; Max-Age=86400"])
            } else {
                respond(request.query["k"] == nil ? 200 : 403, contentType: "text/html; charset=utf-8",
                        body: Data(WebPage.login(failed: request.query["k"] != nil).utf8))
            }
            return
        case ("GET", "/favicon.ico"):
            respond(404, text: "")
            return
        default:
            break
        }
        guard authorized else { return respond(401, text: "Enter the access code shown in colon3.") }

        if request.method == "GET", request.path == "/api/list" {
            return respond(200, contentType: "application/json", body: listing())
        }
        guard request.path.hasPrefix("/file/") else { return respond(404, text: "Not found") }
        let relative = String(request.path.dropFirst("/file/".count))
        guard let target = safeURL(relative) else { return respond(400, text: "Bad path") }

        switch request.method {
        case "GET": download(target)
        case "PUT": upload(to: target, relative: relative, request: request, body: body)
        case "DELETE": delete(target, relative: relative)
        default: respond(405, text: "Method not allowed")
        }
    }

    /// Keeps every path inside the Music folder and to music-related files.
    private func safeURL(_ relative: String) -> URL? {
        let components = relative.split(separator: "/").map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") }),
              let last = components.last,
              Self.allowedExtensions.contains((last as NSString).pathExtension.lowercased()) else { return nil }
        let url = components.reduce(root) { $0.appendingPathComponent($1) }
        guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { return nil }
        return url
    }

    private func listing() -> Data {
        let rootPath = root.standardizedFileURL.path
        var files: [[String: Any]] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                guard Self.allowedExtensions.contains(url.pathExtension.lowercased()),
                      let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                var relative = String(url.standardizedFileURL.path.dropFirst(rootPath.count))
                if relative.hasPrefix("/") { relative.removeFirst() }
                files.append([
                    "path": relative,
                    "size": values.fileSize ?? 0,
                    "modified": Int(values.contentModificationDate?.timeIntervalSince1970 ?? 0),
                ])
            }
        }
        let free = (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        let object: [String: Any] = ["files": files, "free": free, "device": UIDeviceName.value]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }

    // MARK: Download

    private func download(_ url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else {
            return respond(404, text: "Not found")
        }
        let name = url.lastPathComponent
        let ascii = name.unicodeScalars.map { $0.isASCII && $0 != "\"" ? String($0) : "_" }.joined()
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/;,"))) ?? ascii
        let head = Self.head(200, headers: [
            "Content-Type": "application/octet-stream",
            "Content-Length": size.stringValue,
            "Content-Disposition": "attachment; filename=\"\(ascii)\"; filename*=UTF-8''\(encoded)",
        ])
        onEvent(.log("Sent \(name)"))
        connection.send(content: head, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { try? handle.close(); self?.finish(); return }
            self.stream(handle)
        })
    }

    private func stream(_ handle: FileHandle) {
        let chunk = handle.readData(ofLength: 256 * 1024)
        guard !chunk.isEmpty else {
            try? handle.close()
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
                self?.finish()
            })
            return
        }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { try? handle.close(); self?.finish(); return }
            self.stream(handle)
        })
    }

    // MARK: Upload

    private func upload(to target: URL, relative: String, request: Request, body: Data) {
        guard let lengthText = request.headers["content-length"], let length = Int(lengthText), length >= 0 else {
            return respond(411, text: "Content-Length required")
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("upload-" + UUID().uuidString)
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: temp) else { return respond(500, text: "Can't write") }
        var written = 0
        let first = body.prefix(length)
        if !first.isEmpty {
            handle.write(first)
            written = first.count
        }

        func done() {
            try? handle.close()
            let destination = placement(for: target, relative: relative)
            let fileManager = FileManager.default
            try? fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if destination.pathExtension.lowercased() == "lrc" { try? fileManager.removeItem(at: destination) }
            // Re-sending the same album shouldn't create "Song 2.flac" copies.
            if let existing = (try? fileManager.attributesOfItem(atPath: destination.path))?[.size] as? NSNumber,
               existing.intValue == length {
                try? fileManager.removeItem(at: temp)
                respond(200, contentType: "application/json", body: Data("{\"ok\":true,\"skipped\":true}".utf8))
                return
            }
            let final = Self.unique(destination)
            do {
                try fileManager.moveItem(at: temp, to: final)
                onEvent(.log("Received \(final.lastPathComponent)"))
                onEvent(.filesChanged)
                respond(200, contentType: "application/json", body: Data("{\"ok\":true}".utf8))
            } catch {
                try? fileManager.removeItem(at: temp)
                respond(500, text: "Couldn't save the file")
            }
        }

        func receiveMore() {
            guard written < length else { return done() }
            connection.receive(minimumIncompleteLength: 1, maximumLength: min(1 << 20, length - written)) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data, !data.isEmpty {
                    handle.write(data)
                    written += data.count
                }
                if written >= length {
                    done()
                } else if error != nil || isComplete {
                    try? handle.close()
                    try? FileManager.default.removeItem(at: temp)
                    self.finish()
                } else {
                    receiveMore()
                }
            }
        }
        receiveMore()
    }

    /// Loose files go into "Imported"; a loose .lrc goes next to the song with the same name.
    private func placement(for target: URL, relative: String) -> URL {
        guard !relative.contains("/") else { return target }
        if target.pathExtension.lowercased() == "lrc" {
            let base = target.deletingPathExtension().lastPathComponent.lowercased()
            if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for case let url as URL in enumerator
                where LibraryStore.audioExtensions.contains(url.pathExtension.lowercased())
                    && url.deletingPathExtension().lastPathComponent.lowercased() == base {
                    return url.deletingPathExtension().appendingPathExtension("lrc")
                }
            }
        }
        return root.appendingPathComponent("Imported", isDirectory: true).appendingPathComponent(target.lastPathComponent)
    }

    private static func unique(_ url: URL) -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var counter = 2
        while true {
            let candidate = url.deletingLastPathComponent().appendingPathComponent("\(base) \(counter).\(ext)")
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }

    // MARK: Delete

    private func delete(_ url: URL, relative: String) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return respond(404, text: "Not found") }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            return respond(500, text: "Couldn't delete")
        }
        // Remove folders left empty.
        var folder = url.deletingLastPathComponent()
        while folder.standardizedFileURL.path != root.standardizedFileURL.path,
              (try? fileManager.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
            try? fileManager.removeItem(at: folder)
            folder = folder.deletingLastPathComponent()
        }
        onEvent(.log("Deleted \(relative)"))
        onEvent(.filesChanged)
        respond(200, contentType: "application/json", body: Data("{\"ok\":true}".utf8))
    }

    // MARK: Responses

    private static func head(_ status: Int, headers: [String: String]) -> Data {
        let reason: [Int: String] = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                                     404: "Not Found", 405: "Method Not Allowed", 411: "Length Required",
                                     431: "Request Header Fields Too Large", 500: "Internal Server Error"]
        var text = "HTTP/1.1 \(status) \(reason[status] ?? "OK")\r\n"
        var all = headers
        all["Connection"] = "close"
        all["Cache-Control"] = "no-store"
        for (key, value) in all { text += "\(key): \(value)\r\n" }
        return Data((text + "\r\n").utf8)
    }

    private func respond(_ status: Int, contentType: String = "text/plain; charset=utf-8", body: Data,
                         extraHeaders: [String: String] = [:]) {
        var headers = extraHeaders
        headers["Content-Type"] = contentType
        headers["Content-Length"] = String(body.count)
        connection.send(content: Self.head(status, headers: headers) + body, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] _ in self?.finish() })
    }

    private func respond(_ status: Int, text: String) {
        respond(status, body: Data(text.utf8))
    }
}

/// UIDevice is main-actor only; read the name once for the background queue.
enum UIDeviceName {
    nonisolated(unsafe) static var value = "iPhone"
}

private enum WebPage {
    static func login(failed: Bool) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>colon3</title><style>
        :root{color-scheme:light dark;--bg:#f5f5f7;--card:#fff;--fg:#1d1d1f;--muted:#6e6e73;--accent:#ff2d55}
        @media (prefers-color-scheme:dark){:root{--bg:#000;--card:#1c1c1e;--fg:#f5f5f7;--muted:#98989d}}
        body{margin:0;font:16px -apple-system,system-ui,sans-serif;background:var(--bg);color:var(--fg);display:grid;place-items:center;min-height:100vh}
        form{background:var(--card);padding:32px;border-radius:18px;text-align:center;max-width:320px;width:calc(100% - 32px);box-sizing:border-box}
        h1{margin:0 0 4px;font-size:28px}p{color:var(--muted);margin:0 0 20px}
        input{font:600 24px ui-monospace,monospace;letter-spacing:6px;text-transform:uppercase;text-align:center;width:100%;box-sizing:border-box;padding:12px;border-radius:12px;border:1px solid var(--muted);background:transparent;color:var(--fg)}
        button{margin-top:14px;width:100%;padding:12px;border:0;border-radius:12px;background:var(--accent);color:#fff;font:600 17px -apple-system,system-ui,sans-serif}
        .err{color:#ff3b30}</style></head><body>
        <form method="get" action="/"><h1>colon3</h1>
        <p class="\(failed ? "err" : "")">\(failed ? "That code didn't match." : "Enter the code shown on your iPhone.")</p>
        <input name="k" maxlength="6" autocomplete="off" autofocus><button>Open</button></form></body></html>
        """
    }

    static let html = """
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>colon3 Wi-Fi Transfer</title><style>
    :root{color-scheme:light dark;--bg:#f5f5f7;--card:#fff;--fg:#1d1d1f;--muted:#6e6e73;--line:#e5e5ea;--accent:#ff2d55}
    @media (prefers-color-scheme:dark){:root{--bg:#000;--card:#1c1c1e;--fg:#f5f5f7;--muted:#98989d;--line:#2c2c2e}}
    *{box-sizing:border-box}body{margin:0;font:15px -apple-system,system-ui,sans-serif;background:var(--bg);color:var(--fg)}
    main{max-width:900px;margin:0 auto;padding:24px 16px 80px}
    header{display:flex;align-items:baseline;gap:12px;flex-wrap:wrap;margin-bottom:16px}h1{margin:0;font-size:30px}
    .muted{color:var(--muted)}
    #drop{border:2px dashed var(--line);border-radius:18px;padding:28px 16px;text-align:center;background:var(--card);transition:.15s}
    #drop.over{border-color:var(--accent);background:color-mix(in srgb,var(--accent) 10%,var(--card))}
    #drop b{display:block;font-size:18px;margin-bottom:6px}
    .btn{display:inline-block;margin:10px 4px 0;padding:9px 16px;border-radius:999px;border:0;background:var(--accent);color:#fff;font:600 14px inherit;cursor:pointer}
    .btn.alt{background:transparent;color:var(--accent);border:1px solid var(--accent)}
    #queue{margin:12px 0 0;display:grid;gap:6px}.job{background:var(--card);border-radius:12px;padding:10px 12px}
    .job .name{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.bar{height:4px;border-radius:2px;background:var(--line);margin-top:6px;overflow:hidden}
    .bar i{display:block;height:100%;width:0;background:var(--accent)}.job.done .bar i{background:#34c759}.job.err .bar i{background:#ff3b30}
    .tools{display:flex;gap:10px;align-items:center;margin:26px 0 10px;flex-wrap:wrap}
    #filter{flex:1;min-width:200px;padding:10px 14px;border-radius:12px;border:1px solid var(--line);background:var(--card);color:var(--fg);font:inherit}
    details{background:var(--card);border-radius:14px;margin-bottom:8px;overflow:hidden}
    summary{padding:12px 14px;cursor:pointer;font-weight:600;display:flex;gap:8px}summary span{margin-left:auto;font-weight:400}
    .file{display:flex;align-items:center;gap:10px;padding:8px 14px;border-top:1px solid var(--line)}
    .file .n{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    .file a,.file button{color:var(--accent);background:none;border:0;font:inherit;cursor:pointer;text-decoration:none;padding:4px}
    .file button{color:var(--muted)}.file button:hover{color:#ff3b30}
    </style></head><body><main>
    <header><h1>colon3</h1><span class="muted" id="info">Wi-Fi Transfer</span></header>
    <div id="drop"><b>Drop music here</b><span class="muted">Files or whole album folders. Covers and .lrc lyrics come along.</span><br>
    <label class="btn">Choose Files<input type="file" id="files" multiple hidden></label>
    <label class="btn alt">Choose Folder<input type="file" id="folder" webkitdirectory hidden></label></div>
    <div id="queue"></div>
    <div class="tools"><input id="filter" placeholder="Filter your library"><span class="muted" id="count"></span></div>
    <div id="list"></div></main>
    <script>
    const allowed=/\\.(mp3|m4a|m4b|mp4|aac|alac|flac|wav|aif|aiff|caf|jpe?g|png|webp|heic|lrc)$/i;
    const enc=p=>p.split('/').map(encodeURIComponent).join('/');
    const size=b=>b>1e9?(b/1e9).toFixed(1)+' GB':b>1e6?(b/1e6).toFixed(1)+' MB':Math.round(b/1e3)+' KB';
    const esc=s=>s.replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
    let files=[],jobs=[],running=0;
    async function load(){const r=await fetch('/api/list');if(r.status==401){location='/';return}
      const j=await r.json();files=j.files;document.getElementById('info').textContent=j.device+' · '+size(j.free)+' free';render()}
    function render(){const q=document.getElementById('filter').value.toLowerCase();const groups={};
      for(const f of files){if(q&&!f.path.toLowerCase().includes(q))continue;const i=f.path.lastIndexOf('/');
        const dir=i<0?'(Music)':f.path.slice(0,i);(groups[dir]=groups[dir]||[]).push(f)}
      const dirs=Object.keys(groups).sort((a,b)=>a.localeCompare(b));let n=0;
      document.getElementById('list').innerHTML=dirs.map(d=>{const g=groups[d].sort((a,b)=>a.path.localeCompare(b.path,undefined,{numeric:true}));n+=g.length;
        return '<details'+(q?' open':'')+'><summary>'+esc(d)+'<span class="muted">'+g.length+' · '+size(g.reduce((s,f)=>s+f.size,0))+'</span></summary>'+
        g.map(f=>'<div class="file"><span class="n">'+esc(f.path.slice(f.path.lastIndexOf('/')+1))+'</span><span class="muted">'+size(f.size)+
        '</span><a href="/file/'+enc(f.path)+'" download>Download</a><button data-p="'+esc(f.path)+'">Delete</button></div>').join('')+'</details>'}).join('');
      document.getElementById('count').textContent=n+' files'}
    document.getElementById('list').addEventListener('click',async e=>{const p=e.target.dataset&&e.target.dataset.p;if(!p)return;
      if(!confirm('Delete '+p+' from the iPhone?'))return;await fetch('/file/'+enc(p),{method:'DELETE'});load()});
    document.getElementById('filter').oninput=render;
    function add(list){for(const {file,path} of list){if(!allowed.test(file.name))continue;
      const el=document.createElement('div');el.className='job';el.innerHTML='<div class="name">'+esc(path)+'</div><div class="bar"><i></i></div>';
      document.getElementById('queue').prepend(el);jobs.push({file,path,el})}pump()}
    function pump(){while(running<2&&jobs.length){const j=jobs.shift();running++;send(j).finally(()=>{running--;pump();if(!running&&!jobs.length)load()})}}
    function send(j){return new Promise(res=>{const x=new XMLHttpRequest();x.open('PUT','/file/'+enc(j.path));
      x.upload.onprogress=e=>{if(e.lengthComputable)j.el.querySelector('i').style.width=(100*e.loaded/e.total)+'%'};
      x.onload=()=>{j.el.classList.add(x.status==200?'done':'err');j.el.querySelector('i').style.width='100%';res()};
      x.onerror=()=>{j.el.classList.add('err');res()};x.send(j.file)})}
    document.getElementById('files').onchange=e=>add([...e.target.files].map(f=>({file:f,path:f.name})));
    document.getElementById('folder').onchange=e=>add([...e.target.files].map(f=>({file:f,path:f.webkitRelativePath||f.name})));
    const drop=document.getElementById('drop');
    ['dragenter','dragover'].forEach(t=>drop.addEventListener(t,e=>{e.preventDefault();drop.classList.add('over')}));
    ['dragleave','drop'].forEach(t=>drop.addEventListener(t,e=>{e.preventDefault();drop.classList.remove('over')}));
    async function walk(entry,prefix,out){if(entry.isFile){await new Promise(r=>entry.file(f=>{out.push({file:f,path:prefix+f.name});r()},r))}
      else if(entry.isDirectory){const reader=entry.createReader();let batch;do{batch=await new Promise(r=>reader.readEntries(r,()=>r([])));
        for(const c of batch)await walk(c,prefix+entry.name+'/',out)}while(batch.length)}}
    drop.addEventListener('drop',async e=>{const out=[];const items=[...e.dataTransfer.items].map(i=>i.webkitGetAsEntry&&i.webkitGetAsEntry()).filter(Boolean);
      if(items.length){for(const it of items)await walk(it,'',out)}else{for(const f of e.dataTransfer.files)out.push({file:f,path:f.name})}add(out)});
    load();
    </script></body></html>
    """
}
