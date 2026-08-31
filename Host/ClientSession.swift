import Foundation
import Network
import CryptoKit
import CoreGraphics
import AppKit

/// One client connection on the host: performs the ECDH handshake and
/// PIN/token authentication, then relays input events to InputInjector and
/// receives video frames from HostServer. Everything runs on the main queue.
@MainActor
final class ClientSession {
    private enum Phase {
        case waitingHello
        case waitingAuth
        case active
        case closed
    }

    private let connection: NWConnection
    private weak var server: HostServer?
    private var phase: Phase = .waitingHello
    private var key: SymmetricKey?
    private var peerDeviceId = ""
    private var peerName = ""
    var peerDisplayName: String { peerName.isEmpty ? (peerDeviceId.isEmpty ? "Client" : peerDeviceId) : peerName }
    private var pinFailures = 0
    private let sendLock = NSLock()
    private var _outgoingFrames = 0
    var outgoingFrames: Int {
        sendLock.lock()
        defer { sendLock.unlock() }
        return _outgoingFrames
    }

    private(set) var framesSent = 0
    private(set) var framesDropped = 0
    private var consecutiveDrops = 0
    private var currentBitrateFactor: Double = 1.0
    private var lastActivityAt = Date()
    private var watchdogTimer: Timer?

    var canSendFrame: Bool {
        guard phase == .active else { return false }
        sendLock.lock()
        defer { sendLock.unlock() }
        return _outgoingFrames < 2
    }

    init(connection: NWConnection, server: HostServer) {
        self.connection = connection
        self.server = server
    }

