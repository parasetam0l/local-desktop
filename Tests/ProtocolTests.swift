import XCTest
import CryptoKit
import CoreMedia
import CoreVideo

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

final class DisplayMessageTests: XCTestCase {
    func testDisplaysRoundTripWithTheDocumentedKeys() throws {
        let message = RDDisplaysMsg(
            displays: [RDDisplay(id: 1, name: "Built-in Retina Display", width: 1728, height: 1117, isMain: true),
                       RDDisplay(id: 4_278_190_082, name: "LG UltraFine", width: 2560, height: 1440, isMain: false)],
            selectedId: 4_278_190_082)
        let data = RDJSON.encode(message)
        XCTAssertEqual(RDJSON.decode(RDDisplaysMsg.self, from: data), message)

        // Protocol.md documents these field names; older or newer peers rely on them.
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["displays", "selectedId"])
        let first = try XCTUnwrap((json["displays"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(first.keys), ["id", "name", "width", "height", "isMain"])
        XCTAssertEqual(message.displays[0].resolution, "1728×1117")
    }

    func testSizedMirrorFieldsAreOptionalAndRoundTrip() throws {
        // A Mac before 1.2.12 sends neither field.
        let old = try XCTUnwrap(RDJSON.decode(RDDisplaysMsg.self, from: Data(#"{"displays":[],"selectedId":1}"#.utf8)))
        XCTAssertNil(old.sizedMirrorAvailable)
        XCTAssertNil(old.mirrorSize)

        let size = RDMirrorSize(width: 1112, height: 834)
        let message = RDDisplaysMsg(displays: [], selectedId: 7, sizedMirrorAvailable: true, mirrorSize: size)
        XCTAssertEqual(RDJSON.decode(RDDisplaysMsg.self, from: RDJSON.encode(message)), message)
        XCTAssertEqual(size.label, "1112×834")

        let on = RDJSON.decode(RDSetSizedMirrorMsg.self, from: Data(#"{"size":{"width":1024,"height":768}}"#.utf8))
        XCTAssertEqual(on?.size, RDMirrorSize(width: 1024, height: 768))
        // Off is a message without a size.
        let off = try XCTUnwrap(RDJSON.decode(RDSetSizedMirrorMsg.self, from: RDJSON.encode(RDSetSizedMirrorMsg(size: nil))))
        XCTAssertNil(off.size)

        let oldAuth = try XCTUnwrap(RDJSON.decode(AuthOKMsg.self, from: Data(#"{"serverName":"Mac","trusted":true}"#.utf8)))
        XCTAssertNil(oldAuth.sizedMirrorAvailable)
        let newAuth = AuthOKMsg(serverName: "Mac", trusted: true, macAddress: nil, supportsVideoStream: true, sizedMirrorAvailable: true)
        XCTAssertEqual(RDJSON.decode(AuthOKMsg.self, from: RDJSON.encode(newAuth))?.sizedMirrorAvailable, true)
    }

    func testDesktopSizeFillsThePictureAreaEitherWayUp() {
        // An iPad 11" without its safe areas: the same proportions at any scale, and
        // transposed when it is held upright.
        XCTAssertEqual(RDMirrorSize.filling(CGSize(width: 1180, height: 776), percent: 100),
                       RDMirrorSize(width: 1180, height: 776))
        XCTAssertEqual(RDMirrorSize.filling(CGSize(width: 1180, height: 776), percent: 125),
                       RDMirrorSize(width: 1475, height: 970))
        XCTAssertEqual(RDMirrorSize.filling(CGSize(width: 820, height: 1136), percent: 100),
                       RDMirrorSize(width: 820, height: 1136))
        // An iPhone: one and a half times its 734×372 landscape area.
        XCTAssertEqual(RDMirrorSize.filling(CGSize(width: 734, height: 372), percent: 150),
                       RDMirrorSize(width: 1101, height: 558))
        // Too small for macOS to draw sharply: scaled up until the shorter side fits.
        let small = RDMirrorSize.filling(CGSize(width: 393, height: 759), percent: 100)
        XCTAssertEqual(small, RDMirrorSize(width: 540, height: 1043))
        // Too large: scaled down until the longer side fits.
        let large = RDMirrorSize.filling(CGSize(width: 1376, height: 988), percent: 300)
        XCTAssertEqual(large, RDMirrorSize(width: 2732, height: 1962))
        XCTAssertNil(RDMirrorSize.filling(.zero, percent: 100))
    }

    func testStandardDesktopSizeTurnsWithTheDevice() {
        let size = RDMirrorSize(width: 1024, height: 768)
        XCTAssertEqual(size.oriented(like: CGSize(width: 1180, height: 776)), size)
        XCTAssertEqual(size.oriented(like: CGSize(width: 820, height: 1136)), RDMirrorSize(width: 768, height: 1024))
        XCTAssertEqual(RDMirrorSize(width: 768, height: 1024).oriented(like: CGSize(width: 1180, height: 776)), size)
    }

    func testSelectionIsOptional() {
        let data = Data(#"{"displays":[]}"#.utf8)
        XCTAssertEqual(RDJSON.decode(RDDisplaysMsg.self, from: data), RDDisplaysMsg(displays: [], selectedId: nil))
        XCTAssertEqual(RDJSON.decode(RDSelectDisplayMsg.self, from: Data(#"{"id":2}"#.utf8))?.id, 2)
    }
}

final class ClipboardMessageTests: XCTestCase {
    func testClipboardMessagesRoundTripWithTheDocumentedKeys() throws {
        let sharing = RDJSON.encode(RDSetClipboardSharingMsg(enabled: true))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: sharing) as? [String: Bool], ["enabled": true])
        XCTAssertEqual(RDJSON.decode(RDSetClipboardSharingMsg.self, from: sharing)?.enabled, true)

        let text = "Grüße \"quoted\"\nline two 🙂"
        let payload = try XCTUnwrap(RDClipboardMsg.payload(for: text))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: payload) as? [String: String], ["text": text])
        XCTAssertEqual(RDJSON.decode(RDClipboardMsg.self, from: payload)?.text, text)

        let frame = RDFrame.pack(.clipboard, payload: payload)
        var reader = RDFrameReader()
        reader.append(frame)
        let read = try XCTUnwrap(try reader.nextFrame())
        XCTAssertEqual(read.wire, .clipboard)
        XCTAssertEqual(read.body, payload)
    }

    func testClipboardPayloadSkipsEmptyAndOversizedText() {
        XCTAssertNil(RDClipboardMsg.payload(for: ""))
        XCTAssertNil(RDClipboardMsg.payload(for: String(repeating: "a", count: RDClipboardMsg.maxPayload + 1)))
        // Fits as UTF-8 but not once JSON escapes it.
        XCTAssertNil(RDClipboardMsg.payload(for: String(repeating: "\"", count: RDClipboardMsg.maxPayload / 2 + 1)))
        let large = String(repeating: "a", count: RDClipboardMsg.maxPayload - 100)
        XCTAssertNotNil(RDClipboardMsg.payload(for: large))
    }

    func testClipboardImageRoundTripsInPieces() throws {
        var png = Data([0x89, 0x50, 0x4E, 0x47])
        png += Data((0..<(RDClipboardImage.chunkSize * 2 + 1000)).map { UInt8(truncatingIfNeeded: $0) })
        XCTAssertTrue(RDClipboardImage.isPNG(png))
        XCTAssertFalse(RDClipboardImage.isPNG(Data([0xFF, 0xD8, 0xFF, 0xE0])))
        let chunks = try XCTUnwrap(RDClipboardImage.chunks(of: png, id: 7))
        XCTAssertEqual(chunks.count, 3)
        // Each piece fits the host's limit on client messages.
        XCTAssertTrue(chunks.allSatisfy { $0.count <= RDClipboardMsg.maxPayload })

        var assembler = RDClipboardImageAssembler()
        XCTAssertNil(assembler.add(chunks[0]))
        XCTAssertNil(assembler.add(chunks[1]))
        XCTAssertEqual(assembler.add(chunks[2]), png)

        // A missing piece drops the image; the next image still comes through.
        XCTAssertNil(assembler.add(chunks[0]))
        XCTAssertNil(assembler.add(chunks[2]))
        let small = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let single = try XCTUnwrap(RDClipboardImage.chunks(of: small, id: 8))
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(assembler.add(single[0]), small)

        // A piece of another image in the middle drops both.
        XCTAssertNil(assembler.add(chunks[0]))
        XCTAssertNil(assembler.add(try XCTUnwrap(RDClipboardImage.chunks(of: png, id: 9))[1]))
        XCTAssertNil(assembler.add(chunks[1]))
        XCTAssertNil(assembler.add(Data([1, 2])))
    }

    func testClipboardImageSkipsEmptyAndOversizedImages() {
        XCTAssertNil(RDClipboardImage.chunks(of: Data(), id: 1))
        XCTAssertNil(RDClipboardImage.chunks(of: Data(count: RDClipboardImage.maxSize + 1), id: 1))
        XCTAssertEqual(RDClipboardImage.chunks(of: Data(count: RDClipboardImage.maxSize), id: 1)?.count,
                       RDClipboardImage.maxSize / RDClipboardImage.chunkSize)
    }

    func testUnknownMessageTypeIsReadAndLeftForTheCallerToIgnore() throws {
        // How an older peer sees a newer message: the frame is consumed with no wire type.
        var stream = RDFrame.header(.clipboard, length: 3) + Data("abc".utf8)
        stream[stream.startIndex + 4] = 0xEE
        stream += RDFrame.pack(.ping, payload: Data())
        var reader = RDFrameReader()
        reader.append(stream)
        XCTAssertNil(try XCTUnwrap(try reader.nextFrame()).wire)
        XCTAssertEqual(try XCTUnwrap(try reader.nextFrame()).wire, .ping)
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

final class TransportAndMediaUpgradeTests: XCTestCase {
    func testFrameCodecPackAVCCAndUnpackPacketSlice() {
        let vps = Data([0x40, 0x01, 0x0C])
        let sps = Data([0x42, 0x01, 0x01, 0x01])
        let pps = Data([0x44, 0x01, 0xC0])
        let avccBody = Data([0x00, 0x00, 0x00, 0x04, 0x26, 0x01, 0xAF, 0x00])

        let avccPayload = RDFrameCodec.packAVCC(width: 1920,
                                                height: 1080,
                                                codec: .hevc,
                                                parameterSets: [vps, sps, pps],
                                                data: avccBody)
        // Put inside a larger Data slice to verify non-zero startIndex handling.
        let prefixed = Data([0xFF, 0xEE]) + avccPayload
        let slice = prefixed.dropFirst(2)
        let unpacked = RDFrameCodec.unpackPacket(slice)
        XCTAssertEqual(unpacked?.width, 1920)
        XCTAssertEqual(unpacked?.height, 1080)
        XCTAssertEqual(unpacked?.codec, .hevc)
        XCTAssertEqual(unpacked?.isAVCC, true)
        XCTAssertEqual(unpacked.map { Data($0.data) }, avccPayload.dropFirst(RDFrameCodec.headerLength))

        let annexBPayload = RDFrameCodec.pack(width: 1280, height: 720, codec: .h264, data: Data([0, 0, 0, 1, 0x65]))
        let unpackedAnnexB = RDFrameCodec.unpackPacket(annexBPayload)
        XCTAssertEqual(unpackedAnnexB?.width, 1280)
        XCTAssertEqual(unpackedAnnexB?.height, 720)
        XCTAssertEqual(unpackedAnnexB?.codec, .h264)
        XCTAssertEqual(unpackedAnnexB?.isAVCC, false)
    }

    func testHandshakeTLSBindingRejectsMismatchedCertHashAndDerivesVideoStreamKey() throws {
        let hostIdentity = Curve25519.Signing.PrivateKey()
        let clientEphemeral = RDCrypto.makePrivateKey()
        let certHash = RDCrypto.sha256(Data("real-cert".utf8))
        let hello = HelloMsg(deviceId: "dev-1",
                             deviceName: "iPad",
                             pubKey: clientEphemeral.publicKey.rawRepresentation,
                             avcc: true,
                             quicTLSBound: true)
        let serverId = RDHandshake.serverId(for: hostIdentity.publicKey.rawRepresentation)
        let response = try XCTUnwrap(RDHandshake.respond(to: hello,
                                                         identityKey: hostIdentity.publicKey.rawRepresentation,
                                                         serverId: serverId,
                                                         serverName: "Mac",
                                                         tlsCertHash: certHash) {
            try? hostIdentity.signature(for: $0)
        })
        XCTAssertEqual(response.serverHello.quicTLSBound, true)

        let matchingTranscript = RDHandshake.transcriptHash(clientKey: clientEphemeral.publicKey.rawRepresentation,
                                                            deviceId: hello.deviceId,
                                                            serverKey: response.serverHello.pubKey,
                                                            serverIdentity: response.serverHello.identityKey,
                                                            serverId: response.serverHello.serverId,
                                                            tlsCertHash: certHash)
        XCTAssertTrue(RDHandshake.isValidSignature(response.serverHello.signature,
                                                 publicKey: response.serverHello.identityKey,
                                                 message: RDHandshake.serverProof(transcript: matchingTranscript)))
        let clientKeys = try XCTUnwrap(RDHandshake.sessionKeys(privateKey: clientEphemeral,
                                                               peerPublicKey: response.serverHello.pubKey,
                                                               transcript: matchingTranscript))
        var hostVideoStream = RDCipher(key: response.keys.videoStream)
        var clientVideoStream = RDCipher(key: clientKeys.videoStream)
        let sealed = try clientVideoStream.seal(.videoStreamAttach, RDJSON.encode(VideoStreamAttachMsg()))
        let plain = try hostVideoStream.open(header: sealed.prefix(5), body: sealed.dropFirst(5))
        XCTAssertEqual(RDJSON.decode(VideoStreamAttachMsg.self, from: plain)?.version, 1)

        // Mismatched certificate hash (e.g. active TLS proxy) must fail verification.
        let wrongTranscript = RDHandshake.transcriptHash(clientKey: clientEphemeral.publicKey.rawRepresentation,
                                                         deviceId: hello.deviceId,
                                                         serverKey: response.serverHello.pubKey,
                                                         serverIdentity: response.serverHello.identityKey,
                                                         serverId: response.serverHello.serverId,
                                                         tlsCertHash: RDCrypto.sha256(Data("mitm-cert".utf8)))
        XCTAssertFalse(RDHandshake.isValidSignature(response.serverHello.signature,
                                                  publicKey: response.serverHello.identityKey,
                                                  message: RDHandshake.serverProof(transcript: wrongTranscript)))
    }

    func testFrameReaderSliceDecryptionAndZeroCopyConcatenation() throws {
        let key = SymmetricKey(size: .bits256)
        var sender = RDCipher(key: key)
        var receiver = RDCipher(key: key)
        let f1 = try sender.seal(.ping, Data("one".utf8))
        let f2 = try sender.seal(.pong, Data("two-longer".utf8))
        let f3 = try sender.seal(.ping, Data("three-split".utf8))

        var reader = RDFrameReader()
        reader.append(f1 + f2 + f3.prefix(3))
        let first = try XCTUnwrap(try reader.nextFrame())
        XCTAssertEqual(try receiver.open(header: first.header, body: first.body), Data("one".utf8))

        let second = try XCTUnwrap(try reader.nextFrame())
        XCTAssertGreaterThan(second.header.startIndex, 0)
        XCTAssertEqual(try receiver.open(header: second.header, body: second.body), Data("two-longer".utf8))
        XCTAssertNil(try reader.nextFrame())

        reader.append(f3.dropFirst(3))
        let third = try XCTUnwrap(try reader.nextFrame())
        XCTAssertEqual(try receiver.open(header: third.header, body: third.body), Data("three-split".utf8))
    }

    func testEncodedVideoPacketAndHardwareDecodeAVCCAndAnnexB() throws {
        let encoder = HardwareVideoEncoder()
        var captured: EncodedVideoPacket?
        let done = expectation(description: "encoded keyframe")
        encoder.onPacket = { packet in
            if captured == nil {
                captured = packet
                done.fulfill()
            }
        }
        encoder.setup(width: 64, height: 64, fps: 30, bitrate: 1_000_000, codec: .h264)
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         64,
                                         64,
                                         kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                         nil,
                                         &pixelBuffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        if let pixelBuffer {
            encoder.encode(pixelBuffer: pixelBuffer, pts: CMTime(value: 0, timescale: 30), forceKeyframe: true)
            wait(for: [done], timeout: 5)
        }
        encoder.teardown()

        let packet = try XCTUnwrap(captured)
        XCTAssertFalse(packet.parameterSets.isEmpty)
        XCTAssertFalse(packet.avccData.isEmpty)

        // Verify AVCC pack + VideoDecoder AVCC fast path (with non-zero Data slice startIndex)
        let avccWire = packet.packAVCC()
        let unpackedAVCC = try XCTUnwrap(RDFrameCodec.unpackPacket(avccWire))
        XCTAssertTrue(unpackedAVCC.isAVCC)

        let decoderAVCC = VideoDecoder()
        var avccSamples = 0
        decoderAVCC.decode(data: unpackedAVCC.data, isAVCC: true, codec: .h264) { sample in
            XCTAssertTrue(CMSampleBufferIsValid(sample))
            avccSamples += 1
        }
        XCTAssertEqual(avccSamples, 1)

        // Verify Annex-B conversion + VideoDecoder Annex-B path (with non-zero Data slice startIndex)
        let annexBWire = packet.packAnnexB()
        let unpackedAnnexB = try XCTUnwrap(RDFrameCodec.unpackPacket(annexBWire))
        XCTAssertFalse(unpackedAnnexB.isAVCC)

        let decoderAnnexB = VideoDecoder()
        var annexBSamples = 0
        decoderAnnexB.decode(data: unpackedAnnexB.data, isAVCC: false, codec: .h264) { sample in
            XCTAssertTrue(CMSampleBufferIsValid(sample))
            annexBSamples += 1
        }
        XCTAssertEqual(annexBSamples, 1)
    }

    func testCrashRecoveryPolicyCircuitBreakerAndAwakeHangCheck() {
        var history: [TimeInterval] = []
        let t0: TimeInterval = 1_000
        for i in 0..<CrashRecoveryPolicy.maxCrashesInWindow {
            let eval = CrashRecoveryPolicy.evaluateRestart(history: history, now: t0 + Double(i) * 5)
            XCTAssertTrue(eval.allowed)
            history = eval.updated
        }
        // 6th crash inside the 60 s window trips the circuit breaker.
        let blocked = CrashRecoveryPolicy.evaluateRestart(history: history, now: t0 + 30)
        XCTAssertFalse(blocked.allowed)

        // After the window expires, crashes age out and relaunching is permitted again.
        let recovered = CrashRecoveryPolicy.evaluateRestart(history: history,
                                                            now: t0 + CrashRecoveryPolicy.crashWindowSeconds + 30)
        XCTAssertTrue(recovered.allowed)
        XCTAssertEqual(recovered.updated.count, 1)

        // Sleep pauses CLOCK_UPTIME_RAW, so awake uptime delta governs hang detection.
        XCTAssertFalse(CrashRecoveryPolicy.isHung(lastHeartbeatUptimeNs: 10_000_000_000,
                                                currentUptimeNs: 44_999_999_999))
        XCTAssertTrue(CrashRecoveryPolicy.isHung(lastHeartbeatUptimeNs: 10_000_000_000,
                                               currentUptimeNs: 10_000_000_000 + CrashRecoveryPolicy.hangTimeoutNanoseconds))
    }
}
