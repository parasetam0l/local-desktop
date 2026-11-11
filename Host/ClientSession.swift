import CoreGraphics
import CryptoKit
import Foundation
import Network

/// One client connection on the host: performs the v2 handshake and PIN/device
/// authentication, then relays input events to InputInjector and receives video
/// frames from HostServer. The connection runs on the main queue, so every
/// callback is already on the main actor.
@MainActor
final class ClientSession {
    private enum Phase {
        case waitingHello
        case waitingAuth
        case active
        case closed
    }

    /// Time allowed to send `hello` after connecting.
    private static let helloTimeout: TimeInterval = 10
    /// Time allowed to finish authenticating, which includes the user typing the PIN.
    private static let authTimeout: TimeInterval = 120
    /// Silence tolerated from an authenticated client (it pings every 2 s).
    private static let idleTimeout: TimeInterval = 9
    /// Clients only send small messages once authenticated.
    private static let maxClientPayload = 1024 * 1024
    private static let maxPINAttemptsPerConnection = 5

    private let connection: NWConnection
    /// The QUIC connection this session's stream belongs to (nil over TCP). Video moves
    /// to its datagrams once the client sends `videoDatagrams`.
    private let quicGroup: NWConnectionGroup?
    private var videoKey: SymmetricKey?
    private var datagramFlow: NWConnection?
    private var packetizer: RDVideoPacketizer?
    private var clientMaxDatagramSize = RDVideoDatagram.defaultMaxSize
    /// Set once the datagram flow is ready; never cleared, since the client numbers
    /// stream frames by their position on the stream.
    private var videoOverDatagrams = false
    /// Unconfirmed datagram frames older than this are counted lost and stop braking.
    private static let datagramLossTimeout: TimeInterval = 0.3
    /// Datagram frames lost since the last `delivery` log line.
    private var deliveryLost = 0
    private weak var server: HostServer?
    /// The peer's IP, used to cap unauthenticated connections per address.
    let remoteAddress: String
    private var phase: Phase = .waitingHello
    private var reader = RDFrameReader()
    private var sendCipher: RDCipher?
    private var receiveCipher: RDCipher?
    private var transcript = Data()
    private var peerDeviceId = ""
    private var peerName = ""
    var peerDisplayName: String { peerName.isEmpty ? (peerDeviceId.isEmpty ? "Client" : peerDeviceId) : peerName }
    private var pinFailures = 0
    private var pinCheckInFlight = false
    private var deviceAuthAttempted = false

    // Flow control. Send completions run on the main queue, like everything else here.
    private var outgoingFrames = 0
    private var needsKeyframeRecovery = false
    private var lastKeyframeRequestAt = Date.distantPast
    private(set) var bitrateFactor: Double = 1.0
    /// Video frames sent on this connection and the count the client confirmed
    /// (`frameAck`, clients from 1.2.29). A send completion only means macOS took the
    /// bytes; its socket buffer can hold hundreds of milliseconds of video, which every
    /// later frame, pong and cursor echo then waits behind. With acks, frames in flight
    /// are counted up to the device instead.
    private var framesSent: UInt32 = 0
    private var framesAcked: UInt32 = 0
    private var clientAcksFrames = false
    private var frameSentAt = [TimeInterval](repeating: 0, count: 32)
    private var congestion = CongestionEstimator()
    /// Delivery figures summed for the log every 5 seconds, to see where lag comes from.
    private var deliveryLog = (start: 0.0, sent: 0, acked: 0, total: 0.0, min: 1.0, max: 0.0, held: 0)
    /// Limits on frames in flight to the device. A frame count alone capped the frame
    /// rate at count ÷ delivery time (3 frames at 65 ms is 45 fps), so the brake is the
    /// age of the oldest unconfirmed frame; the count only bounds a stalled link.
    private static let maxUnackedFrames: UInt32 = 8
    private static let maxUnackedAge: TimeInterval = 0.12

    // Input the client is holding down, released if the session ends mid-press.
    private var heldButtons = Set<Int>()
    private var heldKeys = Set<UInt16>()

