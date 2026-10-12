import Foundation

/// First message on a new peer connection (uint8 code).
public enum PeerInitMessage: Equatable, Sendable {
    /// Sent by the side answering an indirect connection request (ConnectToPeer).
    case pierceFirewall(token: UInt32)
    /// Sent by the side opening a direct connection.
    case peerInit(username: String, type: String)

    public var frame: Data {
        var writer = ByteWriter()
        switch self {
        case let .pierceFirewall(token):
            writer.u32(token)
            return ByteWriter.initFrame(code: 0, payload: writer.data)
        case let .peerInit(username, type):
            writer.string(username)
            writer.string(type)
            writer.u32(0)  // Token is always 0 today
            return ByteWriter.initFrame(code: 1, payload: writer.data)
        }
    }

    public static func decode(_ body: Data) throws -> PeerInitMessage {
        var reader = ByteReader(body)
        switch try reader.u8() {
        case 0:
            let token = try reader.u32()
            return .pierceFirewall(token: token)
        case 1:
            let username = try reader.string()
            let type = try reader.string()
            return .peerInit(username: username, type: type)
        case let code:
            throw ProtocolError.malformed("Unknown peer init code \(code)")
        }
    }
}

/// Messages exchanged over a `P` connection (uint32 code).
public enum PeerMessage: Sendable {
    case sharedFileListRequest
    case sharedFileListResponse(folders: [SharedFolder])
    case fileSearchResponse(SearchResponse)
    case userInfoRequest
    case folderContentsRequest(token: UInt32, folder: String)
    /// `folders` holds the requested folder and its subfolders; file paths are bare filenames.
    case folderContentsResponse(token: UInt32, folder: String, folders: [SharedFolder])
    case userInfoResponse(description: String, totalUploads: UInt32, queueSize: UInt32, slotsFree: Bool)
    case transferRequest(direction: TransferDirection, token: UInt32, filename: String, size: UInt64?)
    case transferResponse(token: UInt32, allowed: Bool, reason: String?, size: UInt64?)
    case queueUpload(filename: String)
    case placeInQueueResponse(filename: String, place: UInt32)
    case uploadFailed(filename: String)
    case uploadDenied(filename: String, reason: String)
    case placeInQueueRequest(filename: String)
    case unknown(code: UInt32)

    public var code: UInt32 {
        switch self {
        case .sharedFileListRequest: return 4
        case .sharedFileListResponse: return 5
        case .fileSearchResponse: return 9
        case .userInfoRequest: return 15
        case .userInfoResponse: return 16
        case .folderContentsRequest: return 36
        case .folderContentsResponse: return 37
        case .transferRequest: return 40
        case .transferResponse: return 41
        case .queueUpload: return 43
        case .placeInQueueResponse: return 44
        case .uploadFailed: return 46
        case .uploadDenied: return 50
        case .placeInQueueRequest: return 51
        case let .unknown(code): return code
        }
    }

    public func payload() throws -> Data {
        var writer = ByteWriter()
        switch self {
        case .sharedFileListRequest, .userInfoRequest, .unknown:
            break

        case let .sharedFileListResponse(folders):
            writer.u32(UInt32(folders.count))
            for folder in folders {
                writer.string(folder.name)
                writer.u32(UInt32(folder.files.count))
                for file in folder.files { writer.fileEntry(file) }
            }
            writer.u32(0)  // Unknown, always 0
            writer.u32(0)  // No private folders
            return try Zlib.compress(writer.data)

        case let .fileSearchResponse(response):
            writer.string(response.username)
            writer.u32(response.token)
            writer.u32(UInt32(response.files.count))
            for file in response.files { writer.fileEntry(file) }
            writer.bool(response.slotFree)
            writer.u32(response.averageSpeed)
            writer.u32(response.queueLength)
            writer.u32(0)
            return try Zlib.compress(writer.data)

        case let .folderContentsRequest(token, folder):
            writer.u32(token)
            writer.string(folder)

        case let .folderContentsResponse(token, folder, folders):
            writer.u32(token)
            writer.string(folder)
            writer.u32(UInt32(folders.count))
            for entry in folders {
                writer.string(entry.name)
                writer.u32(UInt32(entry.files.count))
                for file in entry.files { writer.fileEntry(file) }
            }
            return try Zlib.compress(writer.data)

        case let .userInfoResponse(description, totalUploads, queueSize, slotsFree):
            writer.string(description)
            writer.bool(false)  // No picture
            writer.u32(totalUploads)
            writer.u32(queueSize)
            writer.bool(slotsFree)
            writer.u32(0)  // Nobody may upload files to us

        case let .transferRequest(direction, token, filename, size):
            writer.u32(direction.rawValue)
            writer.u32(token)
            writer.string(filename)
            if direction == .upload { writer.u64(size ?? 0) }

        case let .transferResponse(token, allowed, reason, size):
            writer.u32(token)
            writer.bool(allowed)
            if let reason { writer.string(reason) }
            if let size { writer.u64(size) }

        case let .queueUpload(filename),
             let .uploadFailed(filename),
             let .placeInQueueRequest(filename):
            writer.string(filename)

        case let .placeInQueueResponse(filename, place):
            writer.string(filename)
            writer.u32(place)

        case let .uploadDenied(filename, reason):
            writer.string(filename)
            writer.string(reason)
        }
        return writer.data
    }

