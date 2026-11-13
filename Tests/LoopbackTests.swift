import XCTest
import Network
import CryptoKit

/// A minimal host speaking protocol v2 over a real localhost socket. It reuses the
/// production handshake (`RDHandshake.respond`) and cipher; only the session
/// bookkeeping of the real `ClientSession` (host) is left out.
private final class LoopbackHost: @unchecked Sendable {
    let identity = Curve25519.Signing.PrivateKey()
    let queue = DispatchQueue(label: "test.host")
    let pin = "1234"
    /// Corrupts the serverHello signature, as an impostor without the key would.
    var forgeSignature = false
    /// Answers `hello` with a plaintext `authFailed` of this kind instead of a serverHello.
    var refuseBeforeHandshake: RDAuthFailure?
    /// Every message type received, including ones it can't decrypt.
    private let receivedLock = NSLock()
    private var _received: [RDWire] = []
    var received: [RDWire] {
        receivedLock.lock()
        defer { receivedLock.unlock() }
        return _received
    }
    /// Sent right after authOK, in the same write, to exercise the size limit switch.
    let largeMessage = Data(repeating: 0x41, count: RDService.maxHandshakePayload * 4)
    /// Device keys registered through PIN pairing.
    private(set) var trustedDeviceKey: Data?

    private var listener: NWListener!
    private var connection: NWConnection?
    /// QUIC mode: the connection's group, its datagram flow, and the video key.
    private var group: NWConnectionGroup?
    private var quicAcceptor: QUICAcceptor?
    private var datagramFlow: NWConnection?
    private var videoKey: SymmetricKey?
    private var framesSent: UInt32 = 0
    /// Answers `videoDatagrams` by sending `datagramFrames` as datagrams, in this order.
    var sendDatagramVideo = false
    /// Enable QUIC TLS channel binding (`quicTLSBound`) during `hello`/`serverHello`.
    var enableTLSBinding = false
    /// When set alongside `enableTLSBinding`, injects a wrong leaf cert hash into handshake proof.
    var forgeTLSCertHash = false
    /// Enable dedicated 2nd QUIC video stream (`authOK.supportsVideoStream`) and deliver frames on it.
    var useDedicatedVideoStream = false
    /// After receiving `videoStreamAttach`, automatically send frame 2 on dedicated stream
    /// (and optionally frame 3 back on control stream if `switchBackAfterDedicatedFrame` is true).
    var dedicatedStreamFrame: Data?
    var switchBackFrame: Data?
    /// Enable XOR parity FEC on datagram sends, and optionally drop piece 0 of each frame.
    var enableDatagramFEC = false
    var dropFirstDatagramDataPiece = false
    /// (number, payload, keyframe); pieces of each frame are sent in reverse order.
    var datagramFrames: [(UInt32, Data, Bool)] = []
    /// Optional delay before sending `datagramFrames` (lets `videoStreamAttach` complete first).
    var datagramSendDelay: TimeInterval = 0
    /// After the datagram frames: `videoStream {nextFrame}` and this frame on the stream,
    /// optionally resuming onto the dedicated video stream while injecting a late stale datagram.
    var resumeStreamFrame: (UInt32, Data)?
    var resumeOnDedicatedVideoStream = false
    var sendLateDatagramAfterResume: (UInt32, Data)?
    /// What the client's `videoDatagrams` said.
    var offeredCanResume: Bool?
    var offeredFEC: Bool?
    var offeredUnsealed: Bool?
    /// Whether `videoStreamAttach` arrived on a 2nd QUIC stream and was verified.
    private(set) var receivedVideoStreamAttach = false
    /// The last `frameAck` number.
    var lastFrameAck: UInt32 = 0
    private var reader = RDFrameReader()
    private var sendCipher: RDCipher?
    private var receiveCipher: RDCipher?
    private var tlsCertHash: Data?
    private var quicTLSBound = false
    private var videoStream: NWConnection?
    private var videoStreamReader = RDFrameReader()
    private var videoStreamSendCipher: RDCipher?
    private var videoStreamReceiveCipher: RDCipher?
    private var transcript = Data()
    private var deviceId = ""

    var serverId: String { RDHandshake.serverId(for: identity.publicKey.rawRepresentation) }

