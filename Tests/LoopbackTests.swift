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
    private var reader = RDFrameReader()
    private var sendCipher: RDCipher?
    private var receiveCipher: RDCipher?
    private var transcript = Data()
    private var deviceId = ""

    var serverId: String { RDHandshake.serverId(for: identity.publicKey.rawRepresentation) }

    func start() throws -> UInt16 {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [self] connection in
            self.connection = connection
            reader = RDFrameReader()
            reader.maxPayload = RDService.maxHandshakePayload
            sendCipher = nil
            receiveCipher = nil
            connection.start(queue: queue)
            receive()
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        return listener.port!.rawValue
    }

    func stop() {
        connection?.cancel()
        listener.cancel()
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, isComplete, error in
            if let data {
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
            if error == nil, !isComplete {
                receive()
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
            let response = RDHandshake.respond(to: hello,
                                               identityKey: identity.publicKey.rawRepresentation,
                                               serverId: serverId,
                                               serverName: "Loopback Mac",
                                               sign: { [identity, forgeSignature] message in
                let signature = try? identity.signature(for: message)
                return forgeSignature ? signature.map { Data($0.reversed()) } : signature
            })!
            transcript = response.transcript
            write(RDFrame.pack(.serverHello, payload: RDJSON.encode(response.serverHello)))
            sendCipher = RDCipher(key: response.keys.serverToClient)
            receiveCipher = RDCipher(key: response.keys.clientToServer)

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

        default:
            break
        }
    }

    private func authenticate(trusted: Bool) {
        var burst = seal(.authOK, AuthOKMsg(serverName: "Loopback Mac", trusted: trusted, macAddress: nil))
        burst.append(try! sendCipher!.seal(.runningApps, largeMessage))
        burst.append(try! sendCipher!.seal(.frame, RDFrameCodec.pack(width: 2, height: 2, codec: .hevc, data: Data([0, 0, 0, 1, 0x26]))))
        write(burst)
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

    private func connect(deviceId: String = "loopback-device") -> (ClientConnection, EventLog) {
        let log = EventLog()
        let connection = ClientConnection(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
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
        wait(for: [log.expectation("pong") { !log.messages(.pong).isEmpty }], timeout: 5)
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
}
