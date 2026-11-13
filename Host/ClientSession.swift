import CoreGraphics
import CryptoKit
import Foundation
import Network

/// Tracks keys and mouse buttons pressed by one remote client on `@MainActor`
/// so they are always released in-order after any queued input events finish.
@MainActor
private final class HeldInputState: @unchecked Sendable {
    var buttons = Set<Int>()
    var keys = Set<UInt16>()

    func releaseAll() {
        InputInjector.release(buttons: buttons, keys: keys)
        buttons.removeAll()
        keys.removeAll()
    }
}

/// One client connection on the host: performs the v2 handshake and PIN/device
/// authentication, then relays input events to InputInjector and streams video
/// frames from ScreenStreamer. All networking, framing, cryptography, pacing,
/// and congestion state run on a dedicated `.userInteractive` serial queue so
/// AppKit/main-thread work never stalls video delivery or RTT pongs.
final class ClientSession: @unchecked Sendable {
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
    /// Stream receive chunk size (256 KiB reduces syscalls/wakeups on bulk bursts).
    private static let receiveChunkSize = 262_144

    private let queue: DispatchQueue
    private let connection: NWConnection
    /// The QUIC connection this session's stream belongs to (nil over TCP). Video moves
    /// to its datagrams once the client sends `videoDatagrams`, or onto a dedicated
    /// second QUIC stream (`videoStreamAttach`) if the client supports it.
    private let quicGroup: NWConnectionGroup?
    private weak var quicAcceptor: QUICAcceptor?
    /// SHA-256 of the host QUIC TLS leaf certificate, used to channel-bind QUIC sessions.
    private let quicTLSCertHash: Data?
    private var quicTLSBound = false

    private var videoKey: SymmetricKey?
    private var datagramFlow: NWConnection?
    private var packetizer: RDVideoPacketizer?
    private var pacer: DatagramPacer?
    /// The client follows `videoStream` (1.2.30 on), so lossy datagrams can be left.
    private var clientCanResumeStream = false
    private var clientFecEnabled = false
    private var clientWantsUnsealedDatagrams = false
    /// The client's `videoDatagrams` max size, until the stream has shown a good link.
    private var pendingDatagramOffer: Int?
    /// Video starts on the stream and moves to datagrams only after a `delivery` window
    /// with no frame held back and an average below this. Starting on datagrams, a lossy
    /// start (an iPad's Wi-Fi) lost keyframe pieces, each loss asked for another large
    /// keyframe, and the picture lagged or stalled for 10-15 s; the stream resends instead.
    private static let datagramSwitchMaxDelay: TimeInterval = 0.025
    /// Evaluates consecutive 5 s datagram windows with loss (`>= 3` lost frames in two windows triggers fallback).
    private var lossMonitor = DatagramLossMonitor()
    private var clientMaxDatagramSize = RDVideoDatagram.defaultMaxSize
    /// Set once the datagram flow is ready; cleared only by `resumeStreamVideo`, which
    /// tells the client where stream numbering goes on.
    private var videoOverDatagrams = false

    /// Dedicated 2nd QUIC stream for video (avoids HoL blocking with input/acks/pings).
    private var pendingVideoStream: NWConnection?
    private var videoStreamConnection: NWConnection?
    private var videoStreamReader = RDFrameReader()
    private var videoStreamSendCipher: RDCipher?
    private var videoStreamReceiveCipher: RDCipher?
    private var usingVideoStream = false

    /// Losses normally show as gaps in the client's acks. With nothing newer acked, an
    /// unconfirmed datagram frame counts as lost after `datagramLossTimeout` only while
    /// at most `isolatedLossFrames` are out (a lone frame lost on a still screen). More
    /// out means the link is backed up, not losing: Network.framework queues datagrams
    /// ahead of stream data, and writing them off at 300 ms let the host keep filling
    /// that queue until the device's pongs waited past its 8 s heartbeat (a 13-15 s
    /// stall when a session started). Then the host waits up to `datagramStallTimeout`.
    private static let datagramLossTimeout: TimeInterval = 0.3
    private static let isolatedLossFrames: UInt32 = 2
    private static let datagramStallTimeout: TimeInterval = 1.5
    /// Datagram frames lost since the last `delivery` log line.
    private var deliveryLost = 0

    private weak var server: HostServer?
    private let sessionGate: SessionGate?
    var sessionID: ObjectIdentifier { ObjectIdentifier(self) }

    /// The peer's IP, used to cap unauthenticated connections per address.
    let remoteAddress: String
    private var phase: Phase = .waitingHello
    private var helloInFlight = false
    private var reader = RDFrameReader()
    private var sendCipher: RDCipher?
    private var receiveCipher: RDCipher?
    private var transcript = Data()
    private var peerDeviceId = ""
    private var peerName = ""
    private(set) var clientSupportsAVCC = false
    private var pinFailures = 0
    private var pinCheckInFlight = false
    private var deviceAuthAttempted = false

    /// Cross-thread snapshots read from `@MainActor` (`HostServer`, `ClipboardSync`).
    private let sharedLock = NSLock()
    private var _peerDisplayName = "Client"
    private var _leftOnPurpose = false
    private var _sharesClipboard = false

    var peerDisplayName: String { withSharedLock { _peerDisplayName } }
    var leftOnPurpose: Bool { withSharedLock { _leftOnPurpose } }
    var sharesClipboard: Bool { withSharedLock { _sharesClipboard } }

    private func withSharedLock<T>(_ body: () -> T) -> T {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        return body()
    }

