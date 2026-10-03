import XCTest
import CryptoKit

/// Runs both halves of the v2 handshake in memory, the way `ClientConnection`
/// (client) and `ClientSession` (host) do.
private struct HandshakeFixture {
    let hostIdentity = Curve25519.Signing.PrivateKey()
    let deviceKey = Curve25519.Signing.PrivateKey()
    let clientEphemeral = RDCrypto.makePrivateKey()
    let serverEphemeral = RDCrypto.makePrivateKey()
    let deviceId = "device-1"

    var serverId: String { RDHandshake.serverId(for: hostIdentity.publicKey.rawRepresentation) }

    var serverTranscript: Data {
        RDHandshake.transcriptHash(clientKey: clientEphemeral.publicKey.rawRepresentation,
                                   deviceId: deviceId,
                                   serverKey: serverEphemeral.publicKey.rawRepresentation,
                                   serverIdentity: hostIdentity.publicKey.rawRepresentation,
                                   serverId: serverId)
    }

    var clientTranscript: Data {
        RDHandshake.transcriptHash(clientKey: clientEphemeral.publicKey.rawRepresentation,
                                   deviceId: deviceId,
                                   serverKey: serverEphemeral.publicKey.rawRepresentation,
                                   serverIdentity: hostIdentity.publicKey.rawRepresentation,
                                   serverId: serverId)
    }

    var serverKeys: RDHandshake.SessionKeys {
        RDHandshake.sessionKeys(privateKey: serverEphemeral,
                                peerPublicKey: clientEphemeral.publicKey.rawRepresentation,
                                transcript: serverTranscript)!
    }

    var clientKeys: RDHandshake.SessionKeys {
        RDHandshake.sessionKeys(privateKey: clientEphemeral,
                                peerPublicKey: serverEphemeral.publicKey.rawRepresentation,
                                transcript: clientTranscript)!
    }
}

final class HandshakeTests: XCTestCase {
    func testBothSidesDeriveTheSameDirectionalKeys() throws {
        let fixture = HandshakeFixture()
        var clientSend = RDCipher(key: fixture.clientKeys.clientToServer)
        var serverReceive = RDCipher(key: fixture.serverKeys.clientToServer)
        var serverSend = RDCipher(key: fixture.serverKeys.serverToClient)
        var clientReceive = RDCipher(key: fixture.clientKeys.serverToClient)

        let up = try clientSend.seal(.ping, Data("up".utf8))
        XCTAssertEqual(try serverReceive.open(header: up.prefix(5), body: up.dropFirst(5)), Data("up".utf8))
        let down = try serverSend.seal(.pong, Data("down".utf8))
        XCTAssertEqual(try clientReceive.open(header: down.prefix(5), body: down.dropFirst(5)), Data("down".utf8))
    }

    func testDirectionsUseDifferentKeys() throws {
        let fixture = HandshakeFixture()
        var serverSend = RDCipher(key: fixture.serverKeys.serverToClient)
        // A message reflected back at the host must not open with the host's receive key.
        var serverReceive = RDCipher(key: fixture.serverKeys.clientToServer)
        let frame = try serverSend.seal(.authOK, Data("ok".utf8))
        XCTAssertThrowsError(try serverReceive.open(header: frame.prefix(5), body: frame.dropFirst(5)))
    }

    func testServerSignatureVerifiesOnlyForItsTranscript() {
        let fixture = HandshakeFixture()
        let identity = fixture.hostIdentity.publicKey.rawRepresentation
        let signature = try! fixture.hostIdentity.signature(for: RDHandshake.serverProof(transcript: fixture.serverTranscript))
        XCTAssertTrue(RDHandshake.isValidSignature(signature, publicKey: identity,
                                                   message: RDHandshake.serverProof(transcript: fixture.clientTranscript)))

        // Replaying that signature in a handshake with different ephemeral keys fails.
        let other = HandshakeFixture()
        let otherTranscript = RDHandshake.transcriptHash(clientKey: other.clientEphemeral.publicKey.rawRepresentation,
                                                         deviceId: fixture.deviceId,
                                                         serverKey: other.serverEphemeral.publicKey.rawRepresentation,
                                                         serverIdentity: identity,
                                                         serverId: fixture.serverId)
        XCTAssertFalse(RDHandshake.isValidSignature(signature, publicKey: identity,
                                                    message: RDHandshake.serverProof(transcript: otherTranscript)))
    }

