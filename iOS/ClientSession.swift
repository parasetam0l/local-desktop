import AVFoundation
import CryptoKit
import Foundation
import Network
import UIKit
import UniformTypeIdentifiers

/// Client side of one local-desktop session: connection lifecycle, the
/// authentication decisions, reconnects, and the input API used by the UI.
/// Socket I/O and crypto live in `ClientConnection`, decoding in `VideoPipeline`;
/// this class only ever runs on the main actor.
@MainActor
final class ClientSession: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting
        case negotiating
        case needPin
        case connected
        /// Message, and seconds until the automatic reconnect (nil = none scheduled).
        case failed(String, Int?)
        case closed
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var hasVideoFrame = false
    @Published private(set) var remoteSize: CGSize = .zero
    @Published private(set) var targetName = ""
    @Published private(set) var serverName = ""
    @Published private(set) var serverId = ""
    /// Fingerprint of the Mac's identity key, shown while pairing.
    @Published private(set) var hostFingerprint = ""
    @Published private(set) var hostDescription = ""
    @Published private(set) var pinError: String?
    @Published private(set) var pinAttemptCounter = 0
    /// The Mac presented a different identity than the one this device paired with.
    @Published private(set) var identityMismatchServerId: String?
    @Published private(set) var isHostLocked = false
    @Published private(set) var isDisplaySleeping = false
    @Published private(set) var isWakingDisplay = false
    @Published private(set) var wakeTimedOut = false
    /// The Mac's Caps Lock, for the key bar's caps light (nil from Macs that don't say).
    @Published private(set) var macCapsLock: Bool?
    /// Whether the Mac's lid is shut, and whether an external display keeps it usable
    /// (nil fields from older Macs decode to "lid open, display exists").
    @Published private(set) var isLidClosed = false
    @Published private(set) var hasExternalDisplay = true
    @Published private(set) var runningApps: [RDRunningApp] = []
    @Published private(set) var hardwareControls = RDHardwareControls(brightness: 0.5, volume: 50, isMuted: false)
    /// The Mac's displays and the one being streamed (Macs before 1.2.1 don't send them).
    @Published private(set) var displays: [RDDisplay] = []
    @Published private(set) var selectedDisplayId: UInt32?
    /// Whether the Mac can lay its desktop out at a size we choose (false before 1.2.12).
    @Published private(set) var sizedMirrorAvailable = false
    /// The size the Mac's desktop is laid out at for us, nil with the Mac's own layout.
    @Published private(set) var mirrorSize: RDMirrorSize?
    /// How the desktop size is chosen: the Settings default at first, then the session
    /// menu's choice. It is asked for when a connection starts and again when the device
    /// is turned, so the picture keeps filling the screen.
    private(set) var desktopSize: DesktopSizeChoice = .macOwn
    /// The room the Mac's picture has on this device, in points; the session view sets it.
    var pictureArea: CGSize = .zero {
        didSet { if pictureArea != oldValue { pictureAreaChanged() } }
    }
    private var pictureAreaUpdate: DispatchWorkItem?
    private var mirrorRequestTimeout: DispatchWorkItem?
    /// How long the Mac gets to set a size up (it retries for a few seconds with its lid shut).
    private static let mirrorRequestPatience: TimeInterval = 8
    /// Whether the Mac hides its Dock for this session (nil when it can't, or before 1.2.13).
    @Published private(set) var hidesMacDock: Bool?
    /// Whether to ask the Mac to hide its Dock when a connection starts (from Settings).
    var defaultHideDock = false
    private var appliedDefaultHideDock = false
    /// Show the keyboard when a click lands in a text field on the Mac. It starts from
    /// Settings and the session panel changes it for this session only.
    @Published var autoKeyboard = false {
        didSet {
            guard autoKeyboard != oldValue, sentTextFocusPreference else { return }
            sendJSON(.setTextFocusReports, RDSetTextFocusReportsMsg(enabled: autoKeyboard))
        }
    }
    private var sentTextFocusPreference = false
    /// Show the keyboard on text field focus while in touchpad mode too.
    @Published var autoKeyboardInTouchpad = true
    /// Whether this session shares the clipboard with the Mac. It starts from Settings and
    /// the session panel changes it for this session only.
    @Published var sharesClipboard = false {
        didSet { if sharesClipboard != oldValue { clipboardSharingChanged() } }
    }
    private var clipboardSyncState = ClientClipboardSyncState()
    private var clipboardImage = RDClipboardImageAssembler()
    private var nextClipboardImageId: UInt32 = 1
    /// The Mac's latest answer after a click: counts up with each one, with whether the
    /// focus is in something to type into.
    @Published private(set) var textFocusReport: (count: Int, editable: Bool) = (0, false)
    /// Whether the Mac blocks its own keyboard and trackpad during sessions (nil before 1.2.4).
    @Published private(set) var blocksMacInput: Bool?
    /// The Mac can close, minimise and place its front window for this device.
    @Published private(set) var macWindowActions = false
    /// The Mac's front window as last reported (see `requestFrontWindow`).
    @Published private(set) var frontWindow: RDFrontWindowMsg?
    @Published var showDebugHUD = false {
        didSet {
            if showDebugHUD {
                currentRTT = lastRTT
                rawRTT = latestRawRTT
                if let protocolName = connection?.currentTransportLabel {
                    transportProtocol = protocolName
                }
            }
        }
    }
    /// Watch only: no pointer, scroll or keyboard input reaches the Mac.
    @Published var isViewOnly = false
    /// The outcome of something the user asked the Mac for, to show for a moment.
    @Published private(set) var notice: SessionNotice?
    private var mirrorSizeState = ClientMirrorSizeState()
    @Published private(set) var liveFPS: Double = 0.0
    @Published private(set) var liveBitrateMbps: Double = 0.0
    @Published private(set) var liveDecodeMs: Double = 0.0
    @Published private(set) var currentRTT: Double = 0.0
    @Published private(set) var rawRTT: Double = 0.0
    @Published private(set) var transportProtocol: String = ""
    private var lastRTT = 0.0
    private var latestRawRTT = 0.0
    private(set) var serverMacAddress: String?

    var displayName: String {
        if !serverName.isEmpty {
            return serverName
        }
        if !targetName.isEmpty {
            return targetName
        }
        return hostDescription.isEmpty ? "Mac" : hostDescription
    }

    /// The lid is shut and no external display is attached: macOS forces clamshell sleep,
    /// so there is no screen to show until the lid opens or a display is connected.
    var isHeadlessClosedLid: Bool { isLidClosed && !hasExternalDisplay }

    let deviceName: String
    var onConnected: ((ClientSession) -> Void)?
    /// Called with the server id after this device pairs with a Mac.
    var onPaired: ((String) -> Void)?

    private static let reconnectDelays = [1, 2, 4, 8, 15, 30]
    /// Stop retrying on our own after this long without a successful connection.
    private static let maxReconnectWindow: TimeInterval = 5 * 60
    private static let handshakeTimeout: UInt64 = 10_000_000_000

    private lazy var video = VideoPipeline(
        onSize: { [weak self] size in self?.videoSizeChanged(size) },
        onNeedsKeyframe: { [weak self] in self?.requestKeyframe(reason: "missing_headers_or_corrupted") }
    )
    var videoOutput: VideoOutput { video.output }

    private let networkQueue = DispatchQueue(label: "rd.client.network", qos: .userInteractive)
    private(set) var endpoint: NWEndpoint?
    /// The host's QUIC advertisement, kept for reconnects to the same host.
    private var quicAdvert: RDQUICAdvert?
    private var actualEndpoint: NWEndpoint?
    /// The Mac the user meant to reach (from Bonjour or recents), if known.
    private var expectedServerId: String?
    private var connection: ClientConnection?
    /// Bumped per connection so events from a replaced connection are ignored.
    private var connectionGeneration = 0
    private var identity: ServerIdentity?
    /// How this connection asked to be let in; authOK is only valid after one of these.
    private enum AuthAttempt {
        case pin(trust: Bool)
        case device
    }
    private var authAttempt: AuthAttempt?
    private var handshakeTimeoutTask: Task<Void, Never>?
    private var pingTimer: Timer?
    private var countdownTimer: Timer?
    private var lastPongAt = Date()
    private var lastStatsReport = Date()
    private var lastKeyframeRequestAt = Date.distantPast
    private var lastWakeRequestAt = Date.distantPast
    private var wakeTimeoutTask: Task<Void, Never>?
    private var shouldAutoWakeClosedLidOnInitialHostState = false
    private(set) var hasConnectedOnce = false
    private var userInitiatedDisconnect = false
    private var reconnectAttempt = 0
    private var failingSince: Date?
    /// After a Wake-on-LAN, keep retrying even before the first successful connection.
    private var wakeRetryDeadline: Date?
    var autoReconnect = true

    init(deviceName: String) {
        self.deviceName = deviceName
    }

    var currentEndpoint: NWEndpoint? { actualEndpoint ?? endpoint }
    var canReconnect: Bool {
        guard currentEndpoint != nil else { return false }
        return hasConnectedOnce || (wakeRetryDeadline.map { $0 > Date() } ?? false)
    }

    // MARK: Connection lifecycle

    /// - Parameter quic: what the host advertised about QUIC. Without TXT info (a recent
    ///   Mac reached by address, or a Bonjour result from before the host's QUIC listener
    ///   was up) QUIC is still tried on the TCP port number: an older Mac doesn't answer
    ///   on UDP and the attempt falls back to TCP within `RDQUIC.fallbackDelay`.
    func connect(to target: NWEndpoint, fallbackName: String? = nil, expectedServerId: String? = nil,
                 quic: RDQUICAdvert? = nil, retryWhileWaking: Bool = false) {
        ClientLog.write("connect to \(target) quic=\(String(describing: quic))")
        userInitiatedDisconnect = false
        resetWakeState()
        tearDownConnection()
        stopPing()
        countdownTimer?.invalidate()
        countdownTimer = nil
        if let fallbackName, !fallbackName.isEmpty {
            targetName = fallbackName
        }
        if let expectedServerId, !expectedServerId.isEmpty {
            self.expectedServerId = expectedServerId
        }
        if retryWhileWaking {
            wakeRetryDeadline = Date().addingTimeInterval(60)
        }
        serverName = ""
        serverId = ""
        hostFingerprint = ""
        identity = nil
        authAttempt = nil
        pinError = nil
        identityMismatchServerId = nil
        endpoint = target
        quicAdvert = quic
        actualEndpoint = nil
        lastRTT = 0.0
        latestRawRTT = 0.0
        currentRTT = 0.0
        rawRTT = 0.0
        transportProtocol = ""
        hostDescription = describe(target)
        phase = .connecting
        video.reset()
        armHandshakeTimeout()

        connectionGeneration += 1
        let generation = connectionGeneration
        let video = self.video
        let conn = ClientConnection(
            to: target,
            quicEndpoint: (quic ?? .samePort).endpoint(forTCP: target),
            deviceId: TrustStore.deviceId,
            deviceName: deviceName,
            queue: networkQueue,
            onEvent: { [weak self] event in
                guard let session = self else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard session.connectionGeneration == generation else { return }
                        session.handle(event)
                    }
                }
            },
            onVideoFrame: { payload in
                video.submit(payload)
            }
        )
        connection = conn
        conn.start()
    }

    func reconnect() {
        guard let target = currentEndpoint else { return }
        // `target` is the resolved TCP address; the QUIC port is derived from it again.
        connect(to: target, fallbackName: targetName, expectedServerId: serverId.isEmpty ? nil : serverId,
                quic: quicAdvert)
    }

    /// "Reconnect Now": starts a fresh backoff sequence.
    func retryNow() {
        reconnectAttempt = 0
        failingSince = nil
        reconnect()
    }

    func disconnect() {
        ClientLog.write("disconnect (user)")
        userInitiatedDisconnect = true
        resetWakeState()
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
        stopPing()
        countdownTimer?.invalidate()
        countdownTimer = nil
        if phase == .connected {
            connection?.sendAndClose(.bye, RDJSON.encode(ByeMsg(reason: RDByeReason.userDisconnect)))
        } else {
            connection?.cancel()
        }
        connection = nil
        connectionGeneration += 1
        phase = .closed
    }

    private func tearDownConnection() {
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
        mirrorRequestTimeout?.cancel()
        mirrorRequestTimeout = nil
        mirrorSizeState.resetForNewConnection()
        mirrorSize = nil
        connection?.cancel()
        connection = nil
        connectionGeneration += 1
    }

    /// Covers TCP connect plus each handshake step; paused while the user types the PIN.
    private func armHandshakeTimeout() {
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.handshakeTimeout)
            guard !Task.isCancelled, let self,
                  self.phase == .connecting || self.phase == .negotiating else { return }
            self.fail("Connection timed out. Check that the Mac and iPhone are on the same Wi-Fi network.")
        }
    }

    private func handle(_ event: ClientConnection.Event) {
        guard !isDead else { return }
        switch event {
        case .ready(let remote):
            actualEndpoint = remote ?? endpoint
            phase = .negotiating
        case .serverHello(let identity):
            handleServerHello(identity)
        case .message(let wire, let payload):
            handleMessage(wire, payload: payload)
        case .pong(let rttMs):
            lastPongAt = Date()
            latestRawRTT = rttMs
            // Fast EWMA smooths single off-channel Wi-Fi scan spikes while still tracking real latency shifts.
            lastRTT = lastRTT > 0 ? (lastRTT * 0.65 + rttMs * 0.35) : rttMs
            reportNetworkStatsIfNeeded()
        case .closed:
            if phase == .connected {
                fail("Connection closed by host")
            } else if identity == nil {
                fail("The Mac closed the connection during setup. Make sure LocalDesktop is up to date on both devices.")
            } else {
                fail("Connection closed")
            }
        case .failed(let reason):
            fail(reason)
        case .rejected(let reason):
            fail(reason, allowReconnect: false)
        }
    }

    private func fail(_ reason: String, allowReconnect: Bool = true) {
        ClientLog.write("session failed: \(reason) (reconnect \(allowReconnect))")
        guard !isDead else { return }
        resetWakeState()
        tearDownConnection()
        stopPing()
        countdownTimer?.invalidate()
        countdownTimer = nil

        if allowReconnect, autoReconnect, !userInitiatedDisconnect, canReconnect, let delay = nextReconnectDelay() {
            phase = .failed(reason, delay)
            countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
                guard let session = self else {
                    timer.invalidate()
                    return
                }
                MainActor.assumeIsolated {
                    session.countdownTick()
                }
            }
        } else {
            phase = .failed(reason, nil)
        }
    }

    private func countdownTick() {
        guard case .failed(let message, let remaining?) = phase else {
            countdownTimer?.invalidate()
            countdownTimer = nil
            return
        }
        if remaining > 1 {
            phase = .failed(message, remaining - 1)
        } else {
            countdownTimer?.invalidate()
            countdownTimer = nil
            reconnect()
        }
    }

    private func nextReconnectDelay() -> Int? {
        let now = Date()
        let since = failingSince ?? now
        failingSince = since
        guard now.timeIntervalSince(since) < Self.maxReconnectWindow else { return nil }
        let delay = Self.reconnectDelays[min(reconnectAttempt, Self.reconnectDelays.count - 1)]
        reconnectAttempt += 1
        return delay
    }

    private var isDead: Bool {
        if case .failed = phase { return true }
        if case .closed = phase { return true }
        return false
    }

    // MARK: Authentication

    private func handleServerHello(_ identity: ServerIdentity) {
        self.identity = identity
        serverName = identity.serverName
        targetName = identity.serverName
        serverId = identity.serverId
        hostFingerprint = RDHandshake.fingerprint(of: identity.identityKey)

        // Reaching a different Mac than the paired one we asked for means someone
        // else is answering for it (or the Mac was reset). Don't offer it the PIN.
        if let expected = expectedServerId, expected != identity.serverId,
           TrustStore.pinnedHostKey(serverId: expected) != nil {
            if TrustStore.pinnedHostKey(serverId: identity.serverId) == identity.identityKey {
                // Another Mac this device paired with now answers at that address (e.g. the
                // addresses swapped). It's legitimate, just not the one that was selected.
                fail("\(identity.serverName) answered instead of the Mac you selected; its address may have changed. "
                     + "Pull to refresh Nearby Macs and try again.", allowReconnect: false)
            } else {
                reportIdentityMismatch(serverId: expected)
            }
            return
        }

        guard let pinned = TrustStore.pinnedHostKey(serverId: identity.serverId) else {
            // First pairing: trust on first use, after the user enters the PIN.
            handshakeTimeoutTask?.cancel()
            phase = .needPin
            return
        }
        guard pinned == identity.identityKey else {
            reportIdentityMismatch(serverId: identity.serverId)
            return
        }
        guard let deviceKey = TrustStore.deviceSigningKey(),
              let signature = try? deviceKey.signature(for: RDHandshake.deviceProof(transcript: identity.transcript)) else {
            handshakeTimeoutTask?.cancel()
            phase = .needPin
            return
        }
        authAttempt = .device
        send(.authDevice, RDJSON.encode(AuthDeviceMsg(signature: signature)))
    }

    /// After the user forgot a Mac whose identity changed: connect again and pair from scratch.
    func pairAgain() {
        expectedServerId = nil
        identityMismatchServerId = nil
        retryNow()
    }

    private func reportIdentityMismatch(serverId: String) {
        identityMismatchServerId = serverId
        fail("This Mac's identity doesn't match the one you paired with, so the connection was stopped. "
             + "If you reinstalled or reset LocalDesktop on it, forget it and pair again.",
             allowReconnect: false)
    }

    /// PIN entry from the UI. With `trust`, this device's public key is registered
    /// so future connections skip the PIN.
    func submitPIN(_ pin: String, trust: Bool) {
        // Only ever to a Mac that has proven its identity in this handshake.
        guard phase == .needPin, identity != nil else { return }
        pinError = nil
        pinAttemptCounter += 1
        phase = .negotiating
        armHandshakeTimeout()
        let deviceKey = trust ? TrustStore.deviceSigningKey()?.publicKey.rawRepresentation : nil
        authAttempt = .pin(trust: deviceKey != nil)
        send(.authPin, RDJSON.encode(AuthPinMsg(pin: pin, trust: deviceKey != nil, deviceKey: deviceKey)))
    }

    // MARK: Messages

    private func handleMessage(_ wire: RDWire, payload: Data) {
        // Before authentication only the answer to our own auth request is meaningful.
        guard phase == .connected || wire == .authOK || wire == .authFailed || wire == .bye else { return }

        switch wire {
        case .authOK:
            guard phase != .connected, let attempt = authAttempt,
                  let msg = RDJSON.decode(AuthOKMsg.self, from: payload) else {
                fail("Protocol error: unexpected authentication response")
                return
            }
            mirrorSizeState.resetForNewConnection()
            mirrorSize = nil
            mirrorRequestTimeout?.cancel()
            mirrorRequestTimeout = nil
            appliedDefaultHideDock = false
            sentTextFocusPreference = false
            sizedMirrorAvailable = msg.sizedMirrorAvailable ?? false
            clipboardImage.reset()
            let isInitialConnect = !hasConnectedOnce
            handleAuthOK(msg, attempt: attempt)
            if showDebugHUD, let protocolName = connection?.currentTransportLabel {
                transportProtocol = protocolName
            }
            if phase == .connected, sizedMirrorAvailable, desktopSize != .macOwn, pictureArea.width >= 1 {
                mirrorSizeState.markAppliedForConnection()
                applyDesktopSize(byUser: false)
            }
            if phase == .connected {
                if sharesClipboard {
                    // Macs before 1.2.21 ignore this.
                    sendJSON(.setClipboardSharing, RDSetClipboardSharingMsg(enabled: true))
                }
                if clipboardSyncState.didAuthenticate(isInitialConnect: isInitialConnect,
                                                      sharesClipboard: sharesClipboard,
                                                      currentChangeCount: UIPasteboard.general.changeCount,
                                                      now: ProcessInfo.processInfo.systemUptime) {
                    syncClipboardToMac(trigger: .reconnect)
                }
            }

        case .authFailed:
            guard phase != .connected, identity != nil, authAttempt != nil else { return }
            authAttempt = nil
            let msg = RDJSON.decode(AuthFailedMsg.self, from: payload)
            switch msg?.kind {
            case .unsupportedVersion?, .tooManyAttempts?:
                fail(msg?.reason ?? "Authentication failed", allowReconnect: false)
            default:
                handshakeTimeoutTask?.cancel()
                pinError = msg?.reason ?? "Incorrect PIN"
                pinAttemptCounter += 1
                phase = .needPin
            }


        case .hostState:
            guard let msg = RDJSON.decode(HostStateMsg.self, from: payload) else { break }
            isHostLocked = msg.isLocked
            isDisplaySleeping = msg.isDisplaySleeping
            blocksMacInput = msg.blocksLocalInput
            hidesMacDock = msg.hidesDock
            macCapsLock = msg.capsLock
            macWindowActions = msg.windowActions ?? false
            if !sentTextFocusPreference {
                sentTextFocusPreference = true
                // Macs before 1.2.13 ignore this.
                if autoKeyboard { sendJSON(.setTextFocusReports, RDSetTextFocusReportsMsg(enabled: true)) }
            }
            // The Settings default, asked for once per connection (the Mac shows its
            // Dock again when its last client leaves).
            if !appliedDefaultHideDock, msg.hidesDock != nil {
                appliedDefaultHideDock = true
                if defaultHideDock { setHidesMacDock(true) }
            }
            isLidClosed = msg.isLidClosed ?? false
            // Macs before this protocol version don't report it; assume a display rather
            // than showing a false "lid closed" warning to them.
            hasExternalDisplay = msg.hasExternalDisplay ?? true
            if !isDisplaySleeping {
                wakeTimeoutTask?.cancel()
                wakeTimeoutTask = nil
                isWakingDisplay = false
                wakeTimedOut = false
                shouldAutoWakeClosedLidOnInitialHostState = false
            } else if shouldAutoWakeClosedLidOnInitialHostState {
                shouldAutoWakeClosedLidOnInitialHostState = false
                if ClientWakePolicy.shouldAutoWakeClosedLid(isInitialConnect: true,
                                                            isHeadlessClosedLid: isHeadlessClosedLid,
                                                            isDisplaySleeping: isDisplaySleeping) {
                    wakeHostDisplay()
                }
            }

        case .frontWindow:
            guard let msg = RDJSON.decode(RDFrontWindowMsg.self, from: payload) else { break }
            frontWindow = msg

        case .runningApps:
            guard let msg = RDJSON.decode(RDRunningAppsMsg.self, from: payload) else { break }
            runningApps = msg.apps

        case .clipboard:
            guard sharesClipboard, let msg = RDJSON.decode(RDClipboardMsg.self, from: payload) else { break }
            receiveClipboard(msg.text)

        case .clipboardImage:
            guard sharesClipboard, let image = clipboardImage.add(payload) else { break }
            receiveClipboardImage(image)

        case .textFocus:
            guard autoKeyboard, let msg = RDJSON.decode(RDTextFocusMsg.self, from: payload) else { break }
            textFocusReport = (textFocusReport.count + 1, msg.editable)

        case .hardwareControlsState:
            guard let msg = RDJSON.decode(RDHardwareControls.self, from: payload) else { break }
            hardwareControls = msg

        case .displays:
            guard let msg = RDJSON.decode(RDDisplaysMsg.self, from: payload) else { break }
            displays = msg.displays
            selectedDisplayId = msg.selectedId
            sizedMirrorAvailable = msg.sizedMirrorAvailable ?? false
            mirrorSize = msg.mirrorSize
            // The Mac's display list changes while it sets a size up, so messages that
            // still have the old size arrive before its answer. Only one with the size
            // asked for settles the request; `mirrorRequestTimedOut` reports one that
            // never comes.
            let outcome = mirrorSizeState.didReceiveDisplays(mirrorSize: msg.mirrorSize,
                                                             sizedMirrorAvailable: sizedMirrorAvailable)
            if outcome.settledRequest {
                mirrorRequestTimeout?.cancel()
                mirrorRequestTimeout = nil
            }
            if let label = outcome.userConfirmedLabel {
                post("Desktop size: \(label)", symbol: "rectangle.dashed")
            }
            // Asked for once per connection (the Mac drops the size when its last client
            // leaves); the session menu and a turn of the device change it after.
            if outcome.shouldApplyInitialSize, desktopSize != .macOwn {
                applyDesktopSize(byUser: false)
            }

        case .bye:
            let msg = RDJSON.decode(ByeMsg.self, from: payload)
            // The host said goodbye on purpose; reconnecting on our own would just loop.
            let reason = msg?.reason == RDByeReason.hostStopped
                ? "Sharing was stopped on the Mac."
                : "The Mac ended the session."
            fail(reason, allowReconnect: false)

        default:
            break
        }
    }

    private func handleAuthOK(_ msg: AuthOKMsg, attempt: AuthAttempt) {
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
        let isInitialConnect = !hasConnectedOnce
        shouldAutoWakeClosedLidOnInitialHostState = isInitialConnect
        phase = .connected
        hasConnectedOnce = true
        reconnectAttempt = 0
        failingSince = nil
        wakeRetryDeadline = nil
        serverMacAddress = msg.macAddress
        // Pin only when this device asked to be trusted (or already was); the host's
        // word alone never makes a Mac "paired".
        let shouldPin: Bool
        switch attempt {
        case .pin(let trust): shouldPin = trust && msg.trusted
        case .device: shouldPin = true
        }
        if shouldPin, let identity {
            TrustStore.pinHostKey(identity.identityKey, serverId: identity.serverId)
            expectedServerId = identity.serverId
            onPaired?(identity.serverId)
        }
        startPing()
        // The Mac wakes its own display when that can help; doing it here as well doubled
        // every wake request and kept a closed-lid Mac cycling between wake and sleep.
        onConnected?(self)
    }

    private func videoSizeChanged(_ size: CGSize) {
        remoteSize = size
        hasVideoFrame = true
    }

    /// Called by the canvas when its display layer appears; it needs an IDR to start.
    func attachVideoLayer(_ layer: AVSampleBufferDisplayLayer) {
        videoOutput.attach(layer)
        requestKeyframe(reason: "new_layer")
    }

    func detachVideoLayer(_ layer: AVSampleBufferDisplayLayer) {
        videoOutput.detach(layer)
    }

    // MARK: Keepalive & Telemetry

    private func startPing() {
        stopPing()
        lastPongAt = Date()
        lastStatsReport = Date()
        // Every second, and in the common run-loop modes so it keeps ticking while a
        // finger is on the screen (the default mode pauses during touch tracking).
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let session = self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated {
                session.pingTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pingTimer = timer
    }

    private func pingTick() {
        guard phase == .connected else {
            stopPing()
            return
        }
        if Date().timeIntervalSince(lastPongAt) > 8.0 {
            fail("Connection lost (no heartbeat)")
            return
        }
        connection?.sendPing()
    }

    private func stopPing() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    private func reportNetworkStatsIfNeeded() {
        guard phase == .connected else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(lastStatsReport)
        guard elapsed >= 1.0 else { return }
        lastStatsReport = now

        let network = connection?.drainStats() ?? ClientConnection.Stats()
        let decoded = video.drainStats()
        let fps = Double(decoded.frames) / elapsed
        // These redraw the session's views, so they only change while the HUD shows them.
        if showDebugHUD {
            liveFPS = fps
            liveBitrateMbps = (Double(network.bytes) * 8.0) / (elapsed * 1_000_000.0)
            liveDecodeMs = decoded.decodeMs
            currentRTT = lastRTT
            rawRTT = latestRawRTT
            transportProtocol = network.transportProtocol
        }

        sendJSON(.networkStats, NetworkStatsMsg(rttMs: lastRTT,
                                                decodeMs: decoded.decodeMs,
                                                fps: fps,
                                                droppedFrames: decoded.dropped + network.lost))
    }

    func shouldAutoShowKeyboard(touchpadMode: Bool) -> Bool {
        AutoKeyboardPolicy.shouldAutoShowKeyboard(autoKeyboard: autoKeyboard,
                                                  autoKeyboardInTouchpad: autoKeyboardInTouchpad,
                                                  touchpadMode: touchpadMode)
    }

    // MARK: Clipboard

    private func clipboardSharingChanged() {
        clipboardSyncState.setSharing(sharesClipboard, currentChangeCount: UIPasteboard.general.changeCount)
        clipboardImage.reset()
        sendJSON(.setClipboardSharing, RDSetClipboardSharingMsg(enabled: sharesClipboard))
    }

    /// Syncs text or an image copied while the app was backgrounded, or queues the sync
    /// until reconnect finishes if the connection dropped while away.
    func syncClipboardToMacAfterBackgroundReturn() {
        let pasteboard = UIPasteboard.general
        let now = ProcessInfo.processInfo.systemUptime
        guard clipboardSyncState.foregroundReturnShouldSync(isConnected: phase == .connected,
                                                           sharesClipboard: sharesClipboard,
                                                           currentChangeCount: pasteboard.changeCount,
                                                           now: now) else { return }
        syncClipboard(from: pasteboard)
    }

    /// Sends this device's clipboard (text or an image) to the Mac if it changed since
    /// sharing turned on or the last sync. Checking `changeCount`, `hasStrings`, `hasURLs`,
    /// and `hasImages` does not show iOS's paste prompt; reading a typed value does, so
    /// only one typed accessor is read per sync.
    func syncClipboardToMac(trigger: ClientClipboardSyncState.Trigger = .pasteCommand) {
        let pasteboard = UIPasteboard.general
        let now = ProcessInfo.processInfo.systemUptime
        guard clipboardSyncState.canStartSync(trigger: trigger,
                                              isConnected: phase == .connected,
                                              sharesClipboard: sharesClipboard,
                                              currentChangeCount: pasteboard.changeCount,
                                              now: now) else { return }
        syncClipboard(from: pasteboard)
    }

    private func syncClipboard(from pasteboard: UIPasteboard) {
        clipboardSyncState.beginSync(currentChangeCount: pasteboard.changeCount)
        defer {
            clipboardSyncState.endSync(currentChangeCount: pasteboard.changeCount,
                                       now: ProcessInfo.processInfo.systemUptime)
        }
        guard let kind = ClientClipboardSyncState.preferredReadKind(hasImages: pasteboard.hasImages,
                                                                    hasStrings: pasteboard.hasStrings,
                                                                    hasURLs: pasteboard.hasURLs) else { return }
        switch kind {
        case .image:
            guard let image = pasteboard.image,
                  let data = Self.encoded(image),
                  let chunks = RDClipboardImage.chunks(of: data, id: nextClipboardImageId) else { return }
            nextClipboardImageId &+= 1
            for chunk in chunks {
                send(.clipboardImage, chunk)
            }
        case .string:
            guard let text = pasteboard.string, !text.isEmpty,
                  let payload = RDClipboardMsg.payload(for: text) else { return }
            send(.clipboard, payload)
        case .url:
            guard let url = pasteboard.url else { return }
            let text = url.absoluteString
            guard !text.isEmpty, let payload = RDClipboardMsg.payload(for: text) else { return }
            send(.clipboard, payload)
        }
    }

    private static func encoded(_ image: UIImage) -> Data? {
        if let png = image.pngData(), png.count <= RDClipboardImage.maxSize { return png }
        return image.jpegData(compressionQuality: 0.9)
    }

    private func receiveClipboardImage(_ data: Data) {
        // Not an image we can read: leave the clipboard alone.
        guard UIImage(data: data) != nil else { return }
        let pasteboard = UIPasteboard.general
        let type = RDClipboardImage.isPNG(data) ? UTType.png : UTType.jpeg
        // Local-only prevents iOS Universal Clipboard from echoing Mac's clipboard back to Mac.
        pasteboard.setItems([[type.identifier: data]], options: [.localOnly: true])
        clipboardSyncState.didReceiveFromHost(currentChangeCount: pasteboard.changeCount)
    }

    private func receiveClipboard(_ text: String) {
        guard !text.isEmpty, text.utf8.count <= RDClipboardMsg.maxPayload else { return }
        let pasteboard = UIPasteboard.general
        // Local-only prevents iOS Universal Clipboard from echoing Mac's clipboard back to Mac.
        pasteboard.setItems([[UTType.utf8PlainText.identifier: text]], options: [.localOnly: true])
        clipboardSyncState.didReceiveFromHost(currentChangeCount: pasteboard.changeCount)
    }

    // MARK: Input

    private func send(_ wire: RDWire, _ payload: Data) {
        connection?.send(wire, payload)
    }

    /// What View only holds back.
    private static let inputWires: Set<RDWire> = [.mouseMoveAbs, .mouseMoveRel, .mouseDown, .mouseUp,
                                                  .scroll, .keyEvent, .textEvent]

    private func sendJSON<T: Encodable>(_ wire: RDWire, _ message: T) {
        guard phase == .connected else { return }
        if isViewOnly, Self.inputWires.contains(wire) { return }
        send(wire, RDJSON.encode(message))
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

    /// Lines (mouse-wheel steps), or points when `precise`. dy > 0 scrolls up.
    func scroll(dx: Double, dy: Double, precise: Bool = false) {
        sendJSON(.scroll, ScrollMsg(dx: dx, dy: dy, precise: precise ? true : nil))
    }

    /// The modifiers kept pressed on the Mac by `setHeldModifiers`.
    private var heldModifiers: RDModifiers = []

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
        let flags = modifiers.union(heldModifiers).rawValue
        if modifiers.contains(.command) { sendModifier(.command, down: true, currentFlags: flags) }
        if modifiers.contains(.shift) { sendModifier(.shift, down: true, currentFlags: flags) }
        if modifiers.contains(.option) { sendModifier(.option, down: true, currentFlags: flags) }
        if modifiers.contains(.control) { sendModifier(.control, down: true, currentFlags: flags) }
    }

    private func sendModifiersUp(_ modifiers: RDModifiers) {
        var remaining = modifiers.union(heldModifiers)
        if modifiers.contains(.control) {
            remaining.remove(.control)
            sendModifier(.control, down: false, currentFlags: remaining.rawValue)
        }
        if modifiers.contains(.option) {
            remaining.remove(.option)
            sendModifier(.option, down: false, currentFlags: remaining.rawValue)
        }
        if modifiers.contains(.shift) {
            remaining.remove(.shift)
            sendModifier(.shift, down: false, currentFlags: remaining.rawValue)
        }
        if modifiers.contains(.command) {
            remaining.remove(.command)
            sendModifier(.command, down: false, currentFlags: remaining.rawValue)
        }
    }

    /// Presses and releases modifiers on the Mac so that it sees exactly these held, as
    /// with physical keys: menus switch to their Option items and clicks carry them.
    func setHeldModifiers(_ modifiers: RDModifiers) {
        let released = heldModifiers.subtracting(modifiers)
        let pressed = modifiers.subtracting(heldModifiers)
        heldModifiers = heldModifiers.intersection(modifiers)
        sendModifiersUp(released)
        sendModifiersDown(pressed)
        heldModifiers = modifiers
    }

    /// A key of a keyboard attached to this device going down or up, by its Mac key code.
    func hardwareKey(code: UInt16, down: Bool, modifiers: RDModifiers) {
        if down, code == RDKey.keyV.rawValue, modifiers.union(heldModifiers).contains(.command) {
            // The Mac must have the clipboard before it sees the paste.
            syncClipboardToMac()
        }
        sendJSON(.keyEvent, KeyEventMsg(code: code, down: down, flags: modifiers.union(heldModifiers).rawValue))
    }

    func keyTap(_ key: RDKey, modifiers: RDModifiers = []) {
        if key == .keyV, modifiers.union(heldModifiers).contains(.command) {
            syncClipboardToMac()
        }
        let added = modifiers.subtracting(heldModifiers)
        let flags = modifiers.union(heldModifiers).rawValue
        sendModifiersDown(added)
        sendJSON(.keyEvent, KeyEventMsg(code: key.rawValue, down: true, flags: flags))
        sendJSON(.keyEvent, KeyEventMsg(code: key.rawValue, down: false, flags: flags))
        sendModifiersUp(added)
    }

    func sendText(_ text: String) {
        sendJSON(.textEvent, TextMsg(s: text))
    }

    /// Text typed on the iOS keyboard, honoring modifiers from the key bar.
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
        let added = modifiers.subtracting(heldModifiers)
        let flags = modifiers.union(heldModifiers).rawValue
        sendModifiersDown(added)
        for character in text.lowercased() {
            if let code = Self.virtualKey(for: character) {
                sendJSON(.keyEvent, KeyEventMsg(code: code, down: true, flags: flags))
                sendJSON(.keyEvent, KeyEventMsg(code: code, down: false, flags: flags))
            } else {
                sendText(String(character))
            }
        }
        sendModifiersUp(added)
    }

    private static func virtualKey(for character: Character) -> UInt16? {
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
        guard now.timeIntervalSince(lastKeyframeRequestAt) > 0.25 else { return }
        lastKeyframeRequestAt = now
        sendJSON(.requestKeyframe, RequestKeyframeMsg(reason: reason))
    }

    func wakeHostDisplay() {
        guard phase == .connected else { return }
        let now = Date()
        guard !isWakingDisplay, now.timeIntervalSince(lastWakeRequestAt) >= 2.0 else { return }
        lastWakeRequestAt = now
        if isDisplaySleeping {
            isWakingDisplay = true
            wakeTimedOut = false
            wakeTimeoutTask?.cancel()
            wakeTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.isWakingDisplay = false
                if self.isDisplaySleeping {
                    self.wakeTimedOut = true
                }
            }
        }
        send(.wakeDisplay, Data())
        if hasVideoFrame {
            moveRel(dx: 1, dy: 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                MainActor.assumeIsolated {
                    self?.moveRel(dx: -1, dy: -1)
                }
            }
        }
        requestKeyframe(reason: "wake_display")
    }

    private func resetWakeState() {
        wakeTimeoutTask?.cancel()
        wakeTimeoutTask = nil
        isWakingDisplay = false
        wakeTimedOut = false
        shouldAutoWakeClosedLidOnInitialHostState = false
    }

    func requestRunningApps() {
        guard phase == .connected else { return }
        send(.requestApps, Data())
    }

    /// Asks which window is in front on the Mac; the answer lands in `frontWindow`.
    func requestFrontWindow() {
        guard phase == .connected, macWindowActions else { return }
        frontWindow = nil
        send(.requestFrontWindow, Data())
    }

    func activateApp(bundleId: String) {
        sendJSON(.activateApp, RDActivateAppMsg(bundleId: bundleId))
    }

    func triggerSystemAction(_ action: RDSystemActionType) {
        sendJSON(.systemAction, RDSystemActionMsg(action: action))
    }

    /// Streams another of the Mac's displays; the Mac confirms with a new `displays` message.
    func selectDisplay(_ id: UInt32) {
        guard phase == .connected, id != selectedDisplayId, displays.contains(where: { $0.id == id }) else { return }
        selectedDisplayId = id
        sendJSON(.selectDisplay, RDSelectDisplayMsg(id: id))
    }

    private func post(_ text: String, symbol: String, isFailure: Bool = false) {
        notice = SessionNotice(id: (notice?.id ?? 0) + 1, symbol: symbol, text: text, isFailure: isFailure)
    }

    /// Lays the Mac's desktop out at `size` (its own screen mirrors that for the session),
    /// or back at the Mac's own size with nil; the Mac confirms with a new `displays` message.
    private func setSizedMirror(_ size: RDMirrorSize?, byUser: Bool) {
        // Against the size on its way, if any: that is what the Mac will have next.
        guard case .send(let targetSize) = mirrorSizeState.beginRequestIfNeeded(
            size,
            isConnected: phase == .connected,
            sizedMirrorAvailable: sizedMirrorAvailable,
            byUser: byUser
        ) else { return }
        sendJSON(.setSizedMirror, RDSetSizedMirrorMsg(size: targetSize))
        mirrorRequestTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in self?.mirrorRequestTimedOut() }
        mirrorRequestTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.mirrorRequestPatience, execute: timeout)
    }

    private func mirrorRequestTimedOut() {
        guard mirrorSizeState.requestedMirrorSize != nil else { return }
        mirrorSizeState.clearPendingRequest()
        mirrorRequestTimeout = nil
        guard phase == .connected else { return }
        // Back on its own size, the Mac is not asked again at every turn of the device.
        if mirrorSize == nil { desktopSize = .macOwn }
        post("The Mac couldn't change the desktop size", symbol: "exclamationmark.triangle", isFailure: true)
    }

    /// Chooses how the Mac's desktop is laid out: at a size that fills this device's
    /// screen, at a standard size, or the Mac's own way.
    func setDesktopSize(_ choice: DesktopSizeChoice, byUser: Bool = true) {
        desktopSize = choice
        applyDesktopSize(byUser: byUser)
    }

    private func applyDesktopSize(byUser: Bool) {
        // Without the picture's area yet, `pictureAreaChanged` asks once it is known.
        guard desktopSize == .macOwn || pictureArea.width >= 1 else { return }
        setSizedMirror(desktopSize.size(for: pictureArea), byUser: byUser)
    }

    /// The device was turned (or the session view was first laid out). The desktop
    /// follows a moment later, so that one turn asks the Mac once; initial layout right
    /// after connecting asks immediately without adding a debounce stall.
    private func pictureAreaChanged() {
        pictureAreaUpdate?.cancel()
        if !mirrorSizeState.hasAppliedForConnection, sizedMirrorAvailable, phase == .connected {
            guard pictureArea.width >= 1 else { return }
            mirrorSizeState.markAppliedForConnection()
            if desktopSize != .macOwn { applyDesktopSize(byUser: false) }
            return
        }
        let update = DispatchWorkItem { [weak self] in
            guard let self, self.mirrorSizeState.hasAppliedForConnection, self.desktopSize != .macOwn else { return }
            self.applyDesktopSize(byUser: false)
        }
        pictureAreaUpdate = update
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: update)
    }

    /// Hides the Mac's Dock for the session or shows it again; the Mac confirms with `hostState`.
    func setHidesMacDock(_ on: Bool) {
        guard phase == .connected, hidesMacDock != nil, on != hidesMacDock else { return }
        hidesMacDock = on
        sendJSON(.setHideDock, RDSetHideDockMsg(enabled: on))
    }

    /// Changes the Mac's setting for blocking its own keyboard and trackpad; the Mac
    /// confirms with `hostState`.
    func setBlocksMacInput(_ on: Bool) {
        guard phase == .connected, blocksMacInput != nil else { return }
        blocksMacInput = on
        sendJSON(.setLocalInputBlock, RDSetLocalInputBlockMsg(enabled: on))
    }

    func requestHardwareControls() {
        guard phase == .connected else { return }
        send(.getHardwareControls, Data())
    }

    func setBrightness(_ value: Float) {
        guard phase == .connected else { return }
        hardwareControls.brightness = value
        sendJSON(.setHardwareControls, RDSetHardwareControlsMsg(brightness: value))
    }

    func setVolume(_ value: Int) {
        guard phase == .connected else { return }
        hardwareControls.volume = value
        sendJSON(.setHardwareControls, RDSetHardwareControlsMsg(volume: value))
    }

    func setMuted(_ value: Bool) {
        guard phase == .connected else { return }
        hardwareControls.isMuted = value
        sendJSON(.setHardwareControls, RDSetHardwareControlsMsg(isMuted: value))
    }

    func sleepHostDisplay() {
        sendJSON(.setHardwareControls, RDSetHardwareControlsMsg(sleepDisplay: true))
    }

    func lockHostScreen() {
        sendJSON(.setHardwareControls, RDSetHardwareControlsMsg(lockScreen: true))
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
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}

/// A short message about the session for the user (see `ClientSession.notice`).
struct SessionNotice: Equatable {
    let id: Int
    let symbol: String
    let text: String
    var isFailure = false
}
