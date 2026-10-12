import Foundation

/// Messages we send to the Soulseek server. Codes and layouts follow Nicotine+'s SLSKPROTOCOL.md.
public enum ServerRequest: Sendable {
    case login(username: String, password: String, majorVersion: UInt32, minorVersion: UInt32)
    case setWaitPort(UInt32)
    case getPeerAddress(username: String)
    case connectToPeer(token: UInt32, username: String, type: ConnectionType)
    case fileSearch(token: UInt32, query: String)
    case setStatus(UInt32)
    case serverPing
    case sharedFoldersFiles(folders: UInt32, files: UInt32)
    case haveNoParent(Bool)
    case acceptChildren(Bool)
    case branchLevel(UInt32)
    case branchRoot(String)
    case cantConnectToPeer(token: UInt32, username: String)

    /// "Experimental clients may use major version 177" (SLSKPROTOCOL.md, Login).
    public static let majorVersion: UInt32 = 177
    public static let minorVersion: UInt32 = 1

    public var code: UInt32 {
        switch self {
        case .login: return 1
        case .setWaitPort: return 2
        case .getPeerAddress: return 3
        case .connectToPeer: return 18
        case .fileSearch: return 26
        case .setStatus: return 28
        case .serverPing: return 32
        case .sharedFoldersFiles: return 35
        case .haveNoParent: return 71
        case .acceptChildren: return 100
        case .branchLevel: return 126
        case .branchRoot: return 127
        case .cantConnectToPeer: return 1001
        }
    }

    public var payload: Data {
        var writer = ByteWriter()
        switch self {
        case let .login(username, password, major, minor):
            writer.string(username)
            writer.string(password)
            writer.u32(major)
            writer.string(MD5.hex(username + password))
            writer.u32(minor)
        case let .setWaitPort(port):
            writer.u32(port)
        case let .getPeerAddress(username):
            writer.string(username)
        case let .connectToPeer(token, username, type):
            writer.u32(token)
            writer.string(username)
            writer.string(type.rawValue)
        case let .fileSearch(token, query):
            writer.u32(token)
            writer.string(query)
        case let .setStatus(status):
            writer.u32(status)
        case .serverPing:
            break
        case let .sharedFoldersFiles(folders, files):
            writer.u32(folders)
            writer.u32(files)
        case let .haveNoParent(value):
            writer.bool(value)
        case let .acceptChildren(value):
            writer.bool(value)
        case let .branchLevel(level):
            writer.u32(level)
        case let .branchRoot(root):
            writer.string(root)
        case let .cantConnectToPeer(token, username):
            writer.u32(token)
            writer.string(username)
        }
        return writer.data
    }

    public var frame: Data { ByteWriter.frame(code: code, payload: payload) }
}

/// Server messages we care about. Everything else decodes to `.other`.
public enum ServerEvent: Equatable, Sendable {
    case loginSucceeded(greeting: String, ownIP: String)
    case loginFailed(reason: String, detail: String?)
    case peerAddress(username: String, ip: String, port: UInt32)
    case connectToPeer(username: String, type: String, ip: String, port: UInt32, token: UInt32)
    case cantConnectToPeer(token: UInt32)
    case relogged
    case other(code: UInt32)

    /// `body` is a frame body as returned by `FrameBuffer` (code + payload).
    public static func decode(_ body: Data) throws -> ServerEvent {
        var reader = ByteReader(body)
        let code = try reader.u32()
        switch code {
        case 1:
            if try reader.bool() {
                let greeting = try reader.string()
                let ip = try reader.ipv4()
                return .loginSucceeded(greeting: greeting, ownIP: ip)
            }
            let reason = try reader.string()
            let detail: String? = try reader.hasRemaining ? reader.string() : nil
            return .loginFailed(reason: reason, detail: detail)
        case 3:
            let username = try reader.string()
            let ip = try reader.ipv4()
            let port = try reader.u32()
            return .peerAddress(username: username, ip: ip, port: port)
        case 18:
            let username = try reader.string()
            let type = try reader.string()
            let ip = try reader.ipv4()
            let port = try reader.u32()
            let token = try reader.u32()
            return .connectToPeer(username: username, type: type, ip: ip, port: port, token: token)
        case 41:
            return .relogged
        case 1001:
            let token = try reader.u32()
            return .cantConnectToPeer(token: token)
        default:
            return .other(code: code)
        }
    }
}
