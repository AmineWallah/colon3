import Foundation
import CZlib

/// zlib (RFC 1950, with header) as used by FileSearchResponse and SharedFileListResponse.
public enum Zlib {
    /// Same cap Nicotine+ uses for search responses.
    public static let defaultLimit = 128 * 1024 * 1024

    public static func decompress(_ input: Data, limit: Int = defaultLimit) throws -> Data {
        guard !input.isEmpty else { throw ProtocolError.decompressionFailed }

        var stream = z_stream()
        guard inflateInit_(&stream, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw ProtocolError.decompressionFailed
        }
        defer { inflateEnd(&stream) }

        let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: input.count)
        defer { inputBuffer.deallocate() }
        input.copyBytes(to: inputBuffer, count: input.count)
        stream.next_in = inputBuffer
        stream.avail_in = UInt32(input.count)

        let chunkSize = 64 * 1024
        let outputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { outputBuffer.deallocate() }

        var output = Data()
        while true {
            stream.next_out = outputBuffer
            stream.avail_out = UInt32(chunkSize)
            let status = inflate(&stream, Z_NO_FLUSH)
            let produced = chunkSize - Int(stream.avail_out)
            if produced > 0 { output.append(outputBuffer, count: produced) }
            if output.count > limit { throw ProtocolError.decompressionFailed }

            if status == Z_STREAM_END { return output }
            if status != Z_OK { throw ProtocolError.decompressionFailed }
            if stream.avail_in == 0 && produced < chunkSize {
                // Input ran out before the end of the zlib stream.
                throw ProtocolError.truncated
            }
        }
    }

    public static func compress(_ input: Data, level: Int32 = 6) throws -> Data {
        let source = [UInt8](input)
        var destinationLength = compressBound(uLong(source.count))
        var destination = [UInt8](repeating: 0, count: Int(destinationLength))
        let status = compress2(&destination, &destinationLength, source, uLong(source.count), level)
        guard status == Z_OK else { throw ProtocolError.compressionFailed }
        return Data(destination.prefix(Int(destinationLength)))
    }
}