    func testDeviceProofCannotBeReplayedToAnotherHandshake() {
        let fixture = HandshakeFixture()
        let devicePublic = fixture.deviceKey.publicKey.rawRepresentation
        let proof = try! fixture.deviceKey.signature(for: RDHandshake.deviceProof(transcript: fixture.clientTranscript))
        XCTAssertTrue(RDHandshake.isValidSignature(proof, publicKey: devicePublic,
                                                   message: RDHandshake.deviceProof(transcript: fixture.serverTranscript)))

        // What an impostor host collects can't be used in its own session with the real host.
        let relay = HandshakeFixture()
        XCTAssertFalse(RDHandshake.isValidSignature(proof, publicKey: devicePublic,
                                                    message: RDHandshake.deviceProof(transcript: relay.serverTranscript)))
        // And a device proof is not a server proof (domain separation).
        XCTAssertFalse(RDHandshake.isValidSignature(proof, publicKey: devicePublic,
                                                    message: RDHandshake.serverProof(transcript: fixture.serverTranscript)))
    }

    func testServerIdIsBoundToIdentityKey() {
        let a = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let b = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        XCTAssertEqual(RDHandshake.serverId(for: a), RDHandshake.serverId(for: a))
        XCTAssertNotEqual(RDHandshake.serverId(for: a), RDHandshake.serverId(for: b))
        XCTAssertEqual(RDHandshake.serverId(for: a).count, 32)
        XCTAssertEqual(RDHandshake.fingerprint(of: a).count, 19) // "XXXX XXXX XXXX XXXX"
    }

    func testTranscriptFieldsAreLengthPrefixed() {
        // Moving bytes between adjacent fields must change the transcript.
        let one = RDHandshake.transcriptHash(clientKey: Data([1, 2]), deviceId: "ab", serverKey: Data([3]),
                                             serverIdentity: Data([4]), serverId: "x")
        let two = RDHandshake.transcriptHash(clientKey: Data([1]), deviceId: "\u{2}ab", serverKey: Data([3]),
                                             serverIdentity: Data([4]), serverId: "x")
        XCTAssertNotEqual(one, two)
    }
}

final class CipherTests: XCTestCase {
    private let key = SymmetricKey(size: .bits256)

    func testRoundTripAndFrameLayout() throws {
        var sender = RDCipher(key: key)
        var receiver = RDCipher(key: key)
        let frame = try sender.seal(.textEvent, Data("hello".utf8))
        XCTAssertEqual(frame.count, RDFrame.headerLength + 5 + RDCipher.tagLength)
        XCTAssertEqual(RDFrame.unpackHeader(frame)?.wire, .textEvent)
        XCTAssertEqual(RDFrame.unpackHeader(frame)?.length, 5 + RDCipher.tagLength)
        XCTAssertEqual(try receiver.open(header: frame.prefix(5), body: frame.dropFirst(5)), Data("hello".utf8))
    }

    func testReplayIsRejected() throws {
        var sender = RDCipher(key: key)
        var receiver = RDCipher(key: key)
        let frame = try sender.seal(.mouseDown, Data("{}".utf8))
        _ = try receiver.open(header: frame.prefix(5), body: frame.dropFirst(5))
        XCTAssertThrowsError(try receiver.open(header: frame.prefix(5), body: frame.dropFirst(5)))
    }

    func testReorderIsRejected() throws {
        var sender = RDCipher(key: key)
        var receiver = RDCipher(key: key)
        _ = try sender.seal(.mouseDown, Data("1".utf8))
        let second = try sender.seal(.mouseUp, Data("2".utf8))
        XCTAssertThrowsError(try receiver.open(header: second.prefix(5), body: second.dropFirst(5)))
    }

    func testRetypedHeaderIsRejected() throws {
        var sender = RDCipher(key: key)
        var receiver = RDCipher(key: key)
        var frame = try sender.seal(.mouseDown, Data("{\"button\":0}".utf8))
        frame[4] = RDWire.mouseUp.rawValue
        XCTAssertThrowsError(try receiver.open(header: frame.prefix(5), body: frame.dropFirst(5)))
    }

    func testTamperedCiphertextIsRejected() throws {
        var sender = RDCipher(key: key)
        var receiver = RDCipher(key: key)
        var frame = try sender.seal(.textEvent, Data("secret".utf8))
        frame[6] ^= 0x01
        XCTAssertThrowsError(try receiver.open(header: frame.prefix(5), body: frame.dropFirst(5)))
    }
}

