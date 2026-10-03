import Foundation
import Network
import CryptoKit

/// What the client learned (and verified) from the host's `serverHello`.
struct ServerIdentity: Sendable {
    let serverId: String
    let serverName: String
    let identityKey: Data
    let transcript: Data
}

/// The network side of one connection attempt: socket, framing, the handshake
/// crypto, and per-direction encryption.
///
/// Everything mutable is confined to `queue`, and the callbacks run there too, so
/// none of this touches main-actor state. `ClientSession` hops events to the main
/// actor; video payloads go straight to the decode pipeline.
final class ClientConnection: @unchecked Sendable {
    enum Event: Sendable {
        case ready(NWEndpoint?)
        /// The host proved it holds `identityKey`; encryption is now active.
        case serverHello(ServerIdentity)
        case message(RDWire, Data)
        case closed
        case failed(String)
        /// The host refused this client outright (version mismatch); don't retry on our own.
        case rejected(String)
    }

    struct Stats {
        var bytes = 0
        var frames = 0
    }

    private let queue: DispatchQueue
    private let connection: NWConnection
    private let deviceId: String
    private let deviceName: String
    private let onEvent: @Sendable (Event) -> Void
    private let onVideoFrame: @Sendable (Data) -> Void

    private var ephemeralKey: Curve25519.KeyAgreement.PrivateKey?
    private var reader = RDFrameReader()
    private var sendCipher: RDCipher?
    private var receiveCipher: RDCipher?
    private var isFinished = false

    private let statsLock = NSLock()
    private var stats = Stats()

    init(to endpoint: NWEndpoint,
         deviceId: String,
         deviceName: String,
         queue: DispatchQueue,
         onEvent: @escaping @Sendable (Event) -> Void,
         onVideoFrame: @escaping @Sendable (Data) -> Void) {
        self.queue = queue
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.onEvent = onEvent
        self.onVideoFrame = onVideoFrame
        connection = NWConnection(to: endpoint, using: Self.makeParameters())
        reader.maxPayload = RDService.maxHandshakePayload
    }

