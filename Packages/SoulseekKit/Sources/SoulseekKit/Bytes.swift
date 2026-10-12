import Foundation

public enum ProtocolError: Error, Equatable {
    case truncated
    case frameTooLarge(Int)
    case compressionFailed
    case decompressionFailed
    case malformed(String)
}

/// Little-endian writer for Soulseek's packing rules (see SLSKPROTOCOL.md, "Packing").
public struct ByteWriter {
    public private(set) var data = Data()

    public init() {}

    public mutating func u8(_ value: UInt8) { data.append(value) }
    public mutating func bool(_ value: Bool) { data.append(value ? 1 : 0) }

    public mutating func u16(_ value: UInt16) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    public mutating func u32(_ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    public mutating func u64(_ value: UInt64) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    /// uint32 length followed by UTF-8 bytes.
    public mutating func string(_ value: String) {
        let bytes = Array(value.utf8)
        u32(UInt32(bytes.count))
        data.append(contentsOf: bytes)
    }

    /// Bytes without a length prefix.
    public mutating func raw(_ bytes: Data) { data.append(bytes) }
}

/// Little-endian reader. Throws `ProtocolError.truncated` instead of trapping on short input.
public struct ByteReader {
    private let bytes: [UInt8]
    public private(set) var offset = 0

    public init(_ data: Data) { bytes = [UInt8](data) }
    public init(_ bytes: [UInt8]) { self.bytes = bytes }

    public var remaining: Int { bytes.count - offset }
    public var hasRemaining: Bool { offset < bytes.count }

    private func require(_ count: Int) throws {
        if count < 0 || offset + count > bytes.count { throw ProtocolError.truncated }
    }

    public mutating func u8() throws -> UInt8 {
        try require(1)
        let value = bytes[offset]
        offset += 1
        return value
    }

    public mutating func bool() throws -> Bool { try u8() != 0 }

    public mutating func u16() throws -> UInt16 {
        try require(2)
        let value = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        offset += 2
        return value
    }

    public mutating func u32() throws -> UInt32 {
        try require(4)
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(bytes[offset + index]) << (8 * index)
        }
        offset += 4
        return value
    }

    public mutating func u64() throws -> UInt64 {
        try require(8)
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(bytes[offset + index]) << (8 * index)
        }
        offset += 8
        return value
    }

    /// File sizes are uint64, except Soulseek NS fills the upper half of >2 GiB sizes with 0xFF.
    /// Same workaround as Nicotine+'s `unpack_file_size`.
    public mutating func fileSize() throws -> UInt64 {
        try require(8)
        if bytes[offset + 7] == 255 {
            let lower = try u32()
            offset += 4
            return UInt64(lower)
        }
        return try u64()
    }

    public mutating func raw(_ count: Int) throws -> [UInt8] {
        try require(count)
        let slice = Array(bytes[offset..<(offset + count)])
        offset += count
        return slice
    }

    /// UTF-8, falling back to Latin-1 for legacy clients (as Nicotine+ does).
    public mutating func string() throws -> String {
        let length = try Int(u32())
        let content = try raw(length)
        if let text = String(bytes: content, encoding: .utf8) { return text }
        return String(bytes: content, encoding: .isoLatin1) ?? ""
    }

    /// IPv4 addresses are sent as a little-endian uint32 whose most significant byte is the first octet.
    public mutating func ipv4() throws -> String {
        let value = try u32()
        return "\(value >> 24 & 0xFF).\(value >> 16 & 0xFF).\(value >> 8 & 0xFF).\(value & 0xFF)"
    }

    public func rest() -> Data { Data(bytes[offset...]) }
}

extension Data {
    /// Hex helper for logging and tests.
    public var hexString: String { map { byte in
        let digits = String(byte, radix: 16)
        return digits.count == 1 ? "0" + digits : digits
    }.joined() }

    public init?(hexString: String) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2, limitedBy: hexString.endIndex) ?? hexString.endIndex
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