    /// Listens on TCP, or with `quic` on one QUIC stream per connection, presenting a
    /// fresh self-signed certificate the way the real host does.
    func start(quic: Bool = false) throws -> UInt16 {
        if quic {
            let key = P256.Signing.PrivateKey()
            let certificate = try RDSelfSignedIdentity.makeCertificate(for: key)
            let identity = try XCTUnwrap(RDSelfSignedIdentity.identity(key: key, certificate: certificate))
            tlsCertHash = RDSelfSignedIdentity.certificateHash(of: identity)
            listener = try NWListener(using: try XCTUnwrap(RDQUIC.serverParameters(identity: identity)), on: .any)
        } else {
            listener = try NWListener(using: .tcp, on: .any)
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        if quic {
            // The production acceptance code (as HostServer uses it), on the test queue.
            let acceptor = QUICAcceptor(queue: queue, log: { print($0) }, onStream: { [self] stream, group, firstBytes in
                self.group = group
                adopt(stream)
                consume(firstBytes)
                receive()
            })
            quicAcceptor = acceptor
            listener.newConnectionGroupHandler = { group in acceptor.accept(group) }
        } else {
            listener.newConnectionHandler = { [self] connection in
                adopt(connection)
                connection.start(queue: queue)
                receive()
            }
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        return listener.port!.rawValue
    }

    private func adopt(_ connection: NWConnection) {
        self.connection = connection
        reader = RDFrameReader()
        reader.maxPayload = RDService.maxHandshakePayload
        sendCipher = nil
        receiveCipher = nil
        framesSent = 0
    }

    func stop() {
        videoStream?.cancel()
        connection?.cancel()
        datagramFlow?.cancel()
        quicAcceptor?.cancelAll()
        listener.cancel()
    }

    private func startDatagramVideo(maxSize: Int) {
        guard sendDatagramVideo, let group, let videoKey,
              let flow = RDQUIC.makeDatagramFlow(on: group) else { return }
        datagramFlow = flow
        let packetizer = RDVideoPacketizer(key: (quicTLSBound && offeredUnsealed == true) ? nil : videoKey,
                                           fecEnabled: enableDatagramFEC && offeredFEC == true)
        flow.stateUpdateHandler = { [self] state in
            guard case .ready = state else { return }
            let sendDatagramsAndResume: @Sendable () -> Void = { [self] in
                for (number, payload, keyframe) in datagramFrames {
                    let pieces = packetizer.datagrams(frame: number, payload: payload, isKeyframe: keyframe,
                                                      maxDatagramSize: min(maxSize, 1200))!
                    var droppedOneDataPiece = false
                    for piece in pieces.reversed() {
                        let isParity = (piece[8] & RDVideoDatagram.fecParityFlag) != 0
                        if dropFirstDatagramDataPiece, !isParity, !droppedOneDataPiece {
                            droppedOneDataPiece = true
                            continue
                        }
                        flow.send(content: piece, completion: .idempotent)
                    }
                }
                guard let (next, payload) = resumeStreamFrame else { return }
                queue.asyncAfter(deadline: .now() + 0.25) { [self] in
                    let onDedicated = resumeOnDedicatedVideoStream && videoStream != nil
                    write(try! sendCipher!.seal(.videoStream,
                                                 RDJSON.encode(VideoStreamMsg(nextFrame: next,
                                                                              onVideoStream: onDedicated ? true : nil,
                                                                              leavingDatagrams: true))))
                    queue.asyncAfter(deadline: .now() + 0.03) { [self] in
                        if let (lateNum, latePayload) = sendLateDatagramAfterResume,
                           let latePieces = packetizer.datagrams(frame: lateNum, payload: latePayload,
                                                                 isKeyframe: true, maxDatagramSize: min(maxSize, 1200)) {
                            for piece in latePieces {
                                flow.send(content: piece, completion: .idempotent)
                            }
                        }
                        queue.asyncAfter(deadline: .now() + 0.03) { [self] in
                            if onDedicated, let stream = videoStream {
                                let wireFrame = quicTLSBound
                                    ? RDFrame.pack(.frame, payload: payload)
                                    : (try! videoStreamSendCipher!.seal(.frame, payload))
                                stream.send(content: wireFrame, completion: .contentProcessed { _ in })
                            } else {
                                write(try! sendCipher!.seal(.frame, payload))
                            }
                        }
                    }
                }
            }
            if datagramSendDelay > 0 {
                queue.asyncAfter(deadline: .now() + datagramSendDelay, execute: sendDatagramsAndResume)
            } else {
                sendDatagramsAndResume()
            }
        }
        flow.start(queue: queue)
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, isComplete, error in
            if let data {
                consume(data)
            }
            if error == nil, !isComplete {
                receive()
            }
        }
    }

    /// Feeds bytes to the frame reader and handles every complete message.
    private func consume(_ data: Data) {
        reader.append(data)
        while let frame = try? reader.nextFrame() {
            if let wire = frame.wire {
                receivedLock.lock()
                _received.append(wire)
                receivedLock.unlock()
            }
            var payload = frame.body
            if receiveCipher != nil {
                guard let plain = try? receiveCipher?.open(header: frame.header, body: frame.body) else {
                    connection?.cancel()
                    return
                }
                payload = plain
            }
            if let wire = frame.wire {
                handle(wire, payload)
            }
        }
    }

    private func handle(_ wire: RDWire, _ payload: Data) {
        switch wire {
        case .hello:
            let hello = RDJSON.decode(HelloMsg.self, from: payload)!
            deviceId = hello.deviceId
            if let refusal = refuseBeforeHandshake {
                let msg = AuthFailedMsg(reason: "This device is no longer trusted. Enter the PIN.", kind: refusal)
                write(RDFrame.pack(.authFailed, payload: RDJSON.encode(msg)))
                return
            }
            let certHashForHandshake: Data? = enableTLSBinding
                ? (forgeTLSCertHash ? RDCrypto.sha256(Data("wrong-cert".utf8)) : tlsCertHash)
                : nil
            let response = RDHandshake.respond(to: hello,
                                               identityKey: identity.publicKey.rawRepresentation,
                                               serverId: serverId,
                                               serverName: "Loopback Mac",
                                               tlsCertHash: certHashForHandshake,
                                               sign: { [identity, forgeSignature] message in
                let signature = try? identity.signature(for: message)
                return forgeSignature ? signature.map { Data($0.reversed()) } : signature
            })!
            transcript = response.transcript
            quicTLSBound = response.serverHello.quicTLSBound == true
            write(RDFrame.pack(.serverHello, payload: RDJSON.encode(response.serverHello)))
            sendCipher = RDCipher(key: response.keys.serverToClient)
            receiveCipher = RDCipher(key: response.keys.clientToServer)
            videoKey = response.keys.videoDatagrams
            videoStreamSendCipher = RDCipher(key: response.keys.videoStream)
            videoStreamReceiveCipher = RDCipher(key: response.keys.videoStream)

        case .authPin:
            let msg = RDJSON.decode(AuthPinMsg.self, from: payload)!
            guard msg.pin == pin else {
                write(seal(.authFailed, AuthFailedMsg(reason: "Incorrect PIN", kind: .incorrectPin)))
                return
            }
            if msg.trust {
                trustedDeviceKey = msg.deviceKey
            }
            authenticate(trusted: msg.trust)

        case .authDevice:
            let msg = RDJSON.decode(AuthDeviceMsg.self, from: payload)!
            if let key = trustedDeviceKey,
               RDHandshake.isValidSignature(msg.signature, publicKey: key,
                                            message: RDHandshake.deviceProof(transcript: transcript)) {
                authenticate(trusted: true)
            } else {
                write(seal(.authFailed, AuthFailedMsg(reason: "untrusted", kind: .untrusted)))
            }

        case .ping:
            write(seal(.pong, RDJSON.decode(PingMsg.self, from: payload)!))

        case .frameAck where payload.count >= 4:
            lastFrameAck = payload.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        case .videoDatagrams:
            let offer = RDJSON.decode(VideoDatagramsMsg.self, from: payload)!
            offeredCanResume = offer.canResumeStream
            offeredFEC = offer.fec
            offeredUnsealed = offer.unsealed
            startDatagramVideo(maxSize: offer.maxSize)

        default:
            break
        }
    }

    private func authenticate(trusted: Bool) {
        if useDedicatedVideoStream, let group, let acceptor = quicAcceptor {
            acceptor.registerExtraStreamHandler(for: group, handler: { [self] stream, firstData in
                self.handleExtraVideoStream(stream, initialData: firstData)
            }, then: { [self] in
                self.sendAuthOKBurst(trusted: trusted, supportsVideoStream: true)
            })
        } else {
            sendAuthOKBurst(trusted: trusted, supportsVideoStream: false)
        }
    }

    private func sendAuthOKBurst(trusted: Bool, supportsVideoStream: Bool) {
        var burst = seal(.authOK, AuthOKMsg(serverName: "Loopback Mac",
                                            trusted: trusted,
                                            macAddress: nil,
                                            supportsVideoStream: supportsVideoStream ? true : nil))
        burst.append(try! sendCipher!.seal(.runningApps, largeMessage))
        burst.append(try! sendCipher!.seal(.frame, RDFrameCodec.pack(width: 2, height: 2, codec: .hevc, data: Data([0, 0, 0, 1, 0x26]))))
        framesSent = 1
        write(burst)
    }

    private func handleExtraVideoStream(_ stream: NWConnection, initialData: Data) {
        videoStream = stream
        videoStreamReader = RDFrameReader()
        videoStreamReader.append(initialData)
        guard let frame = try? videoStreamReader.nextFrame(),
              let plain = try? videoStreamReceiveCipher?.open(header: frame.header, body: frame.body),
              frame.wire == .videoStreamAttach,
              RDJSON.decode(VideoStreamAttachMsg.self, from: plain) != nil else {
            stream.cancel()
            return
        }
        receivedVideoStreamAttach = true
        receivedLock.lock()
        _received.append(.videoStreamAttach)
        receivedLock.unlock()

        write(seal(.videoStream, VideoStreamMsg(nextFrame: 2, onVideoStream: true)))
        if let dedicatedStreamFrame {
            let wireFrame = quicTLSBound
                ? RDFrame.pack(.frame, payload: dedicatedStreamFrame)
                : (try! videoStreamSendCipher!.seal(.frame, dedicatedStreamFrame))
            stream.send(content: wireFrame, completion: .contentProcessed { _ in })
            if let switchBackFrame {
                queue.asyncAfter(deadline: .now() + 0.15) { [self] in
                    write(seal(.videoStream, VideoStreamMsg(nextFrame: 3, onVideoStream: false)))
                    write(try! sendCipher!.seal(.frame, switchBackFrame))
                }
            }
        }
    }

    private func seal<T: Encodable>(_ wire: RDWire, _ message: T) -> Data {
        try! sendCipher!.seal(wire, RDJSON.encode(message))
    }

    private func write(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }
}

/// Collects what the client connection reports, from any thread.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ClientConnection.Event] = []
    private var videoFrames: [Data] = []
    private var waiters: [(predicate: () -> Bool, expectation: XCTestExpectation)] = []