    func start() {
        lastActivityAt = Date()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase != .closed else { return }
                if Date().timeIntervalSince(self.lastActivityAt) > 9.0 {
                    self.finish(reason: "client timed out")
                }
            }
        }
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleState(state)
            }
        }
        connection.start(queue: .main)
    }

    func close() {
        finish(reason: nil)
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

    private func finish(reason: String?) {
        guard phase != .closed else { return }
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        phase = .closed
        sendLock.lock()
        _outgoingFrames = 0
        sendLock.unlock()
        connection.cancel()
        server?.sessionDidEnd(self)
    }

    // MARK: Sending

    private func send(_ wire: RDWire, _ payload: Data, encrypted: Bool) {
        guard phase != .closed else { return }
        var data = payload
        if encrypted {
            guard let key, let sealed = RDCrypto.seal(data, key: key) else { return }
            data = sealed
        }
        if wire == .frame {
            sendLock.lock()
            _outgoingFrames += 1
            sendLock.unlock()
        }
        connection.send(content: RDFrame.pack(wire, payload: data),
                        contentContext: .defaultMessage,
                        isComplete: false,
                        completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if wire == .frame {
                self.sendLock.lock()
                self._outgoingFrames = max(0, self._outgoingFrames - 1)
                self.sendLock.unlock()
            }
            if let error {
                self.finish(reason: error.localizedDescription)
            }
        })
    }

    func sendVideoFrame(_ data: Data, width: Int, height: Int, codec: RDCodec) {
        guard phase == .active else { return }
        guard canSendFrame else {
            framesDropped += 1
            return
        }
        framesSent += 1
        send(.frame, RDFrameCodec.pack(width: width, height: height, codec: codec, data: data), encrypted: true)
    }

    func sendFrame(_ jpeg: Data, width: Int, height: Int) {
        // Drop frames when the network can't keep up instead of queueing them.
        guard phase == .active else { return }
        guard canSendFrame else {
            framesDropped += 1
            return
        }
        framesSent += 1
        send(.frame, RDFrameCodec.pack(width: width, height: height, codec: .jpeg, data: jpeg), encrypted: true)
    }

    func sendHostState(_ state: HostStateMsg) {
        guard phase == .active else { return }
        send(.hostState, RDJSON.encode(state), encrypted: true)
    }

    func sendRunningApps(_ apps: [RDRunningApp]) {
        guard phase == .active else { return }
        send(.runningApps, RDJSON.encode(RDRunningAppsMsg(apps: apps)), encrypted: true)
    }

    // MARK: Receiving

    private var receiveBuffer = Data()

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, isComplete, error in
            Task { @MainActor in
                guard let self, self.phase != .closed else { return }
                if let error {
                    self.finish(reason: error.localizedDescription)
                    return
                }
                if let chunk, !chunk.isEmpty {
                    self.receiveBuffer.append(chunk)
                    self.processReceiveBuffer()
                }
                if isComplete {
                    self.finish(reason: "client disconnected")
                    return
                }
                if self.phase != .closed {
                    self.receiveLoop()
                }
            }
        }
    }

    private func processReceiveBuffer() {
        while receiveBuffer.count >= RDFrame.headerLength {
            guard let (wire, length) = RDFrame.unpackHeader(receiveBuffer) else {
                finish(reason: "bad header")
                return
            }
            let totalLength = RDFrame.headerLength + length
            guard receiveBuffer.count >= totalLength else { break }
            let payload = receiveBuffer.subdata(in: RDFrame.headerLength..<totalLength)
            receiveBuffer.removeSubrange(0..<totalLength)
            lastActivityAt = Date()
            handle(wire, payload: payload)
        }
    }

    private func handle(_ wire: RDWire, payload rawPayload: Data) {
        guard phase != .closed else { return }
        var payload = rawPayload
        if phase == .active || wire == .authPin || wire == .authToken {
            guard let key, let plain = RDCrypto.open(payload, key: key) else {
                finish(reason: "decrypt failed")
                return
            }
            payload = plain
        }

        switch wire {
        case .hello:
            guard phase == .waitingHello,
                  let msg = RDJSON.decode(HelloMsg.self, from: payload),
                  msg.version == RDService.protocolVersion else {
                finish(reason: "bad hello")
                return
            }
            let privateKey = RDCrypto.makePrivateKey()
            guard let sessionKey = RDCrypto.sessionKey(privateKey: privateKey, peerPublicKey: msg.pubKey) else {
                finish(reason: "key exchange failed")
                return
            }
            key = sessionKey
            peerDeviceId = msg.deviceId
            peerName = msg.deviceName
            phase = .waitingAuth
            let response = ServerHelloMsg(serverId: AuthStore.shared.serverId,
                                          serverName: HostServer.computerName,
                                          pubKey: privateKey.publicKey.rawRepresentation,
                                          requiresPin: true,
                                          macAddress: getPrimaryMACAddress())
            send(.serverHello, RDJSON.encode(response), encrypted: false)

        case .authPin:
            guard phase == .waitingAuth, let msg = RDJSON.decode(AuthPinMsg.self, from: payload) else {
                finish(reason: "bad auth")
                return
            }
            if AuthStore.shared.verifyPIN(msg.pin) {
                finishAuth(trustRequested: msg.trust, alreadyTrusted: false)
            } else {
                pinFailures += 1
                if pinFailures >= 5 {
                    send(.authFailed, RDJSON.encode(AuthFailedMsg(reason: "Too many attempts")), encrypted: false)
                    finish(reason: nil)
                    return
                } else {
                    send(.authFailed, RDJSON.encode(AuthFailedMsg(reason: "Incorrect PIN")), encrypted: false)
                }
            }

        case .authToken:
            guard phase == .waitingAuth, let msg = RDJSON.decode(AuthTokenMsg.self, from: payload) else {
                finish(reason: "bad auth")
                return
            }
            if AuthStore.shared.validate(deviceId: peerDeviceId, token: msg.token) {
                finishAuth(trustRequested: false, alreadyTrusted: true)
            } else {
                send(.authFailed,
                     RDJSON.encode(AuthFailedMsg(reason: "This device is no longer trusted. Enter the PIN.")),
                     encrypted: false)
            }

        case .setQuality:
            guard phase == .active, let msg = RDJSON.decode(SetQualityMsg.self, from: payload) else { break }
            server?.applyPresetFromClient(msg.preset, showRemoteCursor: msg.cursor, codec: msg.codec)

        case .wakeDisplay:
            guard phase == .active else { break }
            server?.handleWakeDisplayRequest()

        case .requestKeyframe:
            guard phase == .active else { break }
            let msg = RDJSON.decode(RequestKeyframeMsg.self, from: payload)
            ScreenStreamer.shared.requestKeyframe()
            if msg?.reason == "user_refresh" || ScreenStreamer.shared.timeSinceLastFrame > 1.5 || !ScreenStreamer.shared.isRunning {
                server?.handleRefreshVideoRequest()
            }

        case .ping:
            guard phase == .active, let msg = RDJSON.decode(PingMsg.self, from: payload) else { break }
            send(.pong, RDJSON.encode(PingMsg(t: msg.t)), encrypted: true)

        case .networkStats:
            guard phase == .active, let msg = RDJSON.decode(NetworkStatsMsg.self, from: payload) else { break }
            handleNetworkStats(msg)

        case .bye:
            finish(reason: "client disconnected")

        case .mouseMoveAbs:
            guard phase == .active, let msg = RDJSON.decode(MouseMoveAbsMsg.self, from: payload) else { break }
            if let point = server?.globalPoint(x: msg.x, y: msg.y) {
                InputInjector.moveAbs(Double(point.x), Double(point.y))
                if let cur = server?.currentCursorInFrame() {
                    send(.mouseMoveAbs, RDJSON.encode(MouseMoveAbsMsg(x: cur.x, y: cur.y)), encrypted: true)
                }
            }

        case .mouseMoveRel:
            guard phase == .active, let msg = RDJSON.decode(MouseMoveRelMsg.self, from: payload) else { break }
            InputInjector.moveRel(dx: msg.dx, dy: msg.dy)
            if let cur = server?.currentCursorInFrame() {
                send(.mouseMoveAbs, RDJSON.encode(MouseMoveAbsMsg(x: cur.x, y: cur.y)), encrypted: true)
            }

        case .mouseDown:
            guard phase == .active, let msg = RDJSON.decode(MouseButtonMsg.self, from: payload) else { break }
            InputInjector.buttonDown(msg.button)

        case .mouseUp:
            guard phase == .active, let msg = RDJSON.decode(MouseButtonMsg.self, from: payload) else { break }
            InputInjector.buttonUp(msg.button)

        case .scroll:
            guard phase == .active, let msg = RDJSON.decode(ScrollMsg.self, from: payload) else { break }
            InputInjector.scroll(dx: msg.dx, dy: msg.dy)

        case .keyEvent:
            guard phase == .active, let msg = RDJSON.decode(KeyEventMsg.self, from: payload) else { break }
            InputInjector.key(code: CGKeyCode(msg.code),
                              down: msg.down,
                              flags: InputInjector.flags(RDModifiers(rawValue: msg.flags)))

        case .textEvent:
            guard phase == .active, let msg = RDJSON.decode(TextMsg.self, from: payload) else { break }
            InputInjector.text(msg.s)

        case .requestApps:
            guard phase == .active, let server else { break }
            sendRunningApps(server.getRunningApps())

        case .activateApp:
            guard phase == .active, let msg = RDJSON.decode(RDActivateAppMsg.self, from: payload) else { break }
            server?.didActivateApp(bundleId: msg.bundleId)
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: msg.bundleId).first {
                if app.isHidden {
                    app.unhide()
                }
                app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
                if let bundleURL = app.bundleURL {
                    let config = NSWorkspace.OpenConfiguration()
                    config.activates = true
                    config.addsToRecentItems = false
                    NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in }
                }
            }

        case .systemAction:
            guard phase == .active, let msg = RDJSON.decode(RDSystemActionMsg.self, from: payload) else { break }
            switch msg.action {
            case .showDesktop:
                server?.toggleShowDesktop()
            case .missionControl:
                let _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/open"), arguments: ["-a", "Mission Control"])
            case .launchpad:
                let _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/open"), arguments: ["-a", "Launchpad"])
            case .lockScreen:
                InputInjector.key(code: 12, down: true, flags: [.maskControl, .maskCommand])
                InputInjector.key(code: 12, down: false, flags: [.maskControl, .maskCommand])
            }

        default:
            break
        }

        if phase != .closed {
            receiveLoop()
        }
    }

    private func handleNetworkStats(_ stats: NetworkStatsMsg) {
        let currentPreset = server?.preset ?? .balanced
        let baseBitrate = currentPreset.targetBitrate

        if stats.rttMs > 45.0 || stats.droppedFrames > 0 {
            // Wi-Fi congestion or jitter detected - scale down bitrate by 20%
            currentBitrateFactor = max(0.35, currentBitrateFactor * 0.8)
        } else if stats.rttMs < 18.0 && stats.droppedFrames == 0 {
            // Network is clear and fast - gradually scale up bitrate for higher fidelity
            currentBitrateFactor = min(1.25, currentBitrateFactor + 0.05)
        }
        let dynamicBitrate = Int(Double(baseBitrate) * currentBitrateFactor)
        ScreenStreamer.shared.setDynamicBitrate(dynamicBitrate)
    }

    private func finishAuth(trustRequested: Bool, alreadyTrusted: Bool) {
        var token: Data?
        if !alreadyTrusted, trustRequested {
            token = AuthStore.shared.issueToken(for: peerDeviceId, name: peerName)
        }
        phase = .active
        let ok = AuthOKMsg(serverName: HostServer.computerName,
                           trusted: alreadyTrusted || token != nil,
                           token: token)
        send(.authOK, RDJSON.encode(ok), encrypted: true)
        server?.sessionDidAuthenticate(self, name: peerName)
    }
}