final class FramingTests: XCTestCase {
    func testReaderHandlesArbitraryChunking() throws {
        let stream = RDFrame.pack(.hello, payload: Data("abc".utf8))
            + RDFrame.pack(.ping, payload: Data())
            + RDFrame.pack(.textEvent, payload: Data(repeating: 7, count: 300))
        var reader = RDFrameReader()
        var frames: [RDFrameData] = []
        for byte in stream {
            reader.append(Data([byte]))
            while let frame = try reader.nextFrame() {
                frames.append(frame)
            }
        }
        XCTAssertEqual(frames.map(\.wire), [.hello, .ping, .textEvent])
        XCTAssertEqual(frames[0].body, Data("abc".utf8))
        XCTAssertEqual(frames[1].body, Data())
        XCTAssertEqual(frames[2].body.count, 300)
    }

    func testOversizedFrameIsRejectedBeforeBuffering() {
        var reader = RDFrameReader()
        reader.maxPayload = RDService.maxHandshakePayload
        var header = Data()
        header.appendBE32(UInt32(RDService.maxHandshakePayload + 1))
        header.append(RDWire.hello.rawValue)
        reader.append(header)
        XCTAssertThrowsError(try reader.nextFrame())
    }

    func testLimitCanBeRaisedBetweenFramesOfOneChunk() throws {
        // authOK followed, in the same TCP chunk, by a message larger than the handshake limit.
        let big = Data(repeating: 1, count: RDService.maxHandshakePayload * 4)
        var reader = RDFrameReader()
        reader.maxPayload = RDService.maxHandshakePayload
        reader.append(RDFrame.pack(.authOK, payload: Data("{}".utf8)) + RDFrame.pack(.runningApps, payload: big))
        XCTAssertEqual(try reader.nextFrame()?.wire, .authOK)
        reader.maxPayload = RDService.maxPayload
        XCTAssertEqual(try reader.nextFrame()?.body.count, big.count)
        XCTAssertNil(try reader.nextFrame())
    }

    func testUnknownMessageTypeIsSkippedNotFatal() throws {
        var unknown = Data()
        unknown.appendBE32(2)
        unknown.append(0xEE)
        unknown.append(contentsOf: [1, 2])
        var reader = RDFrameReader()
        reader.append(unknown + RDFrame.pack(.ping, payload: Data()))
        let first = try reader.nextFrame()
        XCTAssertNotNil(first)
        XCTAssertNil(first?.wire)
        XCTAssertEqual(try reader.nextFrame()?.wire, .ping)
        XCTAssertNil(try reader.nextFrame())
    }

    func testVideoPayloadRoundTripsFromSlices() {
        let packed = RDFrameCodec.pack(width: 3456, height: 2234, codec: .hevc, data: Data([0, 0, 0, 1, 0x40]))
        // Unpacking a slice (non-zero startIndex) must still work.
        let slice = (Data([9, 9]) + packed).dropFirst(2)
        let unpacked = RDFrameCodec.unpack(slice)
        XCTAssertEqual(unpacked?.width, 3456)
        XCTAssertEqual(unpacked?.height, 2234)
        XCTAssertEqual(unpacked?.codec, .hevc)
        XCTAssertEqual(unpacked?.data, Data([0, 0, 0, 1, 0x40]))
    }

    func testCodecDecodingRejectsOutOfRangeValues() {
        XCTAssertEqual(RDCodec.from(2), .hevc)
        XCTAssertEqual(RDCodec.from(1), .h264)
        XCTAssertNil(RDCodec.from(0))
        XCTAssertNil(RDCodec.from(256))
        XCTAssertNil(RDCodec.from(-1))
        XCTAssertNil(RDCodec.from(nil))
    }
}

final class PINSecurityTests: XCTestCase {
    func testFormat() {
        XCTAssertTrue(PINHasher.isValidFormat("0429"))
        XCTAssertFalse(PINHasher.isValidFormat("042"))
        XCTAssertFalse(PINHasher.isValidFormat("04290"))
        XCTAssertFalse(PINHasher.isValidFormat("04a9"))
        XCTAssertFalse(PINHasher.isValidFormat("٠٤٢٩")) // Arabic-Indic digits
        XCTAssertFalse(PINHasher.isValidFormat(String(repeating: "1", count: 1_000_000)))
    }