    public func frame() throws -> Data {
        let body = try payload()
        return ByteWriter.frame(code: code, payload: body)
    }

    /// `body` is a frame body as returned by `FrameBuffer` (code + payload).
    public static func decode(_ body: Data) throws -> PeerMessage {
        var reader = ByteReader(body)
        let code = try reader.u32()
        switch code {
        case 4:
            return .sharedFileListRequest

        case 5:
            var list = ByteReader(try Zlib.decompress(reader.rest()))
            let folderCount = try list.u32()
            var folders: [SharedFolder] = []
            for _ in 0..<folderCount {
                let name = try list.string()
                let files = try list.fileList()
                folders.append(SharedFolder(name: name, files: files))
            }
            return .sharedFileListResponse(folders: folders)

        case 9:
            var inner = ByteReader(try Zlib.decompress(reader.rest()))
            let username = try inner.string()
            let token = try inner.u32()
            let files = try inner.fileList()
            let slotFree = try inner.bool()
            let speed = try inner.u32()
            let queue = try inner.u32()
            var privateFiles: [SharedFile] = []
            if inner.hasRemaining { _ = try inner.u32() }
            if inner.hasRemaining { privateFiles = try inner.fileList() }
            return .fileSearchResponse(SearchResponse(
                username: username, token: token, files: files, privateFiles: privateFiles,
                slotFree: slotFree, averageSpeed: speed, queueLength: queue))

        case 15:
            return .userInfoRequest

        case 36:
            let token = try reader.u32()
            let folder = try reader.string()
            return .folderContentsRequest(token: token, folder: folder)

        case 37:
            var inner = ByteReader(try Zlib.decompress(reader.rest()))
            let token = try inner.u32()
            let folder = try inner.string()
            let folderCount = try inner.u32()
            var folders: [SharedFolder] = []
            for _ in 0..<folderCount {
                let name = try inner.string().replacingOccurrences(of: "/", with: "\\")
                let files = try inner.fileList()
                folders.append(SharedFolder(name: name, files: files))
            }
            return .folderContentsResponse(token: token, folder: folder, folders: folders)

        case 40:
            let rawDirection = try reader.u32()
            guard let direction = TransferDirection(rawValue: rawDirection) else {
                throw ProtocolError.malformed("Transfer direction \(rawDirection)")
            }
            let token = try reader.u32()
            let filename = try reader.string()
            let size: UInt64? = try (direction == .upload && reader.hasRemaining) ? reader.u64() : nil
            return .transferRequest(direction: direction, token: token, filename: filename, size: size)

        case 41:
            let token = try reader.u32()
            let allowed = try reader.bool()
            var reason: String?
            var size: UInt64?
            if reader.hasRemaining {
                if allowed { size = try reader.u64() } else { reason = try reader.string() }
            }
            return .transferResponse(token: token, allowed: allowed, reason: reason, size: size)

        case 43:
            let filename = try reader.string()
            return .queueUpload(filename: filename)

        case 44:
            let filename = try reader.string()
            let place = try reader.u32()
            return .placeInQueueResponse(filename: filename, place: place)

        case 46:
            let filename = try reader.string()
            return .uploadFailed(filename: filename)

        case 50:
            let filename = try reader.string()
            let reason = try reader.hasRemaining ? reader.string() : ""
            return .uploadDenied(filename: filename, reason: reason)

        case 51:
            let filename = try reader.string()
            return .placeInQueueRequest(filename: filename)

        default:
            return .unknown(code: code)
        }
    }
}
