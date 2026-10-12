import Foundation

/// Reassembles length-prefixed frames from a TCP byte stream.
///
/// Server, peer-init and peer messages all start with a uint32 length; the returned
/// frame body is everything after it (message code + payload).
public struct FrameBuffer {
    /// Peers can legitimately send large shared file lists, but nothing near this.
    public static let maxFrameSize = 256 * 1024 * 1024

    private var buffer = Data()

    public init() {}

    public var bufferedCount: Int { buffer.count }

    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    public mutating func nextFrame() throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let start = buffer.startIndex
        var length = 0
        for index in 0..<4 {
            length |= Int(buffer[start + index]) << (8 * index)
        }
        guard length <= FrameBuffer.maxFrameSize else { throw ProtocolError.frameTooLarge(length) }
        guard buffer.count >= 4 + length else { return nil }

        let body = buffer.subdata(in: (start + 4)..<(start + 4 + length))
        buffer = buffer.subdata(in: (start + 4 + length)..<buffer.endIndex)
        return body
    }

    /// Hands over whatever is buffered (used when a connection switches to raw file data).
    public mutating func drain() -> Data {
        let rest = buffer
        buffer = Data()
        return rest
    }
}

extension ByteWriter {
    /// uint32 length + uint32 code + payload (server and peer messages).
    static func frame(code: UInt32, payload: Data) -> Data {
        var writer = ByteWriter()
        writer.u32(UInt32(payload.count + 4))
        writer.u32(code)
        writer.raw(payload)
        return writer.data
    }

    /// uint32 length + uint8 code + payload (peer init messages).
    static func initFrame(code: UInt8, payload: Data) -> Data {
        var writer = ByteWriter()
        writer.u32(UInt32(payload.count + 1))
        writer.u8(code)
        writer.raw(payload)
        return writer.data
    }
}
