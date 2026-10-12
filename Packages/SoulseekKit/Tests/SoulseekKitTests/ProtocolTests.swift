import XCTest
@testable import SoulseekKit

/// Checks our codec against bytes produced by Nicotine+'s own encoders (see Fixtures.swift).
final class ProtocolTests: XCTestCase {
    private func bytes(_ hex: String) -> Data {
        guard let data = Data(hexString: hex) else {
            XCTFail("Bad fixture hex")
            return Data()
        }
        return data
    }

    /// Runs a fixture through FrameBuffer and returns the single frame body.
    private func body(_ hex: String) throws -> Data {
        var buffer = FrameBuffer()
        buffer.append(bytes(hex))
        let frame = try XCTUnwrap(try buffer.nextFrame())
        XCTAssertNil(try buffer.nextFrame())
        return frame
    }

    // MARK: Primitives

    func testMD5() {
        XCTAssertEqual(MD5.hex(""), "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(MD5.hex("usernamepassword"), "d51c9a7e9353746a6020f9602d452929")
        XCTAssertEqual(MD5.hex(String(repeating: "a", count: 200)), "887f30b43b2867f4a9accceee7d16e6c")
    }

    func testZlibRoundTrip() throws {
        let original = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0 % 251) })
        let packed = try Zlib.compress(original)
        XCTAssertLessThan(packed.count, original.count)
        XCTAssertEqual(try Zlib.decompress(packed), original)
    }

    func testZlibTruncatedInputThrows() throws {
        let packed = try Zlib.compress(Data(repeating: 7, count: 10_000))
        XCTAssertThrowsError(try Zlib.decompress(packed.prefix(packed.count / 2)))
    }

    func testFrameBufferHandlesByteByByteAndCoalescedInput() throws {
        let stream = bytes(Fixtures.loginFailure) + bytes(Fixtures.getPeerAddress)
        var buffer = FrameBuffer()
        var frames: [Data] = []
        for byte in stream {
            buffer.append(Data([byte]))
            while let frame = try buffer.nextFrame() { frames.append(frame) }
        }
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(buffer.bufferedCount, 0)

        buffer.append(stream)
        XCTAssertNotNil(try buffer.nextFrame())
        XCTAssertNotNil(try buffer.nextFrame())
        XCTAssertNil(try buffer.nextFrame())
    }

    func testTruncatedReadThrows() {
        var reader = ByteReader([UInt8]([0x05, 0x00, 0x00, 0x00, 0x61]))
        XCTAssertThrowsError(try reader.string()) { error in
            XCTAssertEqual(error as? ProtocolError, .truncated)
        }
    }

    // MARK: Server

    func testLoginRequestMatchesNicotine() {
        let frame = ServerRequest.login(
            username: "username", password: "password",
            majorVersion: ServerRequest.majorVersion, minorVersion: ServerRequest.minorVersion).frame
        XCTAssertEqual(frame.hexString, Fixtures.loginRequest)
    }

    func testFileSearchMatchesNicotine() {
        XCTAssertEqual(ServerRequest.fileSearch(token: 1234, query: "aphex twin xtal").frame.hexString,
                       Fixtures.fileSearchRequest)
    }

    func testDecodeLoginReplies() throws {
        XCTAssertEqual(try ServerEvent.decode(body(Fixtures.loginSuccess)),
                       .loginSucceeded(greeting: "Welcome to Soulseek", ownIP: "203.0.113.7"))
        XCTAssertEqual(try ServerEvent.decode(body(Fixtures.loginFailure)),
                       .loginFailed(reason: "INVALIDPASS", detail: nil))
    }

    func testDecodeConnectToPeer() throws {
        XCTAssertEqual(try ServerEvent.decode(body(Fixtures.connectToPeer)),
                       .connectToPeer(username: "peer_user", type: "P", ip: "198.51.100.23", port: 2234, token: 987654))
    }

    func testDecodePeerAddress() throws {
        XCTAssertEqual(try ServerEvent.decode(body(Fixtures.getPeerAddress)),
                       .peerAddress(username: "peer_user", ip: "198.51.100.23", port: 2234))
    }

    // MARK: Peer init

    func testPeerInitFramesMatchNicotine() throws {
        XCTAssertEqual(PeerInitMessage.peerInit(username: "me", type: "P").frame.hexString, Fixtures.peerInit)
        XCTAssertEqual(PeerInitMessage.pierceFirewall(token: 987654).frame.hexString, Fixtures.pierceFirewall)
        XCTAssertEqual(try PeerInitMessage.decode(body(Fixtures.pierceFirewall)), .pierceFirewall(token: 987654))
        XCTAssertEqual(try PeerInitMessage.decode(body(Fixtures.peerInit)), .peerInit(username: "me", type: "P"))
    }

    // MARK: Peer messages

    func testDecodeFileSearchResponseFromNicotine() throws {
        guard case let .fileSearchResponse(response) = try PeerMessage.decode(body(Fixtures.fileSearchResponse)) else {
            return XCTFail("Wrong message")
        }
        XCTAssertEqual(response.username, "peer_user")
        XCTAssertEqual(response.token, 1234)
        XCTAssertTrue(response.slotFree)
        XCTAssertEqual(response.averageSpeed, 5000)
        XCTAssertEqual(response.queueLength, 3)
        XCTAssertEqual(response.files.count, 3)

        let flac = response.files[0]
        XCTAssertEqual(flac.path, "Music\\Aphex Twin\\Selected Ambient Works 85-92\\01 - Xtal.flac")
        XCTAssertEqual(flac.size, 31_457_280)
        XCTAssertEqual(flac.attributes, FileAttributes(duration: 294, sampleRate: 44100, bitDepth: 16))
        XCTAssertEqual(flac.filename, "01 - Xtal.flac")
        XCTAssertEqual(flac.folderName, "Selected Ambient Works 85-92")
        XCTAssertEqual(flac.fileExtension, "flac")

        XCTAssertEqual(response.files[1].attributes, FileAttributes(bitrate: 320, duration: 545, vbr: false))
        XCTAssertEqual(response.files[2].path, "Music\\Ünïcødé\\track é.mp3")
        XCTAssertEqual(response.files[2].attributes, FileAttributes())
    }

    func testTransferRequestDecode() throws {
        guard case let .transferRequest(direction, token, filename, size) =
                try PeerMessage.decode(body(Fixtures.transferRequestUpload)) else {
            return XCTFail("Wrong message")
        }
        XCTAssertEqual(direction, .upload)
        XCTAssertEqual(token, 4242)
        XCTAssertEqual(filename, "Music\\Aphex Twin\\Selected Ambient Works 85-92\\01 - Xtal.flac")
        XCTAssertEqual(size, 31_457_280)

        let encoded = try PeerMessage.transferRequest(direction: .upload, token: 4242, filename: filename, size: size).frame()
        XCTAssertEqual(encoded.hexString, Fixtures.transferRequestUpload)
    }

    func testTransferResponsesMatchNicotine() throws {
        XCTAssertEqual(try PeerMessage.transferResponse(token: 4242, allowed: true, reason: nil, size: nil).frame().hexString,
                       Fixtures.transferResponseAllowed)
        XCTAssertEqual(try PeerMessage.transferResponse(token: 4242, allowed: false, reason: "Queued", size: nil).frame().hexString,
                       Fixtures.transferResponseRejected)

        guard case let .transferResponse(_, allowed, reason, _) =
                try PeerMessage.decode(body(Fixtures.transferResponseRejected)) else {
            return XCTFail("Wrong message")
        }
        XCTAssertFalse(allowed)
        XCTAssertEqual(reason, "Queued")
    }

    func testQueueAndQueueReplies() throws {
        let path = "Music\\Aphex Twin\\Selected Ambient Works 85-92\\02 - Tha.mp3"
        XCTAssertEqual(try PeerMessage.queueUpload(filename: path).frame().hexString, Fixtures.queueUpload)

        guard case let .uploadDenied(deniedPath, reason) = try PeerMessage.decode(body(Fixtures.uploadDenied)) else {
            return XCTFail("Wrong message")
        }
        XCTAssertEqual(deniedPath, path)
        XCTAssertEqual(reason, "File not shared.")

        guard case let .placeInQueueResponse(queuedPath, place) =
                try PeerMessage.decode(body(Fixtures.placeInQueueResponse)) else {
            return XCTFail("Wrong message")
        }
        XCTAssertEqual(queuedPath, path)
        XCTAssertEqual(place, 7)
    }

    func testFolderContentsRequestMatchesNicotine() throws {
        let frame = try PeerMessage.folderContentsRequest(token: 777, folder: "Music\\Aphex Twin\\SAW").frame()
        XCTAssertEqual(frame.hexString, Fixtures.folderContentsRequest)
        guard case let .folderContentsRequest(token, folder) = try PeerMessage.decode(body(Fixtures.folderContentsRequest)) else {
            return XCTFail("Wrong message")
        }
        XCTAssertEqual(token, 777)
        XCTAssertEqual(folder, "Music\\Aphex Twin\\SAW")
    }

    func testDecodeFolderContentsResponse() throws {
        guard case let .folderContentsResponse(token, folder, folders) =
                try PeerMessage.decode(body(Fixtures.folderContentsResponse)) else {
            return XCTFail("Wrong message")
        }
        XCTAssertEqual(token, 777)
        XCTAssertEqual(folder, "Music\\Aphex Twin\\SAW")
        XCTAssertEqual(folders.count, 2)
        XCTAssertEqual(folders[0].files.map(\.path), ["01 - Xtal.flac", "cover.jpg"])
        XCTAssertEqual(folders[0].files[0].attributes, FileAttributes(duration: 294, sampleRate: 44100, bitDepth: 16))
        XCTAssertEqual(folders[1].name, "Music\\Aphex Twin\\SAW\\Scans")

        // Round trip through our encoder.
        let encoded = try PeerMessage.folderContentsResponse(token: token, folder: folder, folders: folders).frame()
        guard case let .folderContentsResponse(_, _, again) = try PeerMessage.decode(body(encoded.hexString)) else {
            return XCTFail("Wrong message")
        }
        XCTAssertEqual(again, folders)
    }

    func testSharedFileListPayloadMatchesProtocolLayout() throws {
        let message = PeerMessage.sharedFileListResponse(folders: [
            SharedFolder(name: "colon3\\Album", files: [SharedFile(path: "song.mp3", size: 5000)]),
        ])
        let frame = try body(try message.frame().hexString)
        var reader = ByteReader(frame)
        XCTAssertEqual(try reader.u32(), 5)
        XCTAssertEqual(try Zlib.decompress(reader.rest()).hexString, Fixtures.sharedFileListPayloadUncompressed)

        guard case let .sharedFileListResponse(folders) = try PeerMessage.decode(frame) else {
            return XCTFail("Wrong message")
        }
        XCTAssertEqual(folders.first?.files.first?.path, "song.mp3")
    }
}