    static func makeParameters() -> NWParameters {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.connectionTimeout = 6
        tcpOptions.enableFastOpen = true
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = false
        if let ipOptions = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ipOptions.version = .v4
        }
        return params
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            self?.handleState(state)
        }
        connection.start(queue: queue)
    }

    /// Closes the connection without reporting an event.
    func cancel() {
        queue.async { self.finish(nil) }
    }

    /// Encrypts (once keys exist) and sends a message. Safe to call from any thread;
    /// messages go out in call order, which keeps the nonce counter in sync.
    func send(_ wire: RDWire, _ payload: Data) {
        queue.async { self.write(wire, payload, then: nil) }
    }

    /// Sends a last message and closes once it has been written.
    func sendAndClose(_ wire: RDWire, _ payload: Data) {
        queue.async {
            guard !self.isFinished else { return }
            let connection = self.connection
            self.write(wire, payload) { connection.cancel() }
            self.isFinished = true
            // Don't hang on to a connection whose peer stopped reading.
            self.queue.asyncAfter(deadline: .now() + 2) { connection.cancel() }
        }
    }

    func drainStats() -> Stats {
        statsLock.lock()
        defer { statsLock.unlock() }
        let current = stats
        stats = Stats()
        return current
    }

    // MARK: Queue-confined

    private func write(_ wire: RDWire, _ payload: Data, then completion: (@Sendable () -> Void)?) {
        guard !isFinished else { return }
        // Until the host has proven its identity and keys exist, only `hello` may go out.
        // Anything else (a PIN above all) is dropped rather than sent in the clear.
        guard sendCipher != nil || wire == .hello else { return }
        let frame: Data
        if sendCipher != nil {
            guard let sealed = try? sendCipher?.seal(wire, payload) else {
                finish(.failed("Encryption failed"))
                return
            }
            frame = sealed
        } else {
            frame = RDFrame.pack(wire, payload: payload)
        }
        connection.send(content: frame, completion: .contentProcessed { _ in completion?() })
    }

    private func handleState(_ state: NWConnection.State) {
        guard !isFinished else { return }
        switch state {
        case .ready:
            onEvent(.ready(connection.currentPath?.remoteEndpoint))
            sendHello()
            receive()
        case .failed(let error):
            finish(.failed(error.localizedDescription))
        case .cancelled:
            finish(.closed)
        case .waiting(let error):
            if case .posix(let code) = error, code == .ECONNREFUSED || code == .EHOSTUNREACH || code == .ENETUNREACH {
                finish(.failed(error.localizedDescription))
            }
        default:
            break
        }
    }

    private func finish(_ event: Event?) {
        guard !isFinished else { return }
        isFinished = true
        connection.cancel()
        if let event {
            onEvent(event)
        }
    }

    private func sendHello() {
        let key = RDCrypto.makePrivateKey()
        ephemeralKey = key
        let hello = HelloMsg(deviceId: deviceId, deviceName: deviceName, pubKey: key.publicKey.rawRepresentation)
        write(.hello, RDJSON.encode(hello), then: nil)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, isComplete, error in
            guard let self, !self.isFinished else { return }
            if let error {
                self.finish(.failed(error.localizedDescription))
                return
            }
            if let chunk, !chunk.isEmpty {
                self.reader.append(chunk)
                self.processFrames()
            }
            if isComplete {
                self.finish(.closed)
                return
            }
            if !self.isFinished {
                self.receive()
            }
        }
    }

    private func processFrames() {
        while !isFinished {
            let frame: RDFrameData
            do {
                guard let next = try reader.nextFrame() else { return }
                frame = next
            } catch {
                finish(.failed("Protocol error: corrupted frame"))
                return
            }
            countStats(bytes: frame.header.count + frame.body.count, isVideo: frame.wire == .frame)

            guard receiveCipher != nil else {
                // Before the handshake only `serverHello` (or a version rejection) is valid.
                switch frame.wire {
                case .serverHello:
                    handleServerHello(frame.body)
                case .authFailed:
                    // Unauthenticated, so the only thing it may mean is a version refusal; the
                    // peer's own text isn't shown (it could ask for the PIN), and nothing else follows.
                    let msg = RDJSON.decode(AuthFailedMsg.self, from: frame.body)
                    finish(msg?.kind == .unsupportedVersion
                           ? .rejected("This Mac runs a different version of Local Desktop. Update both apps.")
                           : .failed("Protocol error: the Mac refused the connection before identifying itself."))
                    return
                default:
                    finish(.failed("Protocol error: unexpected message before handshake"))
                }
                continue
            }

            guard let plain = try? receiveCipher?.open(header: frame.header, body: frame.body) else {
                finish(.failed("The connection was corrupted or tampered with."))
                return
            }
            guard let wire = frame.wire else { continue }
            switch wire {
            case .frame:
                onVideoFrame(plain)
            case .serverHello:
                finish(.failed("Protocol error: repeated handshake"))
            default:
                if wire == .authOK {
                    // Video and app lists can be large; lift the handshake limit before
                    // parsing whatever follows authOK in this same chunk.
                    reader.maxPayload = RDService.maxPayload
                }
                onEvent(.message(wire, plain))
            }
        }
    }

    private func handleServerHello(_ payload: Data) {
        guard let msg = RDJSON.decode(ServerHelloMsg.self, from: payload),
              msg.version == RDService.protocolVersion,
              let key = ephemeralKey else {
            finish(.failed("This Mac runs an incompatible version of Local Desktop Host. Update both apps."))
            return
        }
        // The id must be derived from the key, and the key must have signed this very handshake.
        guard RDHandshake.serverId(for: msg.identityKey) == msg.serverId else {
            finish(.failed("Handshake failed: the Mac's identity doesn't match its id."))
            return
        }
        let transcript = RDHandshake.transcriptHash(clientKey: key.publicKey.rawRepresentation,
                                                    deviceId: deviceId,
                                                    serverKey: msg.pubKey,
                                                    serverIdentity: msg.identityKey,
                                                    serverId: msg.serverId)
        guard RDHandshake.isValidSignature(msg.signature, publicKey: msg.identityKey,
                                           message: RDHandshake.serverProof(transcript: transcript)),
              let keys = RDHandshake.sessionKeys(privateKey: key, peerPublicKey: msg.pubKey, transcript: transcript) else {
            finish(.failed("Handshake failed: the Mac couldn't prove its identity."))
            return
        }
        ephemeralKey = nil
        sendCipher = RDCipher(key: keys.clientToServer)
        receiveCipher = RDCipher(key: keys.serverToClient)
        onEvent(.serverHello(ServerIdentity(serverId: msg.serverId,
                                            serverName: msg.serverName,
                                            identityKey: msg.identityKey,
                                            transcript: transcript)))
    }

    private func countStats(bytes: Int, isVideo: Bool) {
        statsLock.lock()
        stats.bytes += bytes
        if isVideo {
            stats.frames += 1
        }
        statsLock.unlock()
    }
}
