import Foundation
import Network
import CryptoKit
import CoreGraphics

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

    // Input the client is holding down, released if the session ends mid-press.
    private var heldButtons = Set<Int>()
    private var heldKeys = Set<UInt16>()

    private var phaseStartedAt = Date()
    private var lastActivityAt = Date()
    private var watchdogTimer: Timer?

    var canSendFrame: Bool { phase == .active && outgoingFrames < 2 }

    init(connection: NWConnection, server: HostServer, remoteAddress: String) {
        self.connection = connection
        self.server = server
        self.remoteAddress = remoteAddress
        reader.maxPayload = RDService.maxHandshakePayload
    }

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
        connection.start(queue: .main)
    }

    /// Ends the session. With a reason, an active client is sent `bye` first so it
    /// knows not to reconnect.
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
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
        finish(reason: nil, cancelConnection: false)
        // Don't wait forever on a client that stopped reading.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            connection.cancel()
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
        if cancelConnection {
            connection.cancel()
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

        guard canSendFrame else {
            needsKeyframeRecovery = true
            requestRecoveryKeyframe()
            return
        }

        if isKeyframe {
            needsKeyframeRecovery = false
        }
        send(.frame, RDFrameCodec.pack(width: width, height: height, codec: codec, data: data))
    }

    /// Asks for an IDR, at most twice a second per client, so one slow client can't
    /// turn every frame into a keyframe for everyone else.
    private func requestRecoveryKeyframe() {
        let now = Date()
        guard now.timeIntervalSince(lastKeyframeRequestAt) > 0.5 else { return }
        lastKeyframeRequestAt = now
        ScreenStreamer.shared.requestKeyframe()
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
        server?.sessionDidAuthenticate(self, name: peerName)
    }

    // MARK: Authenticated messages

    private func handleActive(_ wire: RDWire, payload: Data) {
        switch wire {
        case .setQuality, .wakeDisplay, .requestKeyframe, .ping, .networkStats, .bye:
            handleSessionMessage(wire, payload: payload)
        case .mouseMoveAbs, .mouseMoveRel, .mouseDown, .mouseUp, .scroll, .keyEvent, .textEvent:
            InputInjector.tickleUserActivity()
            handleInput(wire, payload: payload)
        case .requestApps, .activateApp, .systemAction, .getHardwareControls, .setHardwareControls, .selectDisplay,
             .setLocalInputBlock:
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

        case .networkStats:
            guard let msg = RDJSON.decode(NetworkStatsMsg.self, from: payload) else { return }
            if msg.rttMs > 45.0 || msg.droppedFrames > 0 {
                // Wi-Fi congestion or jitter detected - scale down bitrate by 20%
                bitrateFactor = max(0.35, bitrateFactor * 0.8)
            } else if msg.rttMs < 18.0 {
                // Network is clear and fast - gradually scale up bitrate for higher fidelity
                bitrateFactor = min(1.25, bitrateFactor + 0.05)
            }
            server?.updateBitrate()

        case .bye:
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