    func record(_ event: ClientConnection.Event) {
        lock.lock()
        events.append(event)
        lock.unlock()
        fulfillWaiters()
    }

    func recordVideo(_ payload: Data) {
        lock.lock()
        videoFrames.append(payload)
        lock.unlock()
        fulfillWaiters()
    }

    var snapshot: (events: [ClientConnection.Event], video: [Data]) {
        lock.lock()
        defer { lock.unlock() }
        return (events, videoFrames)
    }

    func expectation(_ description: String, _ predicate: @escaping () -> Bool) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: description)
        lock.lock()
        waiters.append((predicate, expectation))
        lock.unlock()
        fulfillWaiters()
        return expectation
    }

    private func fulfillWaiters() {
        lock.lock()
        let pending = waiters
        lock.unlock()
        for waiter in pending where waiter.predicate() {
            waiter.expectation.fulfill()
            lock.lock()
            waiters.removeAll { $0.expectation === waiter.expectation }
            lock.unlock()
        }
    }

    var serverIdentity: ServerIdentity? {
        for case .serverHello(let identity) in snapshot.events { return identity }
        return nil
    }

    func messages(_ wire: RDWire) -> [Data] {
        snapshot.events.compactMap {
            if case .message(let w, let payload) = $0, w == wire { return payload }
            return nil
        }
    }

    /// Pongs arrive as their own event, already timed.
    var pongs: Int {
        snapshot.events.filter { if case .pong = $0 { return true } else { return false } }.count
    }

    var failure: String? {
        for case .failed(let reason) in snapshot.events { return reason }
        return nil
    }
}

