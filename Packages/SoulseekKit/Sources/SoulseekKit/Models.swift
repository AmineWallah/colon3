import Foundation

public enum ConnectionType: String, Sendable {
    case peer = "P"
    case file = "F"
    case distributed = "D"
}

public enum TransferDirection: UInt32, Sendable {
    case download = 0
    case upload = 1
}

public struct FileAttributes: Equatable, Hashable, Sendable {
    public var bitrate: UInt32?
    public var duration: UInt32?
    public var vbr: Bool?
    public var sampleRate: UInt32?
    public var bitDepth: UInt32?

    public init(bitrate: UInt32? = nil, duration: UInt32? = nil, vbr: Bool? = nil,
                sampleRate: UInt32? = nil, bitDepth: UInt32? = nil) {
        self.bitrate = bitrate
        self.duration = duration
        self.vbr = vbr
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
    }

    var encoded: [(UInt32, UInt32)] {
        var pairs: [(UInt32, UInt32)] = []
        if let bitrate { pairs.append((0, bitrate)) }
        if let duration { pairs.append((1, duration)) }
        if let vbr { pairs.append((2, vbr ? 1 : 0)) }
        if let sampleRate { pairs.append((4, sampleRate)) }
        if let bitDepth { pairs.append((5, bitDepth)) }
        return pairs
    }
}

/// A file as advertised by a peer. `path` is the peer's virtual path, backslash-separated.
public struct SharedFile: Equatable, Hashable, Sendable {
    public var path: String
    public var size: UInt64
    public var attributes: FileAttributes

    public init(path: String, size: UInt64, attributes: FileAttributes = FileAttributes()) {
        self.path = path
        self.size = size
        self.attributes = attributes
    }

    private var components: [Substring] {
        path.split(whereSeparator: { $0 == "\\" || $0 == "/" })
    }

    public var filename: String { components.last.map(String.init) ?? path }

    /// Full virtual folder path ("Music\Artist\Album").
    public var folder: String {
        let parts = components.dropLast()
        return parts.joined(separator: "\\")
    }

    /// Last folder component ("Album").
    public var folderName: String {
        components.dropLast().last.map(String.init) ?? ""
    }

    public var fileExtension: String {
        guard let dot = filename.lastIndex(of: ".") else { return "" }
        return filename[filename.index(after: dot)...].lowercased()
    }
}

public struct SearchResponse: Sendable {
    public var username: String
    public var token: UInt32
    public var files: [SharedFile]
    public var privateFiles: [SharedFile]
    public var slotFree: Bool
    public var averageSpeed: UInt32
    public var queueLength: UInt32

    public init(username: String, token: UInt32, files: [SharedFile], privateFiles: [SharedFile] = [],
                slotFree: Bool, averageSpeed: UInt32, queueLength: UInt32) {
        self.username = username
        self.token = token
        self.files = files
        self.privateFiles = privateFiles
        self.slotFree = slotFree
        self.averageSpeed = averageSpeed
        self.queueLength = queueLength
    }
}

/// A folder in our own shared file list.
public struct SharedFolder: Equatable, Sendable {
    public var name: String
    /// Files with `path` set to the bare filename, as the shared list format expects.
    public var files: [SharedFile]

    public init(name: String, files: [SharedFile]) {
        self.name = name
        self.files = files
    }
}

extension ByteWriter {
    mutating func fileEntry(_ file: SharedFile) {
        u8(1)
        string(file.path)
        u64(file.size)
        string("")  // Extension field is obsolete; Nicotine+ sends it empty too.
        let attributes = file.attributes.encoded
        u32(UInt32(attributes.count))
        for (code, value) in attributes {
            u32(code)
            u32(value)
        }
    }
}

extension ByteReader {
    mutating func fileEntry() throws -> SharedFile {
        _ = try u8()  // Always 1
        let path = try string()
        let size = try fileSize()
        _ = try string()  // Extension, obsolete
        let count = try u32()
        var attributes = FileAttributes()
        for _ in 0..<count {
            let code = try u32()
            let value = try u32()
            switch code {
            case 0: attributes.bitrate = value
            case 1: attributes.duration = value
            case 2: attributes.vbr = value != 0
            case 4: attributes.sampleRate = value
            case 5: attributes.bitDepth = value
            default: break
            }
        }
        return SharedFile(path: path, size: size, attributes: attributes)
    }

    mutating func fileList() throws -> [SharedFile] {
        let count = try u32()
        var files: [SharedFile] = []
        files.reserveCapacity(Int(min(count, 10_000)))
        for _ in 0..<count {
            let file = try fileEntry()
            files.append(file)
        }
        return files
    }
}
