import Foundation
import Network
import CryptoKit
import CoreMedia
import UIKit

/// Client side of one local-desktop session: connect, handshake, PIN/token
/// auth, frame decoding, and input event sending.
@MainActor
final class ClientSession: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting
        case negotiating
        case needPin
        case connected
        case failed(String, Int?)
        case closed
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var image: UIImage?
    @Published private(set) var hasVideoFrame = false
    @Published private(set) var remoteSize: CGSize = .zero
    @Published private(set) var serverName = ""
    private(set) var serverMacAddress: String?
    @Published private(set) var serverId = ""
    @Published private(set) var hostDescription = ""
    @Published private(set) var pinError: String?
    @Published private(set) var pinAttemptCounter = 0
    @Published private(set) var videoStatus: String?
    @Published private(set) var isHostLocked = false
    @Published private(set) var isDisplaySleeping = false
    private(set) var framesReceived = 0

    let deviceName: String
    var onConnected: ((ClientSession) -> Void)?
    var onEnded: ((ClientSession) -> Void)?
    var onCursorMoved: ((CGPoint) -> Void)?
    var onSampleBuffer: ((CMSampleBuffer, Int, Int) -> Void)?

    private let videoDecoder = VideoDecoder()
    private var lastKeyframeRequestAt = Date.distantPast

    private(set) var endpoint: NWEndpoint?
    private var actualEndpoint: NWEndpoint?
    private var connection: NWConnection?
    private var privateKey: Curve25519.KeyAgreement.PrivateKey?
    private var key: SymmetricKey?
    private let keyLock = NSLock()
    private var _sessionKey: SymmetricKey?
    private let networkQueue = DispatchQueue(label: "rd.client.network", qos: .userInteractive)
    private let decodeQueue = DispatchQueue(label: "rd.client.decode", qos: .userInteractive)
    private var receiveBuffer = Data()
    private var pingTimer: Timer?
    private var connectionTimeoutTask: Task<Void, Never>?
    private var lastPongAt = Date()
    private(set) var hasConnectedOnce = false
    private(set) var userInitiatedDisconnect = false
    private var consecutiveFailures = 0
    var autoReconnect = true

    init(deviceName: String) {
        self.deviceName = deviceName
    }

    var currentEndpoint: NWEndpoint? { actualEndpoint ?? endpoint }
    var canReconnect: Bool { currentEndpoint != nil && hasConnectedOnce }

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

    // MARK: Connection lifecycle

    func connect(to target: NWEndpoint, preserveImage: Bool = false) {
        userInitiatedDisconnect = false
        connectionTimeoutTask?.cancel()
        stopPing()
        if !preserveImage {
            image = nil
            remoteSize = .zero
            consecutiveFailures = 0
        }
        videoStatus = nil
        serverName = ""
        serverId = ""
        key = nil
        keyLock.lock()
        _sessionKey = nil
        keyLock.unlock()
        privateKey = nil
        pinError = nil
        endpoint = target
        actualEndpoint = nil
        hostDescription = describe(target)
        phase = .connecting
        networkQueue.async { [weak self] in
            self?.receiveBuffer.removeAll()
        }

        // Safety timeout so the UI never hangs indefinitely while connecting/negotiating
        connectionTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self, self.phase == .connecting || self.phase == .negotiating else { return }
            self.fail("Connection timed out. Check that the Mac and iPhone are on the same Wi-Fi network.")
        }

        let conn = NWConnection(to: target, using: Self.makeParameters())
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.stateChanged(state)
            }
        }
        conn.start(queue: networkQueue)
    }

    func reconnect() {
        guard let target = currentEndpoint else { return }
        connect(to: target, preserveImage: true)
    }

    func disconnect() {
        userInitiatedDisconnect = true
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        stopPing()
        keyLock.lock()
        _sessionKey = nil
        keyLock.unlock()
        networkQueue.async { [weak self] in
            self?.receiveBuffer.removeAll()
        }
        send(.bye, RDJSON.encode(ByeMsg(reason: "user disconnect")), encrypted: phase == .connected)
        connection?.cancel()
        phase = .closed
        onEnded?(self)
    }

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            connectionTimeoutTask?.cancel()
            connectionTimeoutTask = nil
            actualEndpoint = connection?.currentPath?.remoteEndpoint ?? endpoint
            phase = .negotiating
            sendHello()
            startReceiveLoop()
        case .failed(let error):
            connectionTimeoutTask?.cancel()
            connectionTimeoutTask = nil
            fail(error.localizedDescription)
        case .cancelled:
            connectionTimeoutTask?.cancel()
            connectionTimeoutTask = nil
            guard !isDead else { return }
            if !userInitiatedDisconnect && autoReconnect {
                fail("Connection closed by host")
            } else if hasConnectedOnce, !userInitiatedDisconnect {
                phase = .closed
                onEnded?(self)
            } else if !userInitiatedDisconnect, !hasConnectedOnce {
                fail("Connection closed")
            }
        case .waiting(let error):
            if case .posix(let code) = error, code == .ECONNREFUSED || code == .EHOSTUNREACH || code == .ENETUNREACH {
                connectionTimeoutTask?.cancel()
                connectionTimeoutTask = nil
                fail(error.localizedDescription)
            }
        default:
            break
        }
    }

    @Published private(set) var reconnectCountdown: Int?
    private var countdownTimer: Timer?

    private func fail(_ reason: String) {
        guard !isDead else { return }
        
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        stopPing()
        
        countdownTimer?.invalidate()
        countdownTimer = nil
        reconnectCountdown = nil
        
        keyLock.lock()
        _sessionKey = nil
        keyLock.unlock()
        
        networkQueue.async { [weak self] in
            self?.receiveBuffer.removeAll()
        }
        
        connection?.cancel()

        consecutiveFailures += 1
        let waitTime = consecutiveFailures <= 1 ? 1 : 5

        if canReconnect && autoReconnect && !userInitiatedDisconnect {
            phase = .failed(reason, waitTime)
            countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
                Task { @MainActor in
                    guard let self else { return }
                    if case .failed(let msg, let current) = self.phase, let current = current, current > 1 {
                        self.phase = .failed(msg, current - 1)
                    } else {
                        timer.invalidate()
                        self.countdownTimer = nil
                        if case .failed = self.phase {
                            self.reconnect()
                        }
                    }
                }
            }
        } else {
            phase = .failed(reason, nil)
        }
    }

    private var isDead: Bool {
        if case .failed = phase { return true }
        if case .closed = phase { return true }
        return false
    }

    // MARK: Handshake

    private func sendHello() {
        let priv = RDCrypto.makePrivateKey()
        privateKey = priv
        let hello = HelloMsg(deviceId: TrustStore.deviceId,
                             deviceName: deviceName,
                             pubKey: priv.publicKey.rawRepresentation)
        send(.hello, RDJSON.encode(hello), encrypted: false)
    }

    /// PIN entry from the UI. Requests a trust token so future connections skip the PIN.
    func submitPIN(_ pin: String, trust: Bool) {
        guard phase == .needPin else { return }
        pinError = nil
        pinAttemptCounter += 1
        phase = .negotiating
        send(.authPin, RDJSON.encode(AuthPinMsg(pin: pin, trust: trust)), encrypted: true)
    }

    // MARK: Receiving

    private func startReceiveLoop() {
        networkQueue.async { [weak self] in
            self?.readNextChunk()
        }
    }

    private func readNextChunk() {
        guard let conn = connection else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            if let error {
                Task { @MainActor in
                    self.fail(error.localizedDescription)
                }
                return
            }
            if let chunk, !chunk.isEmpty {
                self.receiveBuffer.append(chunk)
                self.processReceiveBuffer()
            }
            if isComplete {
                Task { @MainActor in
                    self.fail("Connection closed by host")
                }
                return
            }
            self.readNextChunk()
        }
    }

    private func processReceiveBuffer() {
        while receiveBuffer.count >= RDFrame.headerLength {
            guard let (wire, length) = RDFrame.unpackHeader(receiveBuffer) else {
                Task { @MainActor in
                    self.fail("Protocol error: corrupted header")
                }
                return
            }
            let totalLength = RDFrame.headerLength + length
            guard receiveBuffer.count >= totalLength else { break }
            let payload = receiveBuffer.subdata(in: RDFrame.headerLength..<totalLength)
            receiveBuffer.removeSubrange(0..<totalLength)
            dispatchPayload(wire, payload: payload)
        }
    }

    private func dispatchPayload(_ wire: RDWire, payload: Data) {
        if wire == .frame {
            keyLock.lock()
            let sessionKey = _sessionKey
            keyLock.unlock()
            guard let sessionKey else { return }
            decodeQueue.async { [weak self] in
                guard let self else { return }
                guard let plain = RDCrypto.open(payload, key: sessionKey) else { return }
                guard let (width, height, codec, frameData) = RDFrameCodec.unpack(plain) else { return }

                switch codec {
                case .h264, .hevc:
                    self.videoDecoder.decode(annexB: frameData, codec: codec) { [weak self] sampleBuffer in
                        guard let self else { return }
                        self.onSampleBuffer?(sampleBuffer, width, height)
                        Task { @MainActor in
                            guard self.phase == .connected else { return }
                            self.framesReceived += 1
                            self.videoStatus = nil
                            if self.remoteSize.width != CGFloat(width) || self.remoteSize.height != CGFloat(height) {
                                self.remoteSize = CGSize(width: width, height: height)
                            }
                            if !self.hasVideoFrame {
                                self.hasVideoFrame = true
                            }
                        }
                    } onError: { [weak self] in
                        Task { @MainActor in
                            self?.requestKeyframe(reason: "missing_headers_or_corrupted")
                        }
                    }
                case .jpeg:
                    guard let decoded = UIImage(data: frameData) else { return }
                    Task { @MainActor in
                        guard self.phase == .connected else { return }
                        self.framesReceived += 1
                        self.videoStatus = nil
                        self.remoteSize = CGSize(width: width, height: height)
                        self.hasVideoFrame = true
                        self.image = decoded
                    }
                }
            }
        } else {
            Task { @MainActor in
                self.handleControlMessage(wire, payload: payload)
            }
        }
    }

    private func handleControlMessage(_ wire: RDWire, payload: Data) {
        guard !isDead else { return }

        switch wire {
        case .serverHello:
            guard let msg = RDJSON.decode(ServerHelloMsg.self, from: payload),
                  let priv = privateKey,
                  let sessionKey = RDCrypto.sessionKey(privateKey: priv, peerPublicKey: msg.pubKey) else {
                fail("Handshake failed")
                return
            }
            key = sessionKey
            keyLock.lock()
            _sessionKey = sessionKey
            keyLock.unlock()
            serverName = msg.serverName
            serverId = msg.serverId
            serverMacAddress = msg.macAddress

            if let token = TrustStore.token(serverId: msg.serverId) {
                phase = .negotiating
                send(.authToken, RDJSON.encode(AuthTokenMsg(token: token)), encrypted: true)
            } else {
                phase = .needPin
            }

        case .authOK:
            guard let key, let plain = RDCrypto.open(payload, key: key),
                  let msg = RDJSON.decode(AuthOKMsg.self, from: plain) else {
                fail("Bad auth response")
                return
            }
            phase = .connected
            hasConnectedOnce = true
            consecutiveFailures = 0
            stopPing()
            lastPongAt = Date()
            pingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.phase == .connected else { return }
                    if Date().timeIntervalSince(self.lastPongAt) > 8.0 {
                        self.fail("Connection lost (no heartbeat)")
                        return
                    }
                    self.send(.ping, RDJSON.encode(PingMsg(t: Date().timeIntervalSince1970)), encrypted: true)
                }
            }
            if let token = msg.token, !serverId.isEmpty {
                TrustStore.setToken(token, serverId: serverId)
            }
            onConnected?(self)

        case .authFailed:
            let plain = key.flatMap { RDCrypto.open(payload, key: $0) } ?? payload
            if let msg = RDJSON.decode(AuthFailedMsg.self, from: plain) {
                pinError = msg.reason
            } else {
                pinError = "Incorrect PIN"
            }
            pinAttemptCounter += 1
            phase = .needPin

        case .pong:
            lastPongAt = Date()

        case .hostState:
            guard let key, let plain = RDCrypto.open(payload, key: key),
                  let msg = RDJSON.decode(HostStateMsg.self, from: plain) else { break }
            isHostLocked = msg.isLocked
            isDisplaySleeping = msg.isDisplaySleeping

        case .bye:
            fail("The Mac ended the session")

        default:
            break
        }
    }

    // MARK: Keepalive

    private func startPing() {
        lastPongAt = Date()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .connected else { return }
                if Date().timeIntervalSince(self.lastPongAt) > 16 {
                    self.fail("Lost connection to the Mac")
                    return
                }
                self.send(.ping, RDJSON.encode(PingMsg(t: Date().timeIntervalSince1970)), encrypted: true)
            }
        }
    }

    private func stopPing() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    // MARK: Input

    private func send(_ wire: RDWire, _ payload: Data, encrypted: Bool) {
        guard let connection else { return }
        var data = payload
        if encrypted {
            guard let key, let sealed = RDCrypto.seal(data, key: key) else { return }
            data = sealed
        }
        let isFinal = wire == .bye
        connection.send(content: RDFrame.pack(wire, payload: data),
                        contentContext: isFinal ? .finalMessage : .defaultMessage,
                        isComplete: isFinal,
                        completion: .contentProcessed { _ in })
    }

    private func sendJSON<T: Encodable>(_ wire: RDWire, _ message: T) {
        guard phase == .connected else { return }
        send(wire, RDJSON.encode(message), encrypted: true)
    }

    func moveAbs(_ x: Double, _ y: Double) {
        sendJSON(.mouseMoveAbs, MouseMoveAbsMsg(x: x, y: y))
    }

    func moveRel(dx: Double, dy: Double) {
        guard abs(dx) > 0.0001 || abs(dy) > 0.0001 else { return }
        sendJSON(.mouseMoveRel, MouseMoveRelMsg(dx: dx, dy: dy))
    }

    func buttonDown(_ button: Int) {
        sendJSON(.mouseDown, MouseButtonMsg(button: button))
    }

    func buttonUp(_ button: Int) {
        sendJSON(.mouseUp, MouseButtonMsg(button: button))
    }

    func click(button: Int, atRemote remote: CGPoint?) {
        if let remote {
            moveAbs(Double(remote.x), Double(remote.y))
        }
        buttonDown(button)
        buttonUp(button)
    }

    func scroll(dx: Double, dy: Double) {
        sendJSON(.scroll, ScrollMsg(dx: dx, dy: dy))
    }

    private func sendModifier(_ modifier: RDModifiers, down: Bool, currentFlags: UInt8) {
        let code: UInt16
        if modifier == .command { code = 55 }
        else if modifier == .shift { code = 56 }
        else if modifier == .option { code = 58 }
        else if modifier == .control { code = 59 }
        else { return }
        sendJSON(.keyEvent, KeyEventMsg(code: code, down: down, flags: currentFlags))
    }

    private func sendModifiersDown(_ modifiers: RDModifiers) {
        if modifiers.contains(.command) { sendModifier(.command, down: true, currentFlags: modifiers.rawValue) }
        if modifiers.contains(.shift) { sendModifier(.shift, down: true, currentFlags: modifiers.rawValue) }
        if modifiers.contains(.option) { sendModifier(.option, down: true, currentFlags: modifiers.rawValue) }
        if modifiers.contains(.control) { sendModifier(.control, down: true, currentFlags: modifiers.rawValue) }
    }

    private func sendModifiersUp(_ modifiers: RDModifiers) {
        if modifiers.contains(.control) { sendModifier(.control, down: false, currentFlags: modifiers.rawValue) }
        if modifiers.contains(.option) { sendModifier(.option, down: false, currentFlags: modifiers.rawValue) }
        if modifiers.contains(.shift) { sendModifier(.shift, down: false, currentFlags: modifiers.rawValue) }
        if modifiers.contains(.command) { sendModifier(.command, down: false, currentFlags: modifiers.rawValue) }
    }

    func keyTap(_ key: RDKey, modifiers: RDModifiers = []) {
        sendModifiersDown(modifiers)
        sendJSON(.keyEvent, KeyEventMsg(code: key.rawValue, down: true, flags: modifiers.rawValue))
        sendJSON(.keyEvent, KeyEventMsg(code: key.rawValue, down: false, flags: modifiers.rawValue))
        sendModifiersUp(modifiers)
    }

    func sendText(_ text: String) {
        sendJSON(.textEvent, TextMsg(s: text))
    }

    /// Text typed on the iOS keyboard, honoring sticky modifiers from the key bar.
    /// Plain text is sent as unicode; with non-shift modifiers held, characters are
    /// mapped to Mac virtual key codes so shortcuts like ⌘C reach the host correctly.
    func typeText(_ text: String, modifiers: RDModifiers) {
        guard !modifiers.isEmpty else {
            sendText(text)
            return
        }
        if modifiers == [.shift] {
            sendText(text.uppercased())
            return
        }
        sendModifiersDown(modifiers)
        for character in text.lowercased() {
            if let code = virtualKey(for: character) {
                sendJSON(.keyEvent, KeyEventMsg(code: code, down: true, flags: modifiers.rawValue))
                sendJSON(.keyEvent, KeyEventMsg(code: code, down: false, flags: modifiers.rawValue))
            } else {
                sendText(String(character))
            }
        }
        sendModifiersUp(modifiers)
    }

    private func virtualKey(for character: Character) -> UInt16? {
        switch character {
        case "a": return 0
        case "b": return 11
        case "c": return 8
        case "d": return 2
        case "e": return 14
        case "f": return 3
        case "g": return 5
        case "h": return 4
        case "i": return 34
        case "j": return 38
        case "k": return 40
        case "l": return 37
        case "m": return 46
        case "n": return 45
        case "o": return 31
        case "p": return 35
        case "q": return 12
        case "r": return 15
        case "s": return 1
        case "t": return 17
        case "u": return 32
        case "v": return 9
        case "w": return 13
        case "x": return 7
        case "y": return 16
        case "z": return 6
        case "1": return 18
        case "2": return 19
        case "3": return 20
        case "4": return 21
        case "5": return 23
        case "6": return 22
        case "7": return 26
        case "8": return 28
        case "9": return 25
        case "0": return 29
        case " ": return 49
        default: return nil
        }
    }

    func setQuality(_ preset: RDQualityPreset, showRemoteCursor: Bool, codec: RDCodec = .hevc) {
        sendJSON(.setQuality, SetQualityMsg(preset: preset.rawValue, cursor: showRemoteCursor, codec: Int(codec.rawValue)))
    }

    func requestKeyframe(reason: String? = nil) {
        guard phase == .connected else { return }
        let now = Date()
        guard now.timeIntervalSince(lastKeyframeRequestAt) > 0.4 else { return }
        lastKeyframeRequestAt = now
        sendJSON(.requestKeyframe, RequestKeyframeMsg(reason: reason))
    }

    func wakeHostDisplay() {
        moveRel(dx: 0, dy: 0)
        requestKeyframe(reason: "wake_display")
    }

    private func describe(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .service(let name, _, _, _):
            return name
        case .hostPort(let host, let port):
            return "\(host):\(port)"
        default:
            return "remote"
        }
    }
}

extension ClientSession: Identifiable {
    var id: ObjectIdentifier { ObjectIdentifier(self) }
}
