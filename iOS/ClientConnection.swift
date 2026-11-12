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
/// Transport: when the host advertises QUIC, the attempt starts on one bidirectional
/// QUIC stream and falls back to TCP if QUIC isn't ready within
/// `RDQUIC.fallbackDelay` or fails before `serverHello`. The fallback is invisible to
/// the caller: `ready` is reported once, and the handshake simply restarts on TCP.
/// Both transports are byte streams, so everything above `connection` is shared.
///
/// QUIC runs as a connection group: the control stream carries the protocol, and
/// once authenticated the client offers `videoDatagrams`; the host then sends video
/// as datagrams (`RDVideoDatagram`), rebuilt here by `RDVideoReassembler`.
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
        /// A `pong`, timed here on arrival: timed on the main thread it also measured how
        /// busy the UI was (typing with the on-screen keyboard showed as RTT spikes).
        case pong(rttMs: Double)
        case closed
        case failed(String)
        /// The host refused this client outright (version mismatch); don't retry on our own.
        case rejected(String)
    }

    struct Stats {
        var bytes = 0
        var frames = 0
        /// Video frames lost or discarded on the datagram path.
        var lost = 0
    }

    private let queue: DispatchQueue
    /// The control stream (TCP, or a QUIC stream once the QUIC group is ready).
    private var connection: NWConnection?
    private let tcpEndpoint: NWEndpoint
    private var quicEndpoint: NWEndpoint?
    /// Resolves a Bonjour service to an address before QUIC: a connection group
    /// traps (crashes) when given a service endpoint instead of host and port.
    private var quicResolver: NWConnection?
    private var group: NWConnectionGroup?
    private var datagramFlow: NWConnection?
    private var videoKey: SymmetricKey?
    private var reassembler: RDVideoReassembler?
    private var isAuthenticated = false
    private var offeredDatagrams = false
    private var lastLossKeyframeRequest: TimeInterval = 0
    /// QUIC attempt events with their time since `start`, for the fallback reason.
    private var quicStartedAt: TimeInterval = 0
    private var quicTrace: [String] = []
    /// Why this attempt left QUIC; sent to the host after `authOK` (`transportNote`).
    private var quicFallbackReason: String?
    private var streamRetried = false
    /// The transport currently in use.
    private var transport: RDTransport
    private var reportedReady = false
    private let deviceId: String
    private let deviceName: String
    private let onEvent: @Sendable (Event) -> Void
    private let onVideoFrame: @Sendable (Data) -> Void

    private var ephemeralKey: Curve25519.KeyAgreement.PrivateKey?
    private var reader = RDFrameReader()
    private var sendCipher: RDCipher?
    /// Video frames received so far; confirmed to the host with each one (`frameAck`).
    private var framesReceived: UInt32 = 0
    /// Stream messages received and messages written since the last startup line.
    private var diagReceived: [RDWire: Int] = [:]
    private var diagWritten: [RDWire: Int] = [:]
    private var diagDatagrams = 0

    /// The first seconds after `authOK`, once a second: what came in on the stream and
    /// as datagrams and what went out, to see which side stalls when video doesn't start.
    private func logStartupDiagnostics(remaining: Int) {
        guard remaining > 0 else { return }
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.isFinished else { return }
            func list(_ counts: [RDWire: Int]) -> String {
                counts.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key)×\($0.value)" }.joined(separator: " ")
            }
            ClientLog.write("startup: in [\(list(self.diagReceived))] datagrams \(self.diagDatagrams) "
                            + "out [\(list(self.diagWritten))]")
            self.diagReceived = [:]
            self.diagWritten = [:]
            self.diagDatagrams = 0
            self.logStartupDiagnostics(remaining: remaining - 1)
        }
    }
    private var receiveCipher: RDCipher?
    private var isFinished = false

    private let statsLock = NSLock()
    private var stats = Stats()

    /// - Parameter quicEndpoint: where to try QUIC first; nil connects over TCP only.
    init(to endpoint: NWEndpoint,
         quicEndpoint: NWEndpoint? = nil,
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
        tcpEndpoint = endpoint
        self.quicEndpoint = quicEndpoint
        if quicEndpoint != nil {
            transport = .quic
            connection = nil
        } else {
            transport = .tcp
            connection = NWConnection(to: endpoint, using: Self.makeParameters())
        }
        reader.maxPayload = RDService.maxHandshakePayload
    }

    static func makeParameters() -> NWParameters {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.connectionTimeout = 6
        tcpOptions.enableFastOpen = true
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        // Asks Wi-Fi to give this connection's packets the low-delay video queue.
        params.serviceClass = .interactiveVideo
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = false
        if let ipOptions = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ipOptions.version = .v4
        }
        return params
    }

    func start() {
        queue.async {
            guard self.transport == .quic else { return self.startCurrentConnection() }
            self.quicStartedAt = ProcessInfo.processInfo.systemUptime
            self.startQUICGroup()
            self.armFallbackTimer(extended: false)
        }
    }

    /// QUIC gets `RDQUIC.fallbackDelay` to finish its handshake (the group becomes
    /// ready); once it has, the control stream gets the same again before TCP takes over.
    private func armFallbackTimer(extended: Bool) {
        queue.asyncAfter(deadline: .now() + RDQUIC.fallbackDelay) { [weak self] in
            guard let self, self.transport == .quic, self.connection?.state != .ready else { return }
            if !extended, self.group?.state == .ready {
                self.trace("timer: handshake done, waiting for the stream")
                return self.armFallbackTimer(extended: true)
            }
            self.fallBackToTCP("not ready in time (group \(self.group.map { "\($0.state)" } ?? "none"), "
                               + "stream \(self.connection.map { "\($0.state)" } ?? "none"))")
        }
    }

    private func sendTransportNote(_ note: String) {
        write(.transportNote, RDJSON.encode(TransportNoteMsg(quicFallback: String(note.prefix(1000)))), then: nil)
    }

    private func trace(_ event: String) {
        guard transport == .quic else { return }
        let ms = Int((ProcessInfo.processInfo.systemUptime - quicStartedAt) * 1000)
        quicTrace.append("\(event) @\(ms)ms")
        ClientLog.write("quic: \(event) @\(ms)ms")
    }

    private func startQUICGroup() {
        guard let quicEndpoint else { return }
        if case .service = quicEndpoint {
            return resolveQUICService(quicEndpoint)
        }
        let group = NWConnectionGroup(with: NWMultiplexGroup(to: quicEndpoint),
                                      using: RDQUIC.clientParameters(verifyQueue: queue))
        self.group = group
        group.stateUpdateHandler = { [weak self, weak group] state in
            guard let self, let group, self.group === group, !self.isFinished else { return }
            self.trace("group \(state)")
            switch state {
            case .ready:
                self.openQUICFlows(group)
            case .failed(let error):
                if self.canFallBack { return self.fallBackToTCP("group failed: \(error)") }
                self.finish(.failed(error.localizedDescription))
            case .cancelled:
                if self.canFallBack { return self.fallBackToTCP("group cancelled") }
                self.finish(.closed)
            default:
                // `.waiting` shows up briefly even on loopback; the fallback timer decides.
                break
            }
        }
        // A group doesn't start without these handlers. The host opens no streams, and
        // video datagrams arrive on the datagram flow (NWConnection(from: group)), not here.
        group.newConnectionHandler = { $0.cancel() }
        group.setReceiveHandler(maximumMessageSize: 65_535, rejectOversizedMessages: true) { _, _, _ in }
        group.start(queue: queue)
    }

    /// Opens the control stream and the datagram flow on a ready QUIC connection.
    /// A plain UDP connection resolves the service without any handshake; its address
    /// (with the service's port, which QUIC shares) is then dialled as a group.
    private func resolveQUICService(_ service: NWEndpoint) {
        let params = NWParameters.udp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let resolver = NWConnection(to: service, using: params)
        quicResolver = resolver
        resolver.stateUpdateHandler = { [weak self, weak resolver] state in
            guard let self, let resolver, self.quicResolver === resolver,
                  self.transport == .quic, !self.isFinished else { return }
            switch state {
            case .ready:
                let remote = resolver.currentPath?.remoteEndpoint
                self.quicResolver = nil
                resolver.cancel()
                guard case .hostPort? = remote else {
                    return self.fallBackToTCP("service resolved to \(String(describing: remote))")
                }
                self.trace("resolved \(remote!)")
                self.quicEndpoint = remote
                self.startQUICGroup()
            case .failed(let error), .waiting(let error):
                self.quicResolver = nil
                resolver.cancel()
                self.fallBackToTCP("service resolve: \(error)")
            default:
                break
            }
        }
        resolver.start(queue: queue)
    }

    private func openQUICFlows(_ group: NWConnectionGroup) {
        guard connection == nil else { return }
        guard openControlStream(group) else { return }
        guard let flow = RDQUIC.makeDatagramFlow(on: group) else { return }
        datagramFlow = flow
        flow.stateUpdateHandler = { [weak self, weak flow] state in
            guard let self, let flow, self.datagramFlow === flow else { return }
            self.trace("datagram flow \(state)")
            guard case .ready = state else { return }
            self.receiveDatagram(on: flow)
            self.offerDatagramsIfReady()
        }
        flow.start(queue: queue)
    }

    /// Extracts the control stream. No options: the stream inherits the group's QUIC
    /// options and parameters (fresh stream options failed with ENETDOWN on Wi-Fi).
    private func openControlStream(_ group: NWConnectionGroup) -> Bool {
        guard let stream = group.extract() else {
            if canFallBack { fallBackToTCP("no stream from the group") }
            return false
        }
        connection = stream
        startCurrentConnection()
        return true
    }

    /// A control stream that fails before `serverHello` while its QUIC connection is
    /// still up is replaced once with a new stream on the same connection.
    private func retryControlStream(after error: NWError) -> Bool {
        guard transport == .quic, canFallBack, !streamRetried, let group, group.state == .ready else { return false }
        streamRetried = true
        trace("stream failed (\(error)), retrying")
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        ephemeralKey = nil
        reader = RDFrameReader()
        reader.maxPayload = RDService.maxHandshakePayload
        return openControlStream(group)
    }

    private func startCurrentConnection() {
        guard let current = connection else { return }
        current.stateUpdateHandler = { [weak self, weak current] state in
            guard let self, let current, self.connection === current else { return }
            self.trace("stream \(state)")
            self.handleState(state)
        }
        current.start(queue: queue)
    }

    /// Whether a failure on the current connection should switch to TCP instead of
    /// ending the attempt: only on QUIC, and only before the host has identified itself.
    private var canFallBack: Bool {
        transport == .quic && receiveCipher == nil && !isFinished
    }

    /// Drops the QUIC attempt and restarts the same attempt over TCP from scratch.
    private func fallBackToTCP(_ reason: String) {
        guard canFallBack else { return }
        quicFallbackReason = ([reason] + quicTrace).joined(separator: "; ")
        quicResolver?.stateUpdateHandler = nil
        quicResolver?.cancel()
        quicResolver = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        datagramFlow?.stateUpdateHandler = nil
        datagramFlow?.cancel()
        datagramFlow = nil
        group?.stateUpdateHandler = nil
        group?.cancel()
        group = nil
        transport = .tcp
        ephemeralKey = nil
        reader = RDFrameReader()
        reader.maxPayload = RDService.maxHandshakePayload
        connection = NWConnection(to: tcpEndpoint, using: Self.makeParameters())
        startCurrentConnection()
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
            let group = self.group
            self.write(wire, payload) {
                connection?.cancel()
                group?.cancel()
            }
            self.isFinished = true
            // Don't hang on to a connection whose peer stopped reading.
            self.queue.asyncAfter(deadline: .now() + 2) {
                connection?.cancel()
                group?.cancel()
            }
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
        diagWritten[wire, default: 0] += 1
        connection?.send(content: frame, completion: .contentProcessed { _ in completion?() })
    }

    private func handleState(_ state: NWConnection.State) {
        guard !isFinished else { return }
        switch state {
        case .ready:
            if !reportedReady {
                reportedReady = true
                onEvent(.ready(reportedRemoteEndpoint()))
            }
            sendHello()
            receive()
        case .failed(let error):
            if retryControlStream(after: error) { return }
            if canFallBack { return fallBackToTCP("stream failed: \(error)") }
            finish(.failed(error.localizedDescription))
        case .cancelled:
            if canFallBack { return fallBackToTCP("stream cancelled") }
            finish(.closed)
        case .waiting(let error):
            // An extracted QUIC stream (like its group) can pass through `waiting`
            // before it is ready; the fallback timer decides, not this state.
            if transport == .quic { return }
            if case .posix(let code) = error, code == .ECONNREFUSED || code == .EHOSTUNREACH || code == .ENETUNREACH {
                finish(.failed(error.localizedDescription))
            }
        default:
            break
        }
    }

    /// The remote endpoint as a TCP address, which is what a reconnect dials: over QUIC
    /// the UDP port may differ, so it's swapped for the TCP one when that's known.
    private func reportedRemoteEndpoint() -> NWEndpoint? {
        let remote = connection?.currentPath?.remoteEndpoint
        guard transport == .quic else { return remote }
        if case .hostPort(let host, _)? = remote, case .hostPort(_, let tcpPort) = tcpEndpoint {
            return .hostPort(host: host, port: tcpPort)
        }
        // A Bonjour service is only tried over QUIC on the same port number.
        return remote
    }

    private func finish(_ event: Event?) {
        guard !isFinished else { return }
        ClientLog.write("connection finished (\(transport)): \(event.map { "\($0)" } ?? "cancelled by app")")
        isFinished = true
        quicResolver?.cancel()
        connection?.cancel()
        datagramFlow?.cancel()
        group?.cancel()
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
        guard let current = connection else { return }
        current.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, isComplete, error in
            // A dropped QUIC attempt may still deliver a last callback; ignore it.
            guard let self, !self.isFinished, self.connection === current else { return }
            if let error {
                if self.canFallBack { return self.fallBackToTCP("receive failed: \(error)") }
                self.finish(.failed(error.localizedDescription))
                return
            }
            if let chunk, !chunk.isEmpty {
                self.reader.append(chunk)
                self.processFrames()
            }
            if isComplete {
                if self.canFallBack { return self.fallBackToTCP("host closed the stream before serverHello") }
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
                           ? .rejected("This Mac runs a different version of LocalDesktop. Update both apps.")
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
            diagReceived[wire, default: 0] += 1
            switch wire {
            case .frame:
                // Confirmed on arrival, before decoding: the host paces itself on what
                // reached the device, not on what it handed to its own network stack.
                // Stream frames are numbered by their position on the stream.
                framesReceived &+= 1
                let number = framesReceived
                if var assembler = reassembler {
                    // Datagrams took over; a stream frame older than one they delivered
                    // can't be decoded in order.
                    let fresh = assembler.noteStreamFrame(number)
                    reassembler = assembler
                    guard fresh else {
                        countLost(1)
                        requestLossKeyframe()
                        continue
                    }
                }
                sendFrameAck(number)
                onVideoFrame(plain)
            case .serverHello:
                finish(.failed("Protocol error: repeated handshake"))
            case .videoStream:
                // The host left datagrams; stream frames go on from `nextFrame`, and
                // datagrams still arriving are ignored.
                guard let msg = RDJSON.decode(VideoStreamMsg.self, from: plain) else { continue }
                reassembler = nil
                framesReceived = msg.nextFrame &- 1
                ClientLog.write("video back on the QUIC stream at frame \(msg.nextFrame)")
            case .pong:
                guard let msg = RDJSON.decode(PingMsg.self, from: plain) else { continue }
                onEvent(.pong(rttMs: max(0.5, (Date().timeIntervalSince1970 - msg.t) * 1000.0)))
            default:
                if wire == .authOK {
                    // Video and app lists can be large; lift the handshake limit before
                    // parsing whatever follows authOK in this same chunk.
                    reader.maxPayload = RDService.maxPayload
                }
                onEvent(.message(wire, plain))
                if wire == .authOK {
                    isAuthenticated = true
                    logStartupDiagnostics(remaining: 15)
                    offerDatagramsIfReady()
                    if let reason = quicFallbackReason {
                        quicFallbackReason = nil
                        sendTransportNote("fell back to TCP: \(reason)")
                    } else if transport == .quic {
                        // Video stays on the stream if the datagram flow never comes up;
                        // say why, so the host log shows it.
                        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                            guard let self, !self.isFinished, !self.offeredDatagrams else { return }
                            let flow = self.datagramFlow.map { "\($0.state)" } ?? "none"
                            self.sendTransportNote("no video datagrams (flow \(flow)): "
                                                   + self.quicTrace.joined(separator: "; "))
                        }
                    }
                }
            }
        }
    }

    private func handleServerHello(_ payload: Data) {
        guard let msg = RDJSON.decode(ServerHelloMsg.self, from: payload),
              msg.version == RDService.protocolVersion,
              let key = ephemeralKey else {
            finish(.failed("This Mac runs an incompatible version of LocalDesktop. Update both apps."))
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
        videoKey = keys.videoDatagrams
        sendCipher = RDCipher(key: keys.clientToServer)
        receiveCipher = RDCipher(key: keys.serverToClient)
        onEvent(.serverHello(ServerIdentity(serverId: msg.serverId,
                                            serverName: msg.serverName,
                                            identityKey: msg.identityKey,
                                            transcript: transcript)))
    }

    // MARK: Video datagrams

    /// After `authOK` on QUIC with a ready datagram flow: tell the host to send video
    /// as datagrams. Frames delivered on the stream so far set where numbering resumes.
    private func offerDatagramsIfReady() {
        guard !offeredDatagrams, isAuthenticated, let flow = datagramFlow, flow.state == .ready,
              let videoKey else { return }
        offeredDatagrams = true
        reassembler = RDVideoReassembler(key: videoKey, lastFrame: framesReceived)
        let reported = flow.maximumDatagramSize
        let maxSize = min(RDVideoDatagram.defaultMaxSize, reported > 0 ? reported : RDVideoDatagram.defaultMaxSize)
        write(.videoDatagrams, RDJSON.encode(VideoDatagramsMsg(maxSize: maxSize, canResumeStream: true)), then: nil)
    }

    private func receiveDatagram(on flow: NWConnection) {
        flow.receiveMessage { [weak self, weak flow] content, _, _, error in
            guard let self, let flow, !self.isFinished, self.datagramFlow === flow else { return }
            if let content, !content.isEmpty {
                self.handleDatagram(content)
            }
            if let error {
                ClientLog.write("datagram receive error: \(error)")
            } else {
                self.receiveDatagram(on: flow)
            }
        }
    }

    private func handleDatagram(_ datagram: Data) {
        diagDatagrams += 1
        guard var assembler = reassembler else { return }
        let output = assembler.receive(datagram)
        reassembler = assembler
        datagramLog.datagrams += 1
        datagramLog.frames += output.frames.count
        datagramLog.dropped += output.dropped
        if output.needsKeyframe { datagramLog.keyframeRequests += 1 }
        let now = ProcessInfo.processInfo.systemUptime
        if datagramLog.datagrams == 1 || now - datagramLog.loggedAt >= 1 {
            datagramLog.loggedAt = now
            ClientLog.write("datagrams: \(datagramLog.datagrams) in, \(datagramLog.frames) frames, "
                            + "\(datagramLog.dropped) dropped, \(datagramLog.keyframeRequests) keyframe requests")
        }
        countStats(bytes: datagram.count, isVideo: false)
        if output.dropped > 0 {
            countLost(output.dropped)
        }
        // Confirmed on arrival, before decoding, like stream frames.
        if let acked = output.acked {
            sendFrameAck(acked)
        }
        for frame in output.frames {
            countStats(bytes: 0, isVideo: true)
            onVideoFrame(frame)
        }
        if output.needsKeyframe {
            requestLossKeyframe()
        }
    }

    private var datagramLog = (datagrams: 0, frames: 0, dropped: 0, keyframeRequests: 0, loggedAt: 0.0)

    private func sendFrameAck(_ number: UInt32) {
        write(.frameAck, Data([UInt8(number >> 24), UInt8(number >> 16 & 0xFF),
                               UInt8(number >> 8 & 0xFF), UInt8(number & 0xFF)]), then: nil)
    }

    /// Asks for a keyframe after a loss, at most twice a second (the host limits too).
    private func requestLossKeyframe() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastLossKeyframeRequest > 0.5 else { return }
        lastLossKeyframeRequest = now
        write(.requestKeyframe, RDJSON.encode(RequestKeyframeMsg(reason: "loss")), then: nil)
    }

    private func countLost(_ frames: Int) {
        statsLock.lock()
        stats.lost += frames
        statsLock.unlock()
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