    private var phaseStartedAt = Date()
    private var lastActivityAt = Date()
    private var watchdogTimer: Timer?

    var canSendFrame: Bool {
        guard phase == .active, outgoingFrames < 2 else { return false }
        guard clientAcksFrames else { return true }
        let unacked = framesSent &- framesAcked
        guard unacked > 0 else { return true }
        guard unacked < Self.maxUnackedFrames else { return false }
        let oldestSentAt = frameSentAt[Int((framesAcked &+ 1) % 32)]
        return ProcessInfo.processInfo.systemUptime - oldestSentAt < Self.maxUnackedAge
    }

    init(connection: NWConnection, server: HostServer, remoteAddress: String,
         quicGroup: NWConnectionGroup? = nil, initialData: Data = Data()) {
        self.connection = connection
        self.initialData = initialData
        self.quicGroup = quicGroup
        self.server = server
        self.remoteAddress = remoteAddress
        reader.maxPayload = RDService.maxHandshakePayload
    }

    /// First bytes read off a QUIC stream before the session took it (`QUICAcceptor`).
    private var initialData: Data

    func start() {
        phaseStartedAt = Date()
        lastActivityAt = Date()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkTimeouts()
            }
        }
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                self?.handleState(state)
            }
        }
        if connection.state == .setup {
            connection.start(queue: .main)
        } else {
            // A QUIC stream is handed over once it is already running (see HostServer),
            // with the bytes that showed it is the client's control stream.
            handleState(connection.state)
            if !initialData.isEmpty, phase != .closed {
                reader.append(initialData)
                initialData = Data()
                processFrames()
            }
        }
    }

    /// Ends the session. With a reason, an active client is sent `bye` first so it
    /// knows not to reconnect.
    /// The client said goodbye because its user pressed Disconnect.
    private(set) var leftOnPurpose = false

    func close(sendingBye reason: String? = nil) {
        guard phase != .closed else { return }
        if let reason, phase == .active {
            send(.bye, json: ByeMsg(reason: reason))
        }
        closeAfterFlush()
    }

    /// Ends the session but lets messages already queued (a `bye` or `authFailed`)
    /// reach the client before the socket closes.
    private func closeAfterFlush() {
        guard phase != .closed else { return }
        let connection = self.connection
        let group = quicGroup
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in
            connection.cancel()
            // Give the FIN a moment to leave before the whole QUIC connection closes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { group?.cancel() }
        })
        finish(reason: nil, cancelConnection: false)
        // Don't wait forever on a client that stopped reading.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            connection.cancel()
            group?.cancel()
        }
    }

    private func checkTimeouts() {
        let now = Date()
        switch phase {
        case .waitingHello:
            if now.timeIntervalSince(phaseStartedAt) > Self.helloTimeout {
                finish(reason: "handshake timed out")
            }
        case .waitingAuth:
            if now.timeIntervalSince(phaseStartedAt) > Self.authTimeout {
                finish(reason: "authentication timed out")
            }
        case .active:
            if now.timeIntervalSince(lastActivityAt) > Self.idleTimeout {
                finish(reason: "client timed out")
            }
        case .closed:
            break
        }
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            receiveLoop()
        case .failed(let error):
            finish(reason: error.localizedDescription)
        case .cancelled:
            finish(reason: nil)
        default:
            break
        }
    }

    private func finish(reason: String?, cancelConnection: Bool = true) {
        guard phase != .closed else { return }
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        phase = .closed
        outgoingFrames = 0
        InputInjector.release(buttons: heldButtons, keys: heldKeys)
        heldButtons.removeAll()
        heldKeys.removeAll()
        datagramFlow?.cancel()
        datagramFlow = nil
        if cancelConnection {
            connection.cancel()
            quicGroup?.cancel()
        }
        server?.sessionDidEnd(self)
    }

    // MARK: Sending

    private func send(_ wire: RDWire, _ payload: Data) {
        guard phase != .closed else { return }
        let frame: Data
        if sendCipher != nil {
            guard let sealed = try? sendCipher?.seal(wire, payload) else {
                finish(reason: "encryption failed")
                return
            }
            frame = sealed
        } else {
            frame = RDFrame.pack(wire, payload: payload)
        }
        let isVideo = wire == .frame
        if isVideo {
            outgoingFrames += 1
            framesSent &+= 1
            frameSentAt[Int(framesSent % 32)] = ProcessInfo.processInfo.systemUptime
            server?.updateFrameGate()
        }
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            MainActor.assumeIsolated {
                guard let self, self.phase != .closed else { return }
                if isVideo {
                    self.outgoingFrames = max(0, self.outgoingFrames - 1)
                    self.server?.updateFrameGate()
                }
                if let error {
                    self.finish(reason: error.localizedDescription)
                }
            }
        })
    }

    private func send<T: Encodable>(_ wire: RDWire, json message: T) {
        send(wire, RDJSON.encode(message))
    }

    private func sendAuthFailed(_ reason: String, kind: RDAuthFailure, retryAfter: Double? = nil) {
        send(.authFailed, json: AuthFailedMsg(reason: reason, kind: kind, retryAfter: retryAfter))
    }

    func sendVideoFrame(_ data: Data, isKeyframe: Bool = false, width: Int, height: Int, codec: RDCodec) {
        guard phase == .active else { return }

        // Drop non-keyframes while recovering to prevent sending corrupted P-frames
        if needsKeyframeRecovery && !isKeyframe {
            requestRecoveryKeyframe()
            return
        }

        expireLostDatagramFrames()
        guard canSendFrame else {
            deliveryLog.held += 1
            needsKeyframeRecovery = true
            requestRecoveryKeyframe()
            return
        }

        if isKeyframe {
            needsKeyframeRecovery = false
        }
        let payload = RDFrameCodec.pack(width: width, height: height, codec: codec, data: data)
        if videoOverDatagrams {
            sendVideoDatagrams(payload, isKeyframe: isKeyframe)
        } else {
            send(.frame, payload)
        }
    }

    // MARK: Video datagrams (QUIC)

    /// The client asked for video as datagrams: open this connection's datagram flow
    /// and switch once it is ready. Until then frames keep going on the stream.
    private func startVideoDatagrams(maxSize: Int) {
        guard let quicGroup, datagramFlow == nil, let videoKey,
              let identity = QUICIdentityStore.loadOrCreate(),
              let options = RDQUIC.serverDatagramFlowOptions(identity: identity),
              let flow = NWConnection(from: quicGroup, using: options) else { return }
        clientMaxDatagramSize = max(RDVideoDatagram.minPieceBody + RDVideoDatagram.overhead, maxSize)
        packetizer = RDVideoPacketizer(key: videoKey)
        datagramFlow = flow
        flow.stateUpdateHandler = { [weak self, weak flow] state in
            MainActor.assumeIsolated {
                guard let self, let flow, self.datagramFlow === flow else { return }
                switch state {
                case .ready:
                    self.videoOverDatagrams = true
                    HostLog.write("video datagrams for \(self.peerDisplayName): up to \(self.maxDatagramSize) bytes")
                case .failed(let error) where self.videoOverDatagrams:
                    // The QUIC connection itself is gone; the stream ends with it.
                    self.finish(reason: "datagram flow: \(error.localizedDescription)")
                case .failed(let error):
                    // Never came up: video simply stays on the stream.
                    HostLog.write("video datagrams for \(self.peerDisplayName) unavailable: \(error)")
                    self.datagramFlow = nil
                default:
                    break
                }
            }
        }
        flow.start(queue: .main)
    }

    private var maxDatagramSize: Int {
        let reported = datagramFlow?.maximumDatagramSize ?? 0
        return min(clientMaxDatagramSize, RDVideoDatagram.defaultMaxSize,
                   reported > 0 ? reported : RDVideoDatagram.defaultMaxSize)
    }

    /// Numbers the frame like a stream frame (same counter, same gate) and sends its pieces.
    private func sendVideoDatagrams(_ payload: Data, isKeyframe: Bool) {
        guard phase != .closed, let flow = datagramFlow, let packetizer else { return }
        framesSent &+= 1
        let number = framesSent
        frameSentAt[Int(number % 32)] = ProcessInfo.processInfo.systemUptime
        guard let datagrams = packetizer.datagrams(frame: number, payload: payload, isKeyframe: isKeyframe,
                                                   maxDatagramSize: maxDatagramSize) else {
            // Too large to send; the client sees a gap and asks for a keyframe.
            server?.updateFrameGate()
            return
        }
        outgoingFrames += 1
        server?.updateFrameGate()
        flow.batch {
            for (index, datagram) in datagrams.enumerated() {
                let isLast = index == datagrams.count - 1
                flow.send(content: datagram, completion: isLast ? .contentProcessed { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.phase != .closed else { return }
                        self.outgoingFrames = max(0, self.outgoingFrames - 1)
                        self.server?.updateFrameGate()
                    }
                } : .idempotent)
            }
        }
    }

    /// A lost datagram frame is never acked on its own; once it is old enough, count it
    /// lost so the in-flight brake doesn't wait for it forever.
    private func expireLostDatagramFrames() {
        guard videoOverDatagrams else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var expired = false
        while framesSent != framesAcked, framesSent &- framesAcked < 32,
              now - frameSentAt[Int((framesAcked &+ 1) % 32)] > Self.datagramLossTimeout {
            framesAcked &+= 1
            deliveryLost += 1
            expired = true
        }
        if expired {
            server?.updateFrameGate()
        }
    }

    /// Asks for an IDR, at most twice a second per client, so one slow client can't
    /// turn every frame into a keyframe for everyone else.
    private func logDelivery(delay: TimeInterval, frames: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        if deliveryLog.start == 0 { deliveryLog.start = now }
        deliveryLog.acked += frames
        deliveryLog.total += delay
        deliveryLog.sent += 1
        deliveryLog.min = min(deliveryLog.min, delay)
        deliveryLog.max = max(deliveryLog.max, delay)
        let elapsed = now - deliveryLog.start
        guard elapsed >= 5 else { return }
        let log = deliveryLog
        let transport = videoOverDatagrams ? "QUIC datagrams" : (quicGroup != nil ? "QUIC stream" : "TCP")
        HostLog.write(String(format: "delivery %@ (%@): %.0f fps, %.0f/%.0f/%.0f ms min/avg/max, %d held back, %d lost, bitrate ×%.2f",
                             peerDisplayName, transport, Double(log.acked) / elapsed, log.min * 1000,
                             log.total / Double(log.sent) * 1000, log.max * 1000, log.held, deliveryLost, bitrateFactor))
        deliveryLog = (now, 0, 0, 0, 1, 0, 0)
        deliveryLost = 0
    }

    private func requestRecoveryKeyframe() {
        let now = Date()
        guard now.timeIntervalSince(lastKeyframeRequestAt) > 0.5 else { return }
        lastKeyframeRequestAt = now
        ScreenStreamer.shared.requestKeyframe()
    }

    /// Whether this client wants to hear, after its clicks, if a text field has focus.
    private var wantsTextFocusReports = false
    private var textFocusCheck = 0
    /// Whether this client turned clipboard sharing on.
    private(set) var sharesClipboard = false

    private var clipboardImage = RDClipboardImageAssembler()

    /// Sends an encoded `clipboard` or a `clipboardImage` piece (see `ClipboardSync`).
    func sendClipboard(_ wire: RDWire, _ payload: Data) {
        guard phase == .active, sharesClipboard else { return }
        send(wire, payload)
    }

    func sendHostState(_ state: HostStateMsg) {
        guard phase == .active else { return }
        send(.hostState, json: state)
    }

    func sendRunningApps(_ apps: [RDRunningApp]) {
        guard phase == .active else { return }
        send(.runningApps, json: RDRunningAppsMsg(apps: apps))
    }

    func sendHardwareControls(_ controls: RDHardwareControls) {
        guard phase == .active else { return }
        send(.hardwareControlsState, json: controls)
    }

    func sendDisplays(_ message: RDDisplaysMsg) {
        guard phase == .active else { return }
        send(.displays, json: message)
    }

    // MARK: Receiving

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, self.phase != .closed else { return }
                if let error {
                    self.finish(reason: error.localizedDescription)
                    return
                }
                if let chunk, !chunk.isEmpty {
                    self.reader.append(chunk)
                    self.processFrames()
                }
                if isComplete {
                    self.finish(reason: "client disconnected")
                    return
                }
                // The only place the next receive is issued, so exactly one is ever pending.
                if self.phase != .closed {
                    self.receiveLoop()
                }
            }
        }
    }

    private func processFrames() {
        while phase != .closed {
            let frame: RDFrameData
            do {
                guard let next = try reader.nextFrame() else { return }
                frame = next
            } catch {
                finish(reason: "bad frame")
                return
            }
            var payload = frame.body
            if receiveCipher != nil {
                // Everything after `hello` is encrypted; decrypting in order keeps the counters in sync.
                guard let plain = try? receiveCipher?.open(header: frame.header, body: frame.body) else {
                    finish(reason: "decrypt failed")
                    return
                }
                payload = plain
            }
            lastActivityAt = Date()
            guard let wire = frame.wire else { continue }
            if phase == .active {
                handleActive(wire, payload: payload)
            } else {
                handleHandshake(wire, payload: payload)
            }
        }
    }

    // MARK: Handshake & authentication

    private func handleHandshake(_ wire: RDWire, payload: Data) {
        switch (phase, wire) {
        case (.waitingHello, .hello):
            handleHello(payload)
        case (.waitingAuth, .authPin):
            guard !pinCheckInFlight, let msg = RDJSON.decode(AuthPinMsg.self, from: payload) else {
                finish(reason: "bad auth")
                return
            }
            pinCheckInFlight = true
            Task {
                let result = await AuthStore.shared.checkPIN(msg.pin)
                guard self.phase == .waitingAuth else { return }
                self.pinCheckInFlight = false
                self.handlePINResult(result, request: msg)
            }
        case (.waitingAuth, .authDevice):
            guard !deviceAuthAttempted, !pinCheckInFlight,
                  let msg = RDJSON.decode(AuthDeviceMsg.self, from: payload) else {
                finish(reason: "bad auth")
                return
            }
            deviceAuthAttempted = true
            if AuthStore.shared.verifyDevice(deviceId: peerDeviceId, signature: msg.signature,
                                             message: RDHandshake.deviceProof(transcript: transcript)) {
                finishAuth(trusted: true)
            } else {
                sendAuthFailed("This device is no longer trusted. Enter the PIN.", kind: .untrusted)
            }
        case (_, .ping):
            break
        case (_, .bye):
            finish(reason: "client disconnected")
        default:
            finish(reason: "unexpected \(wire) before authentication")
        }
    }

    private func handleHello(_ payload: Data) {
        guard let msg = RDJSON.decode(HelloMsg.self, from: payload),
              !msg.deviceId.isEmpty, msg.deviceId.utf8.count <= 128 else {
            finish(reason: "bad hello")
            return
        }
        guard msg.version == RDService.protocolVersion else {
            let reason = msg.version < RDService.protocolVersion
                ? "Update LocalDesktop on this device to connect to this Mac."
                : "Update LocalDesktop on this Mac to connect from this device."
            sendAuthFailed(reason, kind: .unsupportedVersion)
            closeAfterFlush()
            return
        }

        let store = AuthStore.shared
        guard let response = RDHandshake.respond(to: msg,
                                                 identityKey: store.identityPublicKey,
                                                 serverId: store.serverId,
                                                 serverName: HostServer.computerName,
                                                 sign: store.signHandshake) else {
            finish(reason: "key exchange failed")
            return
        }
        transcript = response.transcript
        peerDeviceId = msg.deviceId
        peerName = String(msg.deviceName.prefix(100))

        send(.serverHello, json: response.serverHello)
        let keys = response.keys
        sendCipher = RDCipher(key: keys.serverToClient)
        receiveCipher = RDCipher(key: keys.clientToServer)
        videoKey = keys.videoDatagrams
        phase = .waitingAuth
        phaseStartedAt = Date()
    }

    private func handlePINResult(_ result: AuthStore.PINCheck, request: AuthPinMsg) {
        switch result {
        case .accepted:
            var trusted = false
            if request.trust, let deviceKey = request.deviceKey {
                trusted = AuthStore.shared.trust(deviceId: peerDeviceId, name: peerName, publicKey: deviceKey)
            }
            finishAuth(trusted: trusted)
        case .rejected:
            pinFailures += 1
            if pinFailures >= Self.maxPINAttemptsPerConnection {
                sendAuthFailed("Too many attempts", kind: .tooManyAttempts)
                closeAfterFlush()
            } else {
                sendAuthFailed("Incorrect PIN", kind: .incorrectPin)
            }
        case .lockedOut(let wait):
            sendAuthFailed("Too many incorrect PINs. Try again in \(Self.describe(wait)).",
                           kind: .lockedOut, retryAfter: wait)
        case .busy:
            sendAuthFailed("Another device is entering the PIN. Try again in a moment.", kind: .busy)
        }
    }

    private static func describe(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded(.up))
        if seconds < 90 { return "\(seconds) seconds" }
        return "\(Int((Double(seconds) / 60).rounded(.up))) minutes"
    }

    private func finishAuth(trusted: Bool) {
        phase = .active
        lastActivityAt = Date()
        reader.maxPayload = Self.maxClientPayload
        send(.authOK, json: AuthOKMsg(serverName: HostServer.computerName,
                                      trusted: trusted,
                                      macAddress: getPrimaryMACAddress()))
        server?.sessionDidAuthenticate(self)
    }

    // MARK: Authenticated messages

    private func handleActive(_ wire: RDWire, payload: Data) {
        switch wire {
        case .setQuality, .wakeDisplay, .requestKeyframe, .ping, .networkStats, .frameAck, .videoDatagrams, .transportNote, .bye:
            handleSessionMessage(wire, payload: payload)
        case .mouseMoveAbs, .mouseMoveRel, .mouseDown, .mouseUp, .scroll, .keyEvent, .textEvent:
            InputInjector.tickleUserActivity()
            handleInput(wire, payload: payload)
        case .requestApps, .requestFrontWindow, .activateApp, .systemAction, .getHardwareControls, .setHardwareControls, .selectDisplay,
             .setLocalInputBlock, .setSizedMirror, .setHideDock, .setTextFocusReports,
             .setClipboardSharing, .clipboard, .clipboardImage:
            handleControl(wire, payload: payload)
        default:
            break
        }
    }

    private func handleSessionMessage(_ wire: RDWire, payload: Data) {
        switch wire {
        case .setQuality:
            guard let msg = RDJSON.decode(SetQualityMsg.self, from: payload) else { return }
            server?.applyPresetFromClient(msg.preset, showRemoteCursor: msg.cursor, codec: RDCodec.from(msg.codec))

        case .wakeDisplay:
            server?.handleWakeDisplayRequest()

        case .requestKeyframe:
            let msg = RDJSON.decode(RequestKeyframeMsg.self, from: payload)
            let streamer = ScreenStreamer.shared
            streamer.requestKeyframe()
            if let keyframe = streamer.lastKeyframe, streamer.timeSinceLastFrame > 0.3 {
                sendVideoFrame(keyframe.data, isKeyframe: true, width: keyframe.width, height: keyframe.height, codec: keyframe.codec)
            }
            if msg?.reason == "user_refresh" || streamer.timeSinceLastFrame > 1.5 || !streamer.isRunning {
                server?.handleRefreshVideoRequest()
            }

        case .ping:
            guard let msg = RDJSON.decode(PingMsg.self, from: payload) else { return }
            send(.pong, json: PingMsg(t: msg.t))

        case .frameAck:
            guard payload.count >= 4 else { return }
            let count = payload.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            // Only counts that move forward and don't pass what was sent.
            let advance = count &- framesAcked
            guard advance > 0, advance <= framesSent &- framesAcked else { return }
            if videoOverDatagrams {
                // The ack is the highest frame received; numbers it skipped were lost.
                deliveryLost += Int(advance) - 1
            }
            if framesSent &- count < 32 {
                let delay = ProcessInfo.processInfo.systemUptime - frameSentAt[Int(count % 32)]
                logDelivery(delay: delay, frames: videoOverDatagrams ? 1 : Int(advance))
                if let factor = congestion.add(delay: delay, factor: bitrateFactor) {
                    bitrateFactor = factor
                    server?.updateBitrate()
                }
            }
            framesAcked = count
            clientAcksFrames = true
            server?.updateFrameGate()

        case .networkStats:
            // Clients that ack frames are measured from those acks instead.
            guard !clientAcksFrames else { return }
            guard let msg = RDJSON.decode(NetworkStatsMsg.self, from: payload) else { return }
            if msg.rttMs > 45.0 || msg.droppedFrames > 0 {
                // Wi-Fi congestion or jitter detected - scale down bitrate by 20%
                bitrateFactor = max(0.35, bitrateFactor * 0.8)
            } else if msg.rttMs < 18.0 {
                // Network is clear and fast - gradually scale up bitrate for higher fidelity
                bitrateFactor = min(1.25, bitrateFactor + 0.05)
            }
            server?.updateBitrate()

        case .transportNote:
            guard let msg = RDJSON.decode(TransportNoteMsg.self, from: payload) else { return }
            HostLog.write("QUIC: \(peerDisplayName) \(msg.quicFallback.prefix(1000))")

        case .videoDatagrams:
            guard let msg = RDJSON.decode(VideoDatagramsMsg.self, from: payload) else { return }
            startVideoDatagrams(maxSize: msg.maxSize)

        case .bye:
            leftOnPurpose = RDJSON.decode(ByeMsg.self, from: payload)?.reason == RDByeReason.userDisconnect
            finish(reason: "client disconnected")

        default:
            break
        }
    }

    private func handleInput(_ wire: RDWire, payload: Data) {
        guard let server else { return }
        let bounds = server.streamedDisplayBounds

        switch wire {
        case .mouseMoveAbs:
            guard let msg = RDJSON.decode(MouseMoveAbsMsg.self, from: payload),
                  let point = server.globalPoint(x: msg.x, y: msg.y) else { return }
            InputInjector.moveAbs(Double(point.x), Double(point.y), within: bounds)
            echoCursorPosition()

        case .mouseMoveRel:
            guard let msg = RDJSON.decode(MouseMoveRelMsg.self, from: payload) else { return }
            InputInjector.moveRel(dx: msg.dx, dy: msg.dy, within: bounds)
            echoCursorPosition()

        case .mouseDown:
            guard let msg = RDJSON.decode(MouseButtonMsg.self, from: payload), (0...1).contains(msg.button) else { return }
            heldButtons.insert(msg.button)
            InputInjector.buttonDown(msg.button)

        case .mouseUp:
            guard let msg = RDJSON.decode(MouseButtonMsg.self, from: payload), (0...1).contains(msg.button) else { return }
            heldButtons.remove(msg.button)
            InputInjector.buttonUp(msg.button)
            if wantsTextFocusReports, msg.button == 0 {
                textFocusCheck += 1
                let check = textFocusCheck
                TextFocusProbe.check { [weak self] editable in
                    // Only the latest click's answer counts.
                    guard let self, self.textFocusCheck == check, self.phase == .active else { return }
                    self.send(.textFocus, json: RDTextFocusMsg(editable: editable))
                }
            }

        case .scroll:
            guard let msg = RDJSON.decode(ScrollMsg.self, from: payload) else { return }
            InputInjector.scroll(dx: msg.dx, dy: msg.dy, precise: msg.precise ?? false)

        case .keyEvent:
            guard let msg = RDJSON.decode(KeyEventMsg.self, from: payload), msg.code < 128 else { return }
            if msg.down {
                heldKeys.insert(msg.code)
            } else {
                heldKeys.remove(msg.code)
            }
            InputInjector.key(code: CGKeyCode(msg.code),
                              down: msg.down,
                              flags: InputInjector.flags(RDModifiers(rawValue: msg.flags)))
            if msg.down, msg.code == RDKey.capsLock.rawValue { server.capsLockMayHaveChanged() }

        case .textEvent:
            guard let msg = RDJSON.decode(TextMsg.self, from: payload) else { return }
            InputInjector.text(msg.s)

        default:
            break
        }
    }

    private func echoCursorPosition() {
        if let cur = server?.currentCursorInFrame() {
            send(.mouseMoveAbs, json: MouseMoveAbsMsg(x: cur.x, y: cur.y))
        }
    }

    private func handleControl(_ wire: RDWire, payload: Data) {
        guard let server else { return }
        switch wire {
        case .requestApps:
            sendRunningApps(server.appSwitcher.runningApps())

        case .requestFrontWindow:
            WindowActions.describe { [weak self] window in
                guard let self, self.phase == .active else { return }
                self.send(.frontWindow, json: window)
            }

        case .activateApp:
            guard let msg = RDJSON.decode(RDActivateAppMsg.self, from: payload) else { return }
            server.appSwitcher.activate(bundleId: msg.bundleId)

        case .systemAction:
            guard let msg = RDJSON.decode(RDSystemActionMsg.self, from: payload) else { return }
            switch msg.action {
            case .showDesktop:
                server.toggleShowDesktop()
            case .missionControl:
                _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/open"), arguments: ["-a", "Mission Control"])
            case .launchpad:
                _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/open"), arguments: ["-a", "Launchpad"])
            case .lockScreen:
                HardwareController.lockScreen()
            case .windowClose, .windowMinimize, .windowFullScreen, .windowLeftHalf, .windowRightHalf, .windowFill:
                WindowActions.perform(msg.action) { [weak self] window in
                    guard let self, self.phase == .active else { return }
                    self.send(.frontWindow, json: window)
                }
            }

        case .getHardwareControls:
            sendHardwareControls(HardwareController.getState())

        case .setHardwareControls:
            guard let msg = RDJSON.decode(RDSetHardwareControlsMsg.self, from: payload) else { return }
            if let b = msg.brightness {
                HardwareController.setBrightness(b)
            }
            if let v = msg.volume {
                HardwareController.setVolume(v)
            }
            if let m = msg.isMuted {
                HardwareController.setMuted(m)
            }
            if msg.sleepDisplay == true {
                HardwareController.sleepDisplay()
            }
            if msg.lockScreen == true {
                HardwareController.lockScreen()
            }
            sendHardwareControls(HardwareController.getState())

        case .selectDisplay:
            guard let msg = RDJSON.decode(RDSelectDisplayMsg.self, from: payload) else { return }
            server.setDisplay(msg.id)

        case .setTextFocusReports:
            guard let msg = RDJSON.decode(RDSetTextFocusReportsMsg.self, from: payload) else { return }
            wantsTextFocusReports = msg.enabled

        case .setClipboardSharing:
            guard let msg = RDJSON.decode(RDSetClipboardSharingMsg.self, from: payload) else { return }
            sharesClipboard = msg.enabled
            if !sharesClipboard { clipboardImage.reset() }
            server.clipboard.update()

        case .clipboard:
            guard sharesClipboard, let msg = RDJSON.decode(RDClipboardMsg.self, from: payload) else { return }
            server.clipboard.receive(.text(msg.text), from: self)

        case .clipboardImage:
            guard sharesClipboard, let png = clipboardImage.add(payload) else { return }
            server.clipboard.receive(.image(png), from: self)

        case .setHideDock:
            guard let msg = RDJSON.decode(RDSetHideDockMsg.self, from: payload) else { return }
            server.setHidesDock(msg.enabled)
            sendHostState(server.hostStateMessage)

        case .setSizedMirror:
            guard let msg = RDJSON.decode(RDSetSizedMirrorMsg.self, from: payload) else { return }
            server.setSizedMirror(msg.size)
            // Tells the client the outcome even when nothing changed (e.g. it failed).
            sendDisplays(server.displaysMessage)

        case .setLocalInputBlock:
            guard let msg = RDJSON.decode(RDSetLocalInputBlockMsg.self, from: payload) else { return }
            server.setBlocksLocalInput(msg.enabled)
            // Confirms the setting even when it didn't change.
            sendHostState(server.hostStateMessage)

        default:
            break
        }
    }
}