final class LoopbackTests: XCTestCase {
    private var host: LoopbackHost!
    private var port: UInt16 = 0

    override func setUpWithError() throws {
        host = LoopbackHost()
        port = try host.start()
    }

    override func tearDown() {
        host.stop()
    }

    private func connect(deviceId: String = "loopback-device",
                         quicPort: UInt16? = nil) -> (ClientConnection, EventLog) {
        let log = EventLog()
        let quicEndpoint = quicPort.map { NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: $0)!) }
        let connection = ClientConnection(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                                          quicEndpoint: quicEndpoint,
                                          deviceId: deviceId,
                                          deviceName: "Test iPhone",
                                          queue: DispatchQueue(label: "test.client"),
                                          onEvent: { log.record($0) },
                                          onVideoFrame: { log.recordVideo($0) })
        connection.start()
        return (connection, log)
    }

    func testPINPairingThenDeviceSignatureLogin() {
        let deviceKey = Curve25519.Signing.PrivateKey()

        // 1. Pair with the PIN.
        let (first, log) = connect()
        wait(for: [log.expectation("serverHello") { log.serverIdentity != nil }], timeout: 5)
        let identity = log.serverIdentity!
        XCTAssertEqual(identity.identityKey, host.identity.publicKey.rawRepresentation)
        XCTAssertEqual(identity.serverId, host.serverId)

        first.send(.authPin, RDJSON.encode(AuthPinMsg(pin: "0000", trust: true,
                                                      deviceKey: deviceKey.publicKey.rawRepresentation)))
        wait(for: [log.expectation("authFailed") { !log.messages(.authFailed).isEmpty }], timeout: 5)

        first.send(.authPin, RDJSON.encode(AuthPinMsg(pin: "1234", trust: true,
                                                      deviceKey: deviceKey.publicKey.rawRepresentation)))
        // authOK, a message 4× the handshake limit, and a video frame arrive in one write.
        wait(for: [log.expectation("authOK + burst") {
            !log.messages(.authOK).isEmpty && !log.messages(.runningApps).isEmpty && !log.snapshot.video.isEmpty
        }], timeout: 5)
        XCTAssertEqual(log.messages(.runningApps).first, host.largeMessage)
        XCTAssertEqual(RDFrameCodec.unpack(log.snapshot.video[0])?.codec, .hevc)
        XCTAssertNil(log.failure)

        first.send(.ping, RDJSON.encode(PingMsg(t: 42)))
        wait(for: [log.expectation("pong") { log.pongs > 0 }], timeout: 5)
        first.cancel()

        // 2. Reconnect and log in with a signature over the new handshake, no PIN.
        let (second, log2) = connect()
        wait(for: [log2.expectation("serverHello") { log2.serverIdentity != nil }], timeout: 5)
        let secondIdentity = log2.serverIdentity!
        XCTAssertEqual(secondIdentity.identityKey, identity.identityKey)
        XCTAssertNotEqual(secondIdentity.transcript, identity.transcript)

        let signature = try! deviceKey.signature(for: RDHandshake.deviceProof(transcript: secondIdentity.transcript))
        second.send(.authDevice, RDJSON.encode(AuthDeviceMsg(signature: signature)))
        wait(for: [log2.expectation("authOK") { !log2.messages(.authOK).isEmpty }], timeout: 5)
        second.cancel()
    }

    /// The same handshake, pairing, large burst and pong over one QUIC stream. The QUIC
    /// host has no TCP listener, so success can't come from the TCP fallback.
    func testHandshakeAndPairingOverQUIC() throws {
        let quicHost = LoopbackHost()
        let quicPort = try quicHost.start(quic: true)
        defer { quicHost.stop() }
        let deviceKey = Curve25519.Signing.PrivateKey()

        let (first, log) = connect(quicPort: quicPort)
        wait(for: [log.expectation("serverHello over QUIC") { log.serverIdentity != nil }], timeout: 5)
        XCTAssertEqual(log.serverIdentity?.identityKey, quicHost.identity.publicKey.rawRepresentation)
        first.send(.authPin, RDJSON.encode(AuthPinMsg(pin: "1234", trust: true,
                                                      deviceKey: deviceKey.publicKey.rawRepresentation)))
        wait(for: [log.expectation("authOK + burst") {
            !log.messages(.authOK).isEmpty && !log.messages(.runningApps).isEmpty && !log.snapshot.video.isEmpty
        }], timeout: 5)
        XCTAssertEqual(log.messages(.runningApps).first, quicHost.largeMessage)
        first.send(.ping, RDJSON.encode(PingMsg(t: 42)))
        wait(for: [log.expectation("pong") { log.pongs > 0 }], timeout: 5)
        XCTAssertNil(log.failure)
        XCTAssertTrue(quicHost.received.contains(.frameAck))
        first.cancel()
        // The TCP host never saw a thing.
        XCTAssertTrue(host.received.isEmpty)
    }

    /// The host gives up on lossy datagrams: after `videoStream {nextFrame}` the client
    /// takes stream frames again, numbered from `nextFrame`, and confirms that number.
    func testVideoBackOnStreamAfterVideoStream() throws {
        let quicHost = LoopbackHost()
        quicHost.sendDatagramVideo = true
        let keyframe = RDFrameCodec.pack(width: 64, height: 64, codec: .hevc, data: Data(repeating: 7, count: 3000))
        let streamFrame = RDFrameCodec.pack(width: 64, height: 64, codec: .hevc, data: Data(repeating: 9, count: 500))
        quicHost.datagramFrames = [(2, keyframe, true)]
        quicHost.resumeStreamFrame = (5, streamFrame)
        let quicPort = try quicHost.start(quic: true)
        defer { quicHost.stop() }

        let (connection, log) = connect(quicPort: quicPort)
        wait(for: [log.expectation("serverHello") { log.serverIdentity != nil }], timeout: 5)
        connection.send(.authPin, RDJSON.encode(AuthPinMsg(pin: "1234", trust: false, deviceKey: nil)))
        wait(for: [log.expectation("stream, datagram, stream frames") { log.snapshot.video.count >= 3 }], timeout: 5)
        XCTAssertEqual(quicHost.offeredCanResume, true)
        XCTAssertEqual(log.snapshot.video[1], keyframe)
        XCTAssertEqual(log.snapshot.video[2], streamFrame)
        let deadline = Date().addingTimeInterval(2)
        while quicHost.lastFrameAck != 5, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(quicHost.lastFrameAck, 5)
        XCTAssertNil(log.failure)
        connection.cancel()
    }

    /// Video moves to datagrams after authOK: a multi-piece keyframe (pieces reversed)
    /// arrives whole, a frame after a gap is discarded and a keyframe requested, and
    /// the next keyframe resumes. Frame 1 came on the stream, so numbering goes on at 2.
    func testVideoOverQUICDatagrams() throws {
        let quicHost = LoopbackHost()
        quicHost.sendDatagramVideo = true
        let big = Data((0..<6000).map { UInt8($0 % 251) })
        let keyframe = RDFrameCodec.pack(width: 64, height: 64, codec: .hevc, data: big)
        let resume = RDFrameCodec.pack(width: 64, height: 64, codec: .hevc, data: Data(big.prefix(2500)))
        quicHost.datagramFrames = [(2, keyframe, true),
                                   (4, RDFrameCodec.pack(width: 64, height: 64, codec: .hevc, data: Data([1, 2, 3])), false),
                                   (5, resume, true)]
        let quicPort = try quicHost.start(quic: true)
        defer { quicHost.stop() }

        let (connection, log) = connect(quicPort: quicPort)
        wait(for: [log.expectation("serverHello") { log.serverIdentity != nil }], timeout: 5)
        connection.send(.authPin, RDJSON.encode(AuthPinMsg(pin: "1234", trust: false, deviceKey: nil)))
        // Strict: the release job runs this on macOS 26, where a datagram flow with fresh
        // options never became ready (see `RDQUIC.makeDatagramFlow`).
        wait(for: [log.expectation("stream frame + 2 datagram frames") { log.snapshot.video.count >= 3 }], timeout: 5)
        let video = log.snapshot.video
        XCTAssertEqual(video.count, 3)
        guard video.count == 3 else { return connection.cancel() }
        XCTAssertEqual(video[1], keyframe)
        XCTAssertEqual(video[2], resume)
        XCTAssertTrue(quicHost.received.contains(.videoDatagrams))
        let deadline = Date().addingTimeInterval(5)
        while !quicHost.received.contains(.requestKeyframe), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(quicHost.received.contains(.requestKeyframe))
        XCTAssertGreaterThanOrEqual(connection.drainStats().lost, 2)
        XCTAssertNil(log.failure)
        connection.cancel()
    }

    /// A host that advertises QUIC but doesn't answer on UDP: the attempt moves to TCP
    /// on its own, without a failure event.
    func testFallsBackToTCPWhenQUICDoesNotAnswer() {
        let (connection, log) = connect(quicPort: port)   // nothing listens on this UDP port
        wait(for: [log.expectation("serverHello over TCP") { log.serverIdentity != nil }], timeout: 5)
        XCTAssertNil(log.failure)
        XCTAssertEqual(host.received.first, .hello)
        // After authOK the client tells the host why it left QUIC.
        connection.send(.authPin, RDJSON.encode(AuthPinMsg(pin: "1234", trust: false, deviceKey: nil)))
        let deadline = Date().addingTimeInterval(5)
        while !host.received.contains(.transportNote), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(host.received.contains(.transportNote))
        connection.cancel()
    }

    func testReplayedDeviceProofIsRejected() {
        let deviceKey = Curve25519.Signing.PrivateKey()
        let (first, log) = connect()
        wait(for: [log.expectation("serverHello") { log.serverIdentity != nil }], timeout: 5)
        first.send(.authPin, RDJSON.encode(AuthPinMsg(pin: "1234", trust: true,
                                                      deviceKey: deviceKey.publicKey.rawRepresentation)))
        wait(for: [log.expectation("authOK") { !log.messages(.authOK).isEmpty }], timeout: 5)
        // A proof for this handshake, as an impostor host would have collected it…
        let oldProof = try! deviceKey.signature(for: RDHandshake.deviceProof(transcript: log.serverIdentity!.transcript))
        first.cancel()

        // …is useless in any other session.
        let (second, log2) = connect()
        wait(for: [log2.expectation("serverHello") { log2.serverIdentity != nil }], timeout: 5)
        second.send(.authDevice, RDJSON.encode(AuthDeviceMsg(signature: oldProof)))
        wait(for: [log2.expectation("authFailed") { !log2.messages(.authFailed).isEmpty }], timeout: 5)
        XCTAssertTrue(log2.messages(.authOK).isEmpty)
        second.cancel()
    }

    func testPlaintextRefusalBeforeHandshakeNeverLeadsToAPlaintextPIN() {
        // An impostor that skips serverHello and asks for the PIN in the clear.
        host.refuseBeforeHandshake = .untrusted
        let (connection, log) = connect()
        wait(for: [log.expectation("failure") { log.failure != nil }], timeout: 5)
        XCTAssertTrue(log.messages(.authFailed).isEmpty, "a pre-handshake authFailed must not reach the session")
        XCTAssertNil(log.serverIdentity)

        // Even if something tried to send a PIN now, nothing but hello may leave unencrypted.
        connection.send(.authPin, RDJSON.encode(AuthPinMsg(pin: "1234", trust: false, deviceKey: nil)))
        let settled = expectation(description: "give a stray send time to arrive")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(host.received, [.hello])
        connection.cancel()
    }

    func testVersionRefusalIsTerminal() {
        host.refuseBeforeHandshake = .unsupportedVersion
        let (connection, log) = connect()
        let rejected = log.expectation("rejected") {
            log.snapshot.events.contains { if case .rejected = $0 { return true } else { return false } }
        }
        wait(for: [rejected], timeout: 5)
        connection.cancel()
    }

    func testImpostorWithoutTheIdentityKeyIsRejected() {
        host.forgeSignature = true
        let (connection, log) = connect()
        wait(for: [log.expectation("failure") { log.failure != nil }], timeout: 5)
        XCTAssertNil(log.serverIdentity, "the client must not accept a serverHello it can't verify")
        connection.cancel()
    }

    func testQUICTLSChannelBindingUnsealedDatagramsAndFECLossRecovery() throws {
        let quicHost = LoopbackHost()
        quicHost.enableTLSBinding = true
        quicHost.sendDatagramVideo = true
        quicHost.enableDatagramFEC = true
        quicHost.dropFirstDatagramDataPiece = true
        let frame = RDFrameCodec.packAVCC(width: 64,
                                          height: 64,
                                          codec: .hevc,
                                          parameterSets: [Data([0x40, 0x01])],
                                          data: Data((0..<4500).map { UInt8($0 % 251) }))
        quicHost.datagramFrames = [(2, frame, true)]
        let quicPort = try quicHost.start(quic: true)
        defer { quicHost.stop() }

        let (connection, log) = connect(quicPort: quicPort)
        wait(for: [log.expectation("serverHello") { log.serverIdentity != nil }], timeout: 5)
        connection.send(.authPin, RDJSON.encode(AuthPinMsg(pin: "1234", trust: false, deviceKey: nil)))
        wait(for: [log.expectation("stream frame + FEC-recovered unsealed datagram frame") { log.snapshot.video.count >= 2 }], timeout: 5)

        XCTAssertEqual(quicHost.offeredFEC, true)
        XCTAssertEqual(quicHost.offeredUnsealed, true)
        XCTAssertEqual(log.snapshot.video[1], frame)
        XCTAssertEqual(connection.drainStats().lost, 0)
        XCTAssertNil(log.failure)
        connection.cancel()
    }

    func testQUICTLSBindingRejectsMismatchedCertDigest() throws {
        let quicHost = LoopbackHost()
        quicHost.enableTLSBinding = true
        quicHost.forgeTLSCertHash = true
        let quicPort = try quicHost.start(quic: true)
        defer { quicHost.stop() }

        let (connection, log) = connect(quicPort: quicPort)
        wait(for: [log.expectation("TLS binding mismatch rejected") { log.failure != nil }], timeout: 5)
        XCTAssertNil(log.serverIdentity)
        connection.cancel()
    }

    func testDedicatedQUICVideoStreamAttachesStreamsAndFallsBackCleanly() throws {
        let quicHost = LoopbackHost()
        quicHost.enableTLSBinding = true
        quicHost.useDedicatedVideoStream = true
        let frame2 = RDFrameCodec.packAVCC(width: 128,
                                           height: 72,
                                           codec: .hevc,
                                           parameterSets: [Data([0x40, 0x01])],
                                           data: Data(repeating: 0x2A, count: 1024))
        let frame3 = RDFrameCodec.packAVCC(width: 128,
                                           height: 72,
                                           codec: .hevc,
                                           parameterSets: [],
                                           data: Data(repeating: 0x3B, count: 512))
        quicHost.dedicatedStreamFrame = frame2
        quicHost.switchBackFrame = frame3
        let quicPort = try quicHost.start(quic: true)
        defer { quicHost.stop() }

        let (connection, log) = connect(quicPort: quicPort)
        wait(for: [log.expectation("serverHello") { log.serverIdentity != nil }], timeout: 5)
        connection.send(.authPin, RDJSON.encode(AuthPinMsg(pin: "1234", trust: false, deviceKey: nil)))
        wait(for: [log.expectation("dedicated video stream + fallback frame") { log.snapshot.video.count >= 3 }], timeout: 5)

        XCTAssertTrue(quicHost.receivedVideoStreamAttach)
        XCTAssertEqual(log.snapshot.video[1], frame2)
        XCTAssertEqual(log.snapshot.video[2], frame3)
        let deadline = Date().addingTimeInterval(2)
        while quicHost.lastFrameAck != 3, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(quicHost.lastFrameAck, 3)

        connection.send(.ping, RDJSON.encode(PingMsg(t: 99)))
        wait(for: [log.expectation("control stream stays healthy") { log.pongs > 0 }], timeout: 5)
        XCTAssertNil(log.failure)
        connection.cancel()
    }

    func testDedicatedVideoStreamPreservesReassemblerForDatagramsAndResumesCleanly() throws {
        let quicHost = LoopbackHost()
        quicHost.enableTLSBinding = true
        quicHost.useDedicatedVideoStream = true
        quicHost.sendDatagramVideo = true
        quicHost.enableDatagramFEC = true
        quicHost.datagramSendDelay = 0.2
        quicHost.resumeOnDedicatedVideoStream = true
        let frame2 = RDFrameCodec.packAVCC(width: 128,
                                           height: 72,
                                           codec: .hevc,
                                           parameterSets: [Data([0x40, 0x01])],
                                           data: Data(repeating: 0x2A, count: 1024))
        let frame3 = RDFrameCodec.packAVCC(width: 128,
                                           height: 72,
                                           codec: .hevc,
                                           parameterSets: [Data([0x40, 0x01])],
                                           data: Data((0..<3200).map { UInt8($0 % 251) }))
        let staleDatagramFrame = RDFrameCodec.packAVCC(width: 128,
                                                       height: 72,
                                                       codec: .hevc,
                                                       parameterSets: [],
                                                       data: Data(repeating: 0xEE, count: 512))
        let frame4 = RDFrameCodec.packAVCC(width: 128,
                                           height: 72,
                                           codec: .hevc,
                                           parameterSets: [Data([0x40, 0x01])],
                                           data: Data(repeating: 0x4C, count: 768))
        quicHost.dedicatedStreamFrame = frame2
        quicHost.datagramFrames = [(3, frame3, true)]
        quicHost.sendLateDatagramAfterResume = (4, staleDatagramFrame)
        quicHost.resumeStreamFrame = (4, frame4)
        let quicPort = try quicHost.start(quic: true)
        defer { quicHost.stop() }

        let (connection, log) = connect(quicPort: quicPort)
        wait(for: [log.expectation("serverHello") { log.serverIdentity != nil }], timeout: 5)
        connection.send(.authPin, RDJSON.encode(AuthPinMsg(pin: "1234", trust: false, deviceKey: nil)))
        wait(for: [log.expectation("stream -> dedicated stream -> datagrams -> dedicated stream") {
            log.snapshot.video.count >= 4
        }], timeout: 5)

        XCTAssertTrue(quicHost.receivedVideoStreamAttach)
        XCTAssertEqual(log.snapshot.video[1], frame2)
        XCTAssertEqual(log.snapshot.video[2], frame3)
        XCTAssertEqual(log.snapshot.video[3], frame4)
        let deadline = Date().addingTimeInterval(2)
        while quicHost.lastFrameAck != 4, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(quicHost.lastFrameAck, 4)
        XCTAssertNil(log.failure)
        connection.cancel()
    }
}