    func testStandardPBKDF2Vector() {
        // RFC 6070-style vector for PBKDF2-HMAC-SHA256, P="password", S="salt", c=1.
        let derived = PINHasher.hash("password", salt: Data("salt".utf8), rounds: 1)
        XCTAssertEqual(derived.map { String(format: "%02x", $0) }.joined(),
                       "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
    }

    func testLegacyHashMatchesV1Implementation() {
        let salt = Data((0..<16).map { UInt8($0) })
        XCTAssertEqual(PINHasher.legacyHash("1234", salt: salt), Self.v1PBKDF2(pin: "1234", salt: salt))
        XCTAssertNotEqual(PINHasher.legacyHash("1234", salt: salt), PINHasher.hash("1234", salt: salt, rounds: 60_000))
    }

    func testLockoutEscalatesAfterFreeAttempts() {
        var lockout = PINLockout()
        let start = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<(PINLockout.freeAttempts - 1) {
            lockout.recordFailure(now: start.addingTimeInterval(Double(i)))
            XCTAssertNil(lockout.retryAfter(now: start.addingTimeInterval(Double(i))))
        }
        let fifth = start.addingTimeInterval(10)
        lockout.recordFailure(now: fifth)
        XCTAssertEqual(lockout.retryAfter(now: fifth) ?? 0, PINLockout.baseDelay, accuracy: 0.001)

        let sixth = fifth.addingTimeInterval(PINLockout.baseDelay + 1)
        XCTAssertNil(lockout.retryAfter(now: sixth))
        lockout.recordFailure(now: sixth)
        XCTAssertEqual(lockout.retryAfter(now: sixth) ?? 0, PINLockout.baseDelay * 2, accuracy: 0.001)

        for _ in 0..<20 {
            lockout.recordFailure(now: sixth)
        }
        XCTAssertEqual(lockout.retryAfter(now: sixth) ?? 0, PINLockout.maxDelay, accuracy: 0.001)
    }

    func testBruteForcingTheWholePINSpaceTakesYears() {
        var lockout = PINLockout()
        var now = Date(timeIntervalSince1970: 0)
        for _ in 0..<10_000 {
            if let wait = lockout.retryAfter(now: now) {
                now = now.addingTimeInterval(wait)
            }
            lockout.recordFailure(now: now)
        }
        XCTAssertGreaterThan(now.timeIntervalSince1970, 365 * 24 * 3600)
    }

    func testSuccessAndTimeResetTheCounter() {
        var lockout = PINLockout()
        let now = Date()
        for _ in 0..<PINLockout.freeAttempts {
            lockout.recordFailure(now: now)
        }
        XCTAssertNotNil(lockout.retryAfter(now: now))
        lockout.recordSuccess()
        XCTAssertNil(lockout.retryAfter(now: now))
        XCTAssertEqual(lockout.failures, 0)

        for _ in 0..<(PINLockout.freeAttempts - 1) {
            lockout.recordFailure(now: now)
        }
        lockout.recordFailure(now: now.addingTimeInterval(PINLockout.forgetAfter + 1))
        XCTAssertEqual(lockout.failures, 1)
    }

    /// Verbatim copy of the v1 `RDCrypto.pbkdf2`, kept to prove the migration path.
    private static func v1PBKDF2(pin: String, salt: Data, rounds: UInt32 = 60_000, length: Int = 32) -> Data {
        let password = Array(pin.utf8)
        let hmacKey = SymmetricKey(data: Data(password))
        var derived = Data()
        var blockIndex: UInt32 = 1
        while derived.count < length {
            var u = HMAC<SHA256>.authenticationCode(
                for: Data(password + salt + [UInt8((blockIndex >> 24) & 0xFF), UInt8((blockIndex >> 16) & 0xFF),
                                             UInt8((blockIndex >> 8) & 0xFF), UInt8(blockIndex & 0xFF)]),
                using: hmacKey)
            var t = Data(u)
            if rounds > 1 {
                for _ in 1..<rounds {
                    u = HMAC<SHA256>.authenticationCode(for: Data(u), using: hmacKey)
                    let uBytes = Data(u)
                    for i in 0..<t.count {
                        t[t.startIndex + i] ^= uBytes[uBytes.startIndex + i]
                    }
                }
            }
            derived.append(t)
            blockIndex += 1
        }
        return derived.prefix(length)
    }
}