    // Flow control (confined to `queue`).
    private var outgoingFrames = 0
    /// Bumped whenever `outgoingFrames` is reset across a stream/datagram handoff so
    /// stale send completions never underflow the new channel's in-flight count.
    private var frameSendEpoch: UInt32 = 0
    private var needsKeyframeRecovery = false
    private var lastKeyframeRequestAt: TimeInterval = 0
    private var lastKeyframeSentAt: TimeInterval = 0
    private var bitrateFactor: Double = 1.0
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
    private static let encodeMaxUnackedFrames: UInt32 = 4
    private static let encodeMaxUnackedAge: TimeInterval = 0.08
    private static let sendMaxUnackedFrames: UInt32 = 8
    private static let sendMaxUnackedAge: TimeInterval = 0.25
    private static let coldStartAckThreshold: UInt32 = 3
    private static let coldStartFallbackAge: TimeInterval = 1.0
    private static let startupCongestionGrace: TimeInterval = 0.5

    // Input the client is holding down, released on @MainActor if the session ends mid-press.
    private let heldInput = HeldInputState()

    private var phaseStartedAt = Date()
    private var activeStartedAt: TimeInterval = 0
    private var lastActivityAt = Date()
    private var watchdogTimer: DispatchSourceTimer?
    /// Session messages received since the last startup diagnostics line.
    private var diagReceived: [RDWire: Int] = [:]

    /// The first 15 s of a session, once a second: what came in and how the video gate
    /// stands, to see which side stalls when a session starts without video.
    private func logStartupDiagnostics(_ now: Date) {
        guard now.timeIntervalSince(phaseStartedAt) <= 15 else { return }
        let received = diagReceived.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key)×\($0.value)" }.joined(separator: " ")
        diagReceived = [:]
        HostLog.write("startup \(peerDisplayName): in [\(received)] sent \(framesSent) acked \(framesAcked) "
                      + "out \(outgoingFrames) gate \(canSendFrame) datagrams \(videoOverDatagrams)")
    }

    /// Datagrams and the dedicated QUIC video stream do not share the control socket, so
    /// allowing 4 overlapping sends avoids false gate closes during startup/IDR bursts;
    /// the shared control stream keeps a tighter cap (2) so input never queues behind video.
    private var isColdStart: Bool {
        guard !videoOverDatagrams, usingVideoStream else { return false }
        if !clientAcksFrames {
            return ProcessInfo.processInfo.systemUptime - activeStartedAt < Self.coldStartFallbackAge
        }
        return framesAcked < Self.coldStartAckThreshold
    }

    private func gateAllowsSend(streamOutgoingCap: Int, maxUnacked: UInt32, maxAge: TimeInterval) -> Bool {
        guard phase == .active else { return false }
        let maxOutgoing = videoOverDatagrams ? 4 : (usingVideoStream ? streamOutgoingCap : 2)
        guard outgoingFrames < maxOutgoing else { return false }
        if !clientAcksFrames {
            if !videoOverDatagrams, usingVideoStream,
               ProcessInfo.processInfo.systemUptime - activeStartedAt < Self.coldStartFallbackAge {
                return framesSent < maxUnacked
            }
            return true
        }
        let unacked = framesSent &- framesAcked
        guard unacked > 0 else { return true }
        guard unacked < maxUnacked else { return false }
        let oldestSentAt = frameSentAt[Int((framesAcked &+ 1) % 32)]
        return ProcessInfo.processInfo.systemUptime - oldestSentAt < maxAge
    }

    /// Encode gate passed to `SessionGate`: stops capture early on backpressure so
    /// frames already inside VideoToolbox drain cleanly without triggering IDR recovery.
    private var canEncodeFrame: Bool {
        let cold = isColdStart
        return gateAllowsSend(
            streamOutgoingCap: cold ? 1 : 2,
            maxUnacked: cold ? 2 : Self.encodeMaxUnackedFrames,
            maxAge: Self.encodeMaxUnackedAge
        )
    }

    /// Hard send gate in `sendPackedVideo`: gives in-flight encoder frames headroom over Wi-Fi jitter.
    private var canSendFrame: Bool {
        let cold = isColdStart
        return gateAllowsSend(
            streamOutgoingCap: cold ? 2 : 3,
            maxUnacked: cold ? 4 : Self.sendMaxUnackedFrames,
            maxAge: Self.sendMaxUnackedAge
        )
    }

    private func notifyFrameGate() {
        let ready = canEncodeFrame
        if needsKeyframeRecovery, ready {
            requestRecoveryKeyframe()
        }
        sessionGate?.setCanSend(ready, for: sessionID)
    }

    init(connection: NWConnection,
         server: HostServer,
         sessionGate: SessionGate,
         remoteAddress: String,
         quicGroup: NWConnectionGroup? = nil,
         quicAcceptor: QUICAcceptor? = nil,
         quicTLSCertHash: Data? = nil,
         initialData: Data = Data()) {
        self.queue = DispatchQueue(label: "LocalDesktop.session.\(remoteAddress)", qos: .userInteractive)
        self.connection = connection
        self.initialData = initialData
        self.quicGroup = quicGroup
        self.quicAcceptor = quicAcceptor
        self.quicTLSCertHash = quicTLSCertHash
        self.server = server
        self.sessionGate = sessionGate
        self.remoteAddress = remoteAddress
        self.reader.maxPayload = RDService.maxHandshakePayload
    }

    private var initialData: Data

    func start() {
        queue.async { [self] in
            phaseStartedAt = Date()
            lastActivityAt = Date()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
            timer.setEventHandler { [weak self] in
                self?.checkTimeouts()
            }
            timer.resume()
            watchdogTimer = timer

            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                self.queue.async {
                    self.handleState(state)
                }
            }
            if connection.state == .setup {
                connection.start(queue: queue)
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
    }

    /// Ends the session. With a reason, an active client is sent `bye` first so it
    /// knows not to reconnect.
    func close(sendingBye reason: String? = nil) {
        queue.async { [self] in
            guard phase != .closed else { return }
            if let reason, phase == .active {
                sendOnControl(.bye, RDJSON.encode(ByeMsg(reason: reason)))
            }
            closeAfterFlush()
        }
    }

    /// Ends the session but lets messages already queued (a `bye` or `authFailed`)
    /// reach the client before the socket closes.
    private func closeAfterFlush() {
        guard phase != .closed else { return }
        let connection = self.connection
        let videoStream = self.videoStreamConnection ?? self.pendingVideoStream
        let group = quicGroup
        let queue = self.queue
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in
            connection.cancel()
            videoStream?.cancel()
            // Give the FIN a moment to leave before the whole QUIC connection closes.
            queue.asyncAfter(deadline: .now() + 0.5) { group?.cancel() }
        })
        finish(reason: nil, cancelConnection: false)
        // Don't wait forever on a client that stopped reading.
        queue.asyncAfter(deadline: .now() + 2) {
            connection.cancel()
            videoStream?.cancel()
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
                return
            }
            // Also here, not only when a frame is sent: with no confirmations the gate
            // stops the encoder, so no frame would come to reopen it.
            expireLostDatagramFrames()
            pollStalledDatagramWindow()
            notifyFrameGate()
            logStartupDiagnostics(now)
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
        watchdogTimer?.cancel()
        watchdogTimer = nil
        phase = .closed
        outgoingFrames = 0
        sessionGate?.unregister(self)

        if let quicGroup {
            quicAcceptor?.unregisterExtraStreamHandler(for: quicGroup)
        }

        let held = heldInput
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                held.releaseAll()
            }
        }

        pacer?.cancel()
        pacer = nil
        datagramFlow?.cancel()
        datagramFlow = nil

        if cancelConnection {
            pendingVideoStream?.cancel()
            videoStreamConnection?.cancel()
            connection.cancel()
            quicGroup?.cancel()
        }
        pendingVideoStream = nil
        videoStreamConnection = nil

        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.server?.sessionDidEnd(self)
            }
        }
    }

    // MARK: Sending

    private func sendOnControl(_ wire: RDWire, _ payload: Data) {
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
        let sendEpoch = frameSendEpoch
        if isVideo {
            outgoingFrames += 1
            framesSent &+= 1
            frameSentAt[Int(framesSent % 32)] = ProcessInfo.processInfo.systemUptime
            notifyFrameGate()
        }
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard self.phase != .closed else { return }
                if isVideo, self.frameSendEpoch == sendEpoch {
                    self.outgoingFrames = max(0, self.outgoingFrames - 1)
                    self.notifyFrameGate()
                }
                if let error {
                    self.finish(reason: error.localizedDescription)
                }
            }
        })
    }

    private func sendVideoFrameOnStream(_ payload: Data) {
        guard phase == .active else { return }
        guard usingVideoStream, let stream = videoStreamConnection else {
            sendOnControl(.frame, payload)
            return
        }
        let frame: Data
        if quicTLSBound {
            frame = RDFrame.pack(.frame, payload: payload)
        } else {
            guard let sealed = try? videoStreamSendCipher?.seal(.frame, payload) else {
                handleVideoStreamFailed(stream, reason: "encryption failed")
                sendOnControl(.frame, payload)
                return
            }
            frame = sealed
        }
        let sendEpoch = frameSendEpoch
        outgoingFrames += 1
        framesSent &+= 1
        frameSentAt[Int(framesSent % 32)] = ProcessInfo.processInfo.systemUptime
        notifyFrameGate()
        stream.send(content: frame, completion: .contentProcessed { [weak self, weak stream] error in
            guard let self, let stream else { return }
            self.queue.async {
                guard self.phase != .closed, self.videoStreamConnection === stream else { return }
                if self.frameSendEpoch == sendEpoch {
                    self.outgoingFrames = max(0, self.outgoingFrames - 1)
                    self.notifyFrameGate()
                }
                if let error {
                    self.handleVideoStreamFailed(stream, reason: error.localizedDescription)
                }
            }
        })
    }

    private func send<T: Encodable>(_ wire: RDWire, json message: T) {
        sendOnControl(wire, RDJSON.encode(message))
    }

    private func sendAuthFailed(_ reason: String, kind: RDAuthFailure, retryAfter: Double? = nil) {
        send(.authFailed, json: AuthFailedMsg(reason: reason, kind: kind, retryAfter: retryAfter))
    }

    /// Dispatches an encoded packet onto this session's serial queue (used for cached keyframe replay).
    func enqueueEncodedPacket(_ packet: EncodedVideoPacket) {
        queue.async { [self] in
            guard phase == .active else { return }
            let payload = clientSupportsAVCC ? packet.packAVCC() : packet.packAnnexB()
            sendPackedVideo(payload, isKeyframe: packet.isKeyframe)
        }
    }

    /// Dispatches an already wire-packed payload onto this session's serial queue (used by `SessionGate`).
    func enqueuePackedVideo(_ payload: Data, isKeyframe: Bool) {
        queue.async { [self] in
            sendPackedVideo(payload, isKeyframe: isKeyframe)
        }
    }

    private func sendPackedVideo(_ payload: Data, isKeyframe: Bool) {
        guard phase == .active else { return }

        // Drop non-keyframes while recovering to prevent sending corrupted P-frames
        if needsKeyframeRecovery && !isKeyframe {
            requestRecoveryKeyframe()
            return
        }

        expireLostDatagramFrames()
        let wasRecovering = needsKeyframeRecovery
        guard canSendFrame else {
            deliveryLog.held += 1
            needsKeyframeRecovery = true
            requestRecoveryKeyframe(forceImmediate: !wasRecovering || isKeyframe)
            notifyFrameGate()
            return
        }

        if isKeyframe {
            needsKeyframeRecovery = false
            lastKeyframeSentAt = ProcessInfo.processInfo.systemUptime
        }
        if videoOverDatagrams {
            sendVideoDatagrams(payload, isKeyframe: isKeyframe)
        } else {
            sendVideoFrameOnStream(payload)
        }
    }

    // MARK: Video datagrams (QUIC)

    /// The client asked for video as datagrams: open this connection's datagram flow
    /// and switch once it is ready. Until then frames keep going on the stream.
    private func startVideoDatagrams(maxSize: Int) {
        guard let quicGroup, datagramFlow == nil, let videoKey,
              let flow = RDQUIC.makeDatagramFlow(on: quicGroup) else { return }
        clientMaxDatagramSize = max(RDVideoDatagram.minPieceBody + RDVideoDatagram.overhead, maxSize)
        packetizer = RDVideoPacketizer(key: clientWantsUnsealedDatagrams ? nil : videoKey,
                                       fecEnabled: clientFecEnabled)
        datagramFlow = flow
        flow.stateUpdateHandler = { [weak self, weak flow] state in
            guard let self, let flow else { return }
            self.queue.async {
                guard self.datagramFlow === flow, self.phase != .closed else { return }
                switch state {
                case .ready:
                    self.pacer = DatagramPacer(flow: flow)
                    self.lossMonitor.reset()
                    self.deliveryLost = 0
                    self.usingVideoStream = false
                    let now = ProcessInfo.processInfo.systemUptime
                    self.deliveryLog = (start: now, sent: 0, acked: 0, total: 0, min: 1.0, max: 0.0, held: 0)
                    self.videoOverDatagrams = true
                    self.sessionGate?.setUsesDatagrams(true, for: self.sessionID)
                    self.notifyFrameGate()
                    HostLog.write("video datagrams for \(self.peerDisplayName): up to \(self.maxDatagramSize) bytes"
                                  + (self.clientFecEnabled ? " +FEC" : "")
                                  + (self.clientWantsUnsealedDatagrams ? " +TLSBound" : ""))
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
        flow.start(queue: queue)
    }

    private var maxDatagramSize: Int {
        let reported = datagramFlow?.maximumDatagramSize ?? 0
        return min(clientMaxDatagramSize, RDVideoDatagram.defaultMaxSize,
                   reported > 0 ? reported : RDVideoDatagram.defaultMaxSize)
    }

    /// Numbers the frame like a stream frame (same counter, same gate) and sends its pieces.
    private func sendVideoDatagrams(_ payload: Data, isKeyframe: Bool) {
        guard phase != .closed, let pacer, let packetizer else { return }
        framesSent &+= 1
        let number = framesSent
        frameSentAt[Int(number % 32)] = ProcessInfo.processInfo.systemUptime
        guard let datagrams = packetizer.datagrams(frame: number, payload: payload, isKeyframe: isKeyframe,
                                                   maxDatagramSize: maxDatagramSize) else {
            // Too large to send; the client sees a gap and asks for a keyframe.
            notifyFrameGate()
            return
        }
        let sendEpoch = frameSendEpoch
        outgoingFrames += 1
        notifyFrameGate()
        let rate = sessionGate?.currentEncoderBitrate ?? ScreenStreamer.sharedState.encoderBitrate
        pacer.setRate(bitsPerSecond: DatagramPacer.rate(forEncoderBitrate: rate))
        pacer.enqueue(datagrams) { [weak self, weak pacer] in
            guard let self, let pacer else { return }
            self.queue.async {
                // A pacer replaced by `resumeStreamVideo` no longer counts.
                guard self.phase != .closed, self.pacer === pacer else { return }
                if self.frameSendEpoch == sendEpoch {
                    self.outgoingFrames = max(0, self.outgoingFrames - 1)
                    self.notifyFrameGate()
                }
            }
        }
    }

    /// Datagrams kept losing frames: send video on the stream again, which resends
    /// instead of dropping. The datagram flow stays open, unused, since cancelling it
    /// could take the QUIC connection with it.
    private func resumeStreamVideo(lost: Int) {
        guard videoOverDatagrams, clientCanResumeStream, phase != .closed else { return }
        videoOverDatagrams = false
        sessionGate?.setUsesDatagrams(false, for: sessionID)
        pacer?.cancel()
        pacer = nil
        // Frames still in flight as datagrams will never be confirmed.
        framesAcked = framesSent
        frameSendEpoch &+= 1
        outgoingFrames = 0
        let onDedicated = videoStreamConnection != nil
        usingVideoStream = onDedicated
        send(.videoStream, json: VideoStreamMsg(nextFrame: framesSent &+ 1,
                                                onVideoStream: onDedicated ? true : nil,
                                                leavingDatagrams: true))
        HostLog.write("video for \(peerDisplayName) back on the \(onDedicated ? "dedicated " : "")QUIC stream: \(lost) frames lost in 5 s, twice")
        requestRecoveryKeyframe(forceImmediate: true)
        notifyFrameGate()
    }

    // MARK: Dedicated 2nd QUIC video stream

    private func handleExtraQUICStream(_ stream: NWConnection, initialData: Data) {
        guard phase == .active, pendingVideoStream == nil, videoStreamConnection == nil else {
            stream.cancel()
            return
        }
        pendingVideoStream = stream
        videoStreamReader.maxPayload = Self.maxClientPayload
        stream.stateUpdateHandler = { [weak self, weak stream] state in
            guard let self, let stream else { return }
            self.queue.async {
                guard self.phase != .closed,
                      (self.pendingVideoStream === stream || self.videoStreamConnection === stream) else { return }
                switch state {
                case .failed(let error):
                    self.handleVideoStreamFailed(stream, reason: error.localizedDescription)
                case .cancelled:
                    self.handleVideoStreamFailed(stream, reason: "cancelled")
                default:
                    break
                }
            }
        }
        if !initialData.isEmpty {
            videoStreamReader.append(initialData)
            processVideoStreamAttach()
        }
        videoStreamReceiveLoop(on: stream)
    }

    private func videoStreamReceiveLoop(on stream: NWConnection) {
        stream.receive(minimumIncompleteLength: 1, maximumLength: Self.receiveChunkSize) { [weak self, weak stream] chunk, _, isComplete, error in
            guard let self, let stream else { return }
            self.queue.async {
                guard self.phase != .closed,
                      (self.pendingVideoStream === stream || self.videoStreamConnection === stream) else { return }
                if let error {
                    self.handleVideoStreamFailed(stream, reason: error.localizedDescription)
                    return
                }
                if let chunk, !chunk.isEmpty, self.pendingVideoStream === stream {
                    self.videoStreamReader.append(chunk)
                    self.processVideoStreamAttach()
                }
                if isComplete {
                    self.handleVideoStreamFailed(stream, reason: "closed")
                    return
                }
                if self.phase != .closed,
                   (self.pendingVideoStream === stream || self.videoStreamConnection === stream) {
                    self.videoStreamReceiveLoop(on: stream)
                }
            }
        }
    }

    private func processVideoStreamAttach() {
        guard let stream = pendingVideoStream else { return }
        let frame: RDFrameData
        do {
            guard let next = try videoStreamReader.nextFrame() else { return }
            frame = next
        } catch {
            handleVideoStreamFailed(stream, reason: "bad attach frame")
            return
        }
        guard videoStreamReceiveCipher != nil,
              let plain = try? videoStreamReceiveCipher?.open(header: frame.header, body: frame.body),
              frame.wire == .videoStreamAttach,
              RDJSON.decode(VideoStreamAttachMsg.self, from: plain) != nil else {
            handleVideoStreamFailed(stream, reason: "invalid videoStreamAttach")
            return
        }
        pendingVideoStream = nil
        videoStreamConnection = stream
        if !videoOverDatagrams {
            usingVideoStream = true
            let next = framesSent &+ 1
            send(.videoStream, json: VideoStreamMsg(nextFrame: next, onVideoStream: true))
            HostLog.write("QUIC: dedicated video stream active for \(peerDisplayName) at frame \(next)")
        } else {
            HostLog.write("QUIC: dedicated video stream ready for \(peerDisplayName)")
        }
    }

    private func handleVideoStreamFailed(_ stream: NWConnection, reason: String) {
        guard pendingVideoStream === stream || videoStreamConnection === stream else { return }
        stream.cancel()
        if pendingVideoStream === stream { pendingVideoStream = nil }
        if videoStreamConnection === stream { videoStreamConnection = nil }
        if usingVideoStream {
            usingVideoStream = false
            frameSendEpoch &+= 1
            outgoingFrames = 0
            send(.videoStream, json: VideoStreamMsg(nextFrame: framesSent &+ 1, onVideoStream: false))
            requestRecoveryKeyframe(forceImmediate: true)
            notifyFrameGate()
            HostLog.write("QUIC: video stream fell back to control stream for \(peerDisplayName): \(reason)")
        }
    }

    /// A lost datagram frame is never acked on its own; once it is old enough, count it
    /// lost so the in-flight brake doesn't wait for it forever.
    private func expireLostDatagramFrames() {
        guard videoOverDatagrams else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var expired = false
        while framesSent != framesAcked, framesSent &- framesAcked < 32,
              now - frameSentAt[Int((framesAcked &+ 1) % 32)]
                > (framesSent &- framesAcked <= Self.isolatedLossFrames ? Self.datagramLossTimeout
                                                                         : Self.datagramStallTimeout) {
            framesAcked &+= 1
            deliveryLost += 1
            expired = true
        }
        if expired {
            notifyFrameGate()
        }
    }

    /// When UDP datagrams stop being acknowledged completely, `logDelivery` never runs;
    /// advance the 5 s loss window from the watchdog so unacked expirations still trigger fallback.
    private func pollStalledDatagramWindow() {
        guard videoOverDatagrams else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard let shouldResume = lossMonitor.pollIdleWindow(windowStart: deliveryLog.start,
                                                            now: now,
                                                            lost: deliveryLost) else { return }
        let lost = deliveryLost
        deliveryLost = 0
        deliveryLog = (start: now, sent: 0, acked: 0, total: 0.0, min: 1.0, max: 0.0, held: 0)
        if shouldResume {
            resumeStreamVideo(lost: lost)
        } else if lost > 0 {
            HostLog.write("delivery \(peerDisplayName) (UDP datagrams): 0 acked, \(lost) lost")
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
        let transport: String
        if videoOverDatagrams {
            transport = "QUIC datagrams"
        } else if usingVideoStream {
            transport = "QUIC video stream"
        } else if quicGroup != nil {
            transport = "QUIC stream"
        } else {
            transport = "TCP"
        }
        HostLog.write(String(format: "delivery %@ (%@): %.0f fps, %.0f/%.0f/%.0f ms min/avg/max, %d held back, %d lost, bitrate ×%.2f",
                             peerDisplayName, transport, Double(log.acked) / elapsed, log.min * 1000,
                             log.total / Double(log.sent) * 1000, log.max * 1000, log.held, deliveryLost, bitrateFactor))
        deliveryLog = (now, 0, 0, 0, 1, 0, 0)
        // Keep video on its dedicated QUIC stream whenever available: it already isolates
        // control/input from HoL blocking without UDP burst-loss stalls on Wi-Fi.
        if !usingVideoStream, let maxSize = pendingDatagramOffer, !videoOverDatagrams, log.held == 0,
           log.total / Double(log.sent) < Self.datagramSwitchMaxDelay {
            pendingDatagramOffer = nil
            startVideoDatagrams(maxSize: maxSize)
        }
        let lost = deliveryLost
        deliveryLost = 0
        if videoOverDatagrams, lossMonitor.evaluateWindow(lost: lost) {
            resumeStreamVideo(lost: lost)
        }
    }

    private func requestRecoveryKeyframe(forceImmediate: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        if !forceImmediate {
            guard now - lastKeyframeRequestAt > 0.2 else { return }
        }
        lastKeyframeRequestAt = now
        ScreenStreamer.requestKeyframe()
    }

    /// Whether this client wants to hear, after its clicks, if a text field has focus.
    private var wantsTextFocusReports = false
    private var textFocusCheck = 0
    private var clipboardImage = RDClipboardImageAssembler()

    /// Sends an encoded `clipboard` or a `clipboardImage` piece (see `ClipboardSync`).
    func sendClipboard(_ wire: RDWire, _ payload: Data) {
        queue.async { [self] in
            guard phase == .active, sharesClipboard else { return }
            sendOnControl(wire, payload)
        }
    }

    func sendHostState(_ state: HostStateMsg) {
        queue.async { [self] in
            guard phase == .active else { return }
            send(.hostState, json: state)
        }
    }

    func sendRunningApps(_ apps: [RDRunningApp]) {
        queue.async { [self] in
            guard phase == .active else { return }
            send(.runningApps, json: RDRunningAppsMsg(apps: apps))
        }
    }

    func sendHardwareControls(_ controls: RDHardwareControls) {
        queue.async { [self] in
            guard phase == .active else { return }
            send(.hardwareControlsState, json: controls)
        }
    }

    func sendDisplays(_ message: RDDisplaysMsg) {
        queue.async { [self] in
            guard phase == .active else { return }
            send(.displays, json: message)
        }
    }

    // MARK: Receiving

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.receiveChunkSize) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                guard self.phase != .closed else { return }
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
            let peerId = peerDeviceId
            let peerDisplay = peerName
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result = await AuthStore.shared.checkPIN(msg.pin)
                var trusted = false
                if case .accepted = result, msg.trust, let deviceKey = msg.deviceKey {
                    trusted = AuthStore.shared.trust(deviceId: peerId, name: peerDisplay, publicKey: deviceKey)
                }
                let isTrusted = trusted
                self.queue.async {
                    guard self.phase == .waitingAuth else { return }
                    self.pinCheckInFlight = false
                    self.handlePINResult(result, trusted: isTrusted)
                }
            }
        case (.waitingAuth, .authDevice):
            guard !deviceAuthAttempted, !pinCheckInFlight,
                  let msg = RDJSON.decode(AuthDeviceMsg.self, from: payload) else {
                finish(reason: "bad auth")
                return
            }
            deviceAuthAttempted = true
            let peerId = peerDeviceId
            let expectedProof = RDHandshake.deviceProof(transcript: transcript)
            let signature = msg.signature
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    let ok = AuthStore.shared.verifyDevice(deviceId: peerId, signature: signature, message: expectedProof)
                    guard let session = self else { return }
                    session.queue.async {
                        guard session.phase == .waitingAuth else { return }
                        if ok {
                            session.finishAuth(trusted: true)
                        } else {
                            session.sendAuthFailed("This device is no longer trusted. Enter the PIN.", kind: .untrusted)
                        }
                    }
                }
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
        guard !helloInFlight else { return }
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

        helloInFlight = true
        let certHash = quicGroup != nil ? quicTLSCertHash : nil
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                let store = AuthStore.shared
                let response = RDHandshake.respond(to: msg,
                                                   identityKey: store.identityPublicKey,
                                                   serverId: store.serverId,
                                                   serverName: HostServer.computerName,
                                                   tlsCertHash: certHash,
                                                   sign: store.signHandshake)
                guard let session = self else { return }
                session.queue.async {
                    guard session.phase == .waitingHello else { return }
                    session.helloInFlight = false
                    guard let response else {
                        session.finish(reason: "key exchange failed")
                        return
                    }
                    session.completeHello(msg: msg, response: response)
                }
            }
        }
    }

    private func completeHello(msg: HelloMsg, response: RDHandshake.HostResponse) {
        transcript = response.transcript
        peerDeviceId = msg.deviceId
        peerName = String(msg.deviceName.prefix(100))
        clientSupportsAVCC = msg.avcc == true
        quicTLSBound = response.serverHello.quicTLSBound == true
        let display = peerName.isEmpty ? (peerDeviceId.isEmpty ? "Client" : peerDeviceId) : peerName
        withSharedLock { _peerDisplayName = display }

        send(.serverHello, json: response.serverHello)
        let keys = response.keys
        sendCipher = RDCipher(key: keys.serverToClient)
        receiveCipher = RDCipher(key: keys.clientToServer)
        videoKey = keys.videoDatagrams
        videoStreamSendCipher = RDCipher(key: keys.videoStream)
        videoStreamReceiveCipher = RDCipher(key: keys.videoStream)
        phase = .waitingAuth
        phaseStartedAt = Date()
    }

    private func handlePINResult(_ result: AuthStore.PINCheck, trusted: Bool) {
        switch result {
        case .accepted:
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
        activeStartedAt = ProcessInfo.processInfo.systemUptime
        lastActivityAt = Date()
        reader.maxPayload = Self.maxClientPayload
        if let quicGroup, let quicAcceptor {
            quicAcceptor.registerExtraStreamHandler(for: quicGroup, handler: { [weak self] stream, initialData in
                guard let session = self else { return }
                session.queue.async {
                    session.handleExtraQUICStream(stream, initialData: initialData)
                }
            }, then: { [weak self] in
                guard let session = self else { return }
                session.queue.async {
                    session.completeAuthOK(trusted: trusted, supportsVideoStream: true)
                }
            })
        } else {
            completeAuthOK(trusted: trusted, supportsVideoStream: false)
        }
    }

    private func completeAuthOK(trusted: Bool, supportsVideoStream: Bool) {
        guard phase == .active else { return }
        sessionGate?.register(self, canSend: canEncodeFrame, bitrateFactor: bitrateFactor)
        send(.authOK, json: AuthOKMsg(serverName: HostServer.computerName,
                                      trusted: trusted,
                                      macAddress: getPrimaryMACAddress(),
                                      supportsVideoStream: supportsVideoStream ? true : nil,
                                      sizedMirrorAvailable: SizedMirror.isAvailable ? true : nil))
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.server?.sessionDidAuthenticate(self)
            }
        }
    }

    // MARK: Authenticated messages

    private func handleActive(_ wire: RDWire, payload: Data) {
        switch wire {
        case .setQuality, .wakeDisplay, .requestKeyframe, .ping, .networkStats, .frameAck, .videoDatagrams, .transportNote, .bye:
            handleSessionMessage(wire, payload: payload)
        case .mouseMoveAbs, .mouseMoveRel, .mouseDown, .mouseUp, .scroll, .keyEvent, .textEvent:
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
        diagReceived[wire, default: 0] += 1
        switch wire {
        case .setQuality:
            guard let msg = RDJSON.decode(SetQualityMsg.self, from: payload) else { return }
            let codec = RDCodec.from(msg.codec)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.server?.applyPresetFromClient(msg.preset, showRemoteCursor: msg.cursor, codec: codec)
                }
            }

        case .wakeDisplay:
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.server?.handleWakeDisplayRequest()
                }
            }

        case .requestKeyframe:
            let msg = RDJSON.decode(RequestKeyframeMsg.self, from: payload)
            let state = ScreenStreamer.sharedState
            state.requestKeyframe()
            if let keyframe = state.lastKeyframe, state.timeSinceLastFrame > 0.3 {
                let packed = clientSupportsAVCC ? keyframe.packAVCC() : keyframe.packAnnexB()
                sendPackedVideo(packed, isKeyframe: true)
            }
            if msg?.reason == "user_refresh" || state.timeSinceLastFrame > 1.5 {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.server?.handleRefreshVideoRequest()
                    }
                }
            } else {
                // `isRunning` is MainActor-isolated; if false, still check on main.
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        if !ScreenStreamer.shared.isRunning {
                            self?.server?.handleRefreshVideoRequest()
                        }
                    }
                }
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
                let now = ProcessInfo.processInfo.systemUptime
                let delay = now - frameSentAt[Int(count % 32)]
                logDelivery(delay: delay, frames: videoOverDatagrams ? 1 : Int(advance))
                let allowCut = (now - activeStartedAt) >= Self.startupCongestionGrace
                let maxFactor = sessionGate?.probingMaxFactor ?? 1.25
                let currentFactor = min(maxFactor, bitrateFactor)
                if let factor = congestion.add(delay: delay,
                                               factor: currentFactor,
                                               allowCut: allowCut,
                                               maxFactor: maxFactor,
                                               now: now) {
                    bitrateFactor = factor
                    sessionGate?.setBitrateFactor(factor, for: sessionID)
                } else if currentFactor != bitrateFactor {
                    bitrateFactor = currentFactor
                    sessionGate?.setBitrateFactor(currentFactor, for: sessionID)
                }
            }
            framesAcked = count
            clientAcksFrames = true
            notifyFrameGate()

        case .networkStats:
            // Clients that ack frames are measured from those acks instead.
            guard !clientAcksFrames else { return }
            guard let msg = RDJSON.decode(NetworkStatsMsg.self, from: payload) else { return }
            let maxFactor = sessionGate?.probingMaxFactor ?? 1.25
            if msg.rttMs > 45.0 || msg.droppedFrames > 0 {
                // Wi-Fi congestion or jitter detected - scale down bitrate by 20%
                bitrateFactor = max(0.35, min(maxFactor, bitrateFactor) * 0.8)
            } else if msg.rttMs < 18.0 {
                // Network is clear and fast - gradually scale up bitrate for higher fidelity
                bitrateFactor = min(maxFactor, bitrateFactor + 0.05)
            } else {
                bitrateFactor = min(maxFactor, bitrateFactor)
            }
            sessionGate?.setBitrateFactor(bitrateFactor, for: sessionID)

        case .transportNote:
            guard let msg = RDJSON.decode(TransportNoteMsg.self, from: payload) else { return }
            HostLog.write("QUIC: \(peerDisplayName) \(msg.quicFallback.prefix(1000))")

        case .videoDatagrams:
            guard let msg = RDJSON.decode(VideoDatagramsMsg.self, from: payload) else { return }
            clientCanResumeStream = msg.canResumeStream == true
            clientFecEnabled = msg.fec == true
            clientWantsUnsealedDatagrams = (msg.unsealed == true) && quicTLSBound
            pendingDatagramOffer = msg.maxSize

        case .bye:
            let onPurpose = RDJSON.decode(ByeMsg.self, from: payload)?.reason == RDByeReason.userDisconnect
            withSharedLock { _leftOnPurpose = onPurpose }
            finish(reason: "client disconnected")

        default:
            break
        }
    }

    private func handleInput(_ wire: RDWire, payload: Data) {
        switch wire {
        case .mouseMoveAbs:
            guard let msg = RDJSON.decode(MouseMoveAbsMsg.self, from: payload) else { return }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let server = self.server,
                          let point = server.globalPoint(x: msg.x, y: msg.y) else { return }
                    InputInjector.tickleUserActivity()
                    InputInjector.moveAbs(Double(point.x), Double(point.y), within: server.streamedDisplayBounds)
                    self.echoCursorPositionOnMain()
                }
            }

        case .mouseMoveRel:
            guard let msg = RDJSON.decode(MouseMoveRelMsg.self, from: payload) else { return }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let server = self.server else { return }
                    InputInjector.tickleUserActivity()
                    InputInjector.moveRel(dx: msg.dx, dy: msg.dy, within: server.streamedDisplayBounds)
                    self.echoCursorPositionOnMain()
                }
            }

        case .mouseDown:
            guard let msg = RDJSON.decode(MouseButtonMsg.self, from: payload), (0...1).contains(msg.button) else { return }
            let held = heldInput
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    InputInjector.tickleUserActivity()
                    held.buttons.insert(msg.button)
                    InputInjector.buttonDown(msg.button)
                }
            }

        case .mouseUp:
            guard let msg = RDJSON.decode(MouseButtonMsg.self, from: payload), (0...1).contains(msg.button) else { return }
            let checkFocus = wantsTextFocusReports && msg.button == 0
            let check: Int
            if checkFocus {
                textFocusCheck += 1
                check = textFocusCheck
            } else {
                check = 0
            }
            let held = heldInput
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    InputInjector.tickleUserActivity()
                    held.buttons.remove(msg.button)
                    InputInjector.buttonUp(msg.button)
                    guard checkFocus else { return }
                    TextFocusProbe.check { [weak self] editable in
                        guard let session = self else { return }
                        session.queue.async {
                            // Only the latest click's answer counts.
                            guard session.textFocusCheck == check, session.phase == .active else { return }
                            session.send(.textFocus, json: RDTextFocusMsg(editable: editable))
                        }
                    }
                }
            }

        case .scroll:
            guard let msg = RDJSON.decode(ScrollMsg.self, from: payload) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    InputInjector.tickleUserActivity()
                    InputInjector.scroll(dx: msg.dx, dy: msg.dy, precise: msg.precise ?? false)
                }
            }

        case .keyEvent:
            guard let msg = RDJSON.decode(KeyEventMsg.self, from: payload), msg.code < 128 else { return }
            let held = heldInput
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    InputInjector.tickleUserActivity()
                    if msg.down {
                        held.keys.insert(msg.code)
                    } else {
                        held.keys.remove(msg.code)
                    }
                    InputInjector.key(code: CGKeyCode(msg.code),
                                      down: msg.down,
                                      flags: InputInjector.flags(RDModifiers(rawValue: msg.flags)))
                    if msg.down, msg.code == RDKey.capsLock.rawValue {
                        self?.server?.capsLockMayHaveChanged()
                    }
                }
            }

        case .textEvent:
            guard let msg = RDJSON.decode(TextMsg.self, from: payload) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    InputInjector.tickleUserActivity()
                    InputInjector.text(msg.s)
                }
            }

        default:
            break
        }
    }

    @MainActor
    private func echoCursorPositionOnMain() {
        if let cur = server?.currentCursorInFrame() {
            queue.async { [self] in
                guard phase == .active else { return }
                send(.mouseMoveAbs, json: MouseMoveAbsMsg(x: cur.x, y: cur.y))
            }
        }
    }

    private func handleControl(_ wire: RDWire, payload: Data) {
        switch wire {
        case .setTextFocusReports:
            guard let msg = RDJSON.decode(RDSetTextFocusReportsMsg.self, from: payload) else { return }
            wantsTextFocusReports = msg.enabled

        case .setClipboardSharing:
            guard let msg = RDJSON.decode(RDSetClipboardSharingMsg.self, from: payload) else { return }
            withSharedLock { _sharesClipboard = msg.enabled }
            if !msg.enabled { clipboardImage.reset() }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.server?.clipboard.update() }
            }

        case .clipboard:
            guard sharesClipboard, let msg = RDJSON.decode(RDClipboardMsg.self, from: payload) else { return }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.server?.clipboard.receive(.text(msg.text), from: self)
                }
            }

        case .clipboardImage:
            guard sharesClipboard, let png = clipboardImage.add(payload) else { return }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.server?.clipboard.receive(.image(png), from: self)
                }
            }

        case .requestApps:
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let server = self.server else { return }
                    self.sendRunningApps(server.appSwitcher.runningApps())
                }
            }

        case .requestFrontWindow:
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    WindowActions.describe { window in
                        self?.send(.frontWindow, json: window)
                    }
                }
            }

        case .activateApp:
            guard let msg = RDJSON.decode(RDActivateAppMsg.self, from: payload) else { return }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.server?.appSwitcher.activate(bundleId: msg.bundleId) }
            }

        case .systemAction:
            guard let msg = RDJSON.decode(RDSystemActionMsg.self, from: payload) else { return }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let server = self.server else { return }
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
                        WindowActions.perform(msg.action) { window in
                            self.send(.frontWindow, json: window)
                        }
                    }
                }
            }

        case .getHardwareControls:
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.sendHardwareControls(HardwareController.getState())
                }
            }

        case .setHardwareControls:
            guard let msg = RDJSON.decode(RDSetHardwareControlsMsg.self, from: payload) else { return }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    if let b = msg.brightness { HardwareController.setBrightness(b) }
                    if let v = msg.volume { HardwareController.setVolume(v) }
                    if let m = msg.isMuted { HardwareController.setMuted(m) }
                    if msg.sleepDisplay == true { HardwareController.sleepDisplay() }
                    if msg.lockScreen == true { HardwareController.lockScreen() }
                    self?.sendHardwareControls(HardwareController.getState())
                }
            }

        case .selectDisplay:
            guard let msg = RDJSON.decode(RDSelectDisplayMsg.self, from: payload) else { return }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.server?.setDisplay(msg.id) }
            }

        case .setHideDock:
            guard let msg = RDJSON.decode(RDSetHideDockMsg.self, from: payload) else { return }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let server = self.server else { return }
                    server.setHidesDock(msg.enabled)
                    self.sendHostState(server.hostStateMessage)
                }
            }

        case .setSizedMirror:
            guard let msg = RDJSON.decode(RDSetSizedMirrorMsg.self, from: payload) else { return }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let server = self.server else { return }
                    server.setSizedMirror(msg.size)
                    // Tells the client the outcome even when nothing changed (e.g. it failed).
                    self.sendDisplays(server.displaysMessage)
                }
            }

        case .setLocalInputBlock:
            guard let msg = RDJSON.decode(RDSetLocalInputBlockMsg.self, from: payload) else { return }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let server = self.server else { return }
                    server.setBlocksLocalInput(msg.enabled)
                    // Confirms the setting even when it didn't change.
                    self.sendHostState(server.hostStateMessage)
                }
            }

        default:
            break
        }
    }
}
