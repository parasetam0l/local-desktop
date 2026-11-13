import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit

/// State shared between the main actor and the capture / encoder threads.
/// Everything mutable is guarded by `lock`.
final class CaptureState: @unchecked Sendable {
    private let lock = NSLock()
    private var _frameSize: CGSize = .zero
    private var _lastKeyframe: EncodedVideoPacket?
    private var _lastFrameTime: Date = .distantPast
    private var _forceNextKeyframe = false
    private var _isCapturing = false
    private var _clientsReady = false
    /// The newest frame captured while no client could take one. The screen may not
    /// change again, so it is encoded as soon as a client can (otherwise the last
    /// keystroke or scroll step could stay missing on the device until the next change).
    private var _pendingFrame: (buffer: CVPixelBuffer, pts: CMTime)?
    /// The SCStream whose frames we accept; frames from a superseded stream are dropped.
    private var _activeStream: ObjectIdentifier?
    private var _onVideoPacket: ((EncodedVideoPacket) -> Void)?

    let encoder = HardwareVideoEncoder()
    var encoderBitrate: Int { encoder.currentBitrate }

    init() {
        encoder.onPacket = { [weak self] packet in
            guard let self else { return }
            self.lock.lock()
            self._frameSize = CGSize(width: packet.width, height: packet.height)
            if packet.isKeyframe {
                self._lastKeyframe = packet
            }
            let callback = self._onVideoPacket
            self.lock.unlock()

            callback?(packet)
        }
    }

    var onVideoPacket: ((EncodedVideoPacket) -> Void)? {
        get { withLock { _onVideoPacket } }
        set { withLock { _onVideoPacket = newValue } }
    }

    var frameSize: CGSize { withLock { _frameSize } }
    var lastKeyframe: EncodedVideoPacket? { withLock { _lastKeyframe } }
    var timeSinceLastFrame: TimeInterval { withLock { Date().timeIntervalSince(_lastFrameTime) } }

    func requestKeyframe() {
        withLock { _forceNextKeyframe = true }
    }

    /// Whether at least one client can take another frame. When none can, captured
    /// frames are not encoded at all, which keeps the encoder's reference chain intact.
    /// Returns whether frames became ready while one was held back.
    func setClientsReady(_ ready: Bool) -> Bool {
        withLock {
            let reopened = ready && !_clientsReady && _pendingFrame != nil
            _clientsReady = ready
            return reopened
        }
    }

    /// Encodes the frame held back while no client could take one. Runs on the capture queue.
    func encodePendingFrame() {
        lock.lock()
        guard _isCapturing, _clientsReady, let pending = _pendingFrame else {
            lock.unlock()
            return
        }
        _pendingFrame = nil
        let force = _forceNextKeyframe
        _forceNextKeyframe = false
        lock.unlock()
        encoder.encode(pixelBuffer: pending.buffer, pts: pending.pts, forceKeyframe: force)
    }

    func activate(stream: SCStream?) {
        withLock {
            _activeStream = stream.map(ObjectIdentifier.init)
            _isCapturing = stream != nil
            _pendingFrame = nil
            if stream != nil {
                _forceNextKeyframe = true
            }
        }
    }

    func resetStats() {
        withLock {
            _frameSize = .zero
            _lastKeyframe = nil
        }
    }

    func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, from stream: SCStream, of type: SCStreamOutputType) {
        lock.lock()
        guard _isCapturing, type == .screen, _activeStream == ObjectIdentifier(stream),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            lock.unlock()
            return
        }
        _lastFrameTime = Date()
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard _clientsReady else {
            _pendingFrame = (pixelBuffer, pts)
            lock.unlock()
            return
        }
        _pendingFrame = nil
        // Only consume a pending keyframe request when a frame is actually encoded.
        let force = _forceNextKeyframe
        _forceNextKeyframe = false
        lock.unlock()

        encoder.encode(pixelBuffer: pixelBuffer, pts: pts, forceKeyframe: force)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

// MARK: - ScreenStreamer

@MainActor
final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate {
    static let shared = ScreenStreamer()
    /// Shared capture/encoder state accessed off `@MainActor` by capture and session queues.
    nonisolated static let sharedState = CaptureState()
    nonisolated private static let captureQueue = DispatchQueue(label: "rd.capture", qos: .userInteractive)

    nonisolated let state = ScreenStreamer.sharedState

    /// Called on the encoder's callback thread.
    nonisolated var onVideoPacket: ((EncodedVideoPacket) -> Void)? {
        get { state.onVideoPacket }
        set { state.onVideoPacket = newValue }
    }

    /// The system ended a running capture; the streamer has already let go of it.
    var onCaptureStopped: ((Error) -> Void)?

    private(set) var currentDisplay: CGDirectDisplayID = CGMainDisplayID()
    nonisolated var frameSize: CGSize { state.frameSize }
    nonisolated var lastKeyframe: EncodedVideoPacket? { state.lastKeyframe }
    nonisolated var timeSinceLastFrame: TimeInterval { state.timeSinceLastFrame }

    private var stream: SCStream?
    private var preset: RDQualityPreset = .high
    private(set) var currentCodec: RDCodec = .hevc
    var showRemoteCursor: Bool = false
    private var runningDisplay: CGDirectDisplayID?
    nonisolated private var captureQueue: DispatchQueue { Self.captureQueue }
    private var restartDebounceTask: Task<Void, Error>?
    /// Bumped whenever capture is torn down, so a `start()` that was suspended
    /// while another start/stop ran knows it has been superseded.
    private var generation = 0

    private override init() {
        super.init()
    }

    var isRunning: Bool { stream != nil }

    private static let errorDomain = "rd.capture"
    private static let noDisplayCode = 1

    /// Whether capture failed only because no display is available, as happens while the
    /// lid is closed, the display sleeps or it's unplugged. That clears up on its own.
    static func isDisplayUnavailable(_ error: Error) -> Bool {
        let error = error as NSError
        switch error.domain {
        case SCStreamErrorDomain:
            return [SCStreamError.Code.noCaptureSource, .noDisplayList]
                .map(\.rawValue).contains(error.code)
        case errorDomain:
            return error.code == noDisplayCode
        default:
            return false
        }
    }

    nonisolated static func requestKeyframe() {
        sharedState.requestKeyframe()
    }

    nonisolated static func setClientsReady(_ ready: Bool) {
        if sharedState.setClientsReady(ready) {
            let state = sharedState
            captureQueue.async { state.encodePendingFrame() }
        }
    }

    nonisolated static func setDynamicBitrate(_ newBitrate: Int) {
        sharedState.encoder.setDynamicBitrate(newBitrate)
    }

    nonisolated static func setLossyDatagramMode(_ anyDatagrams: Bool) {
        sharedState.encoder.setKeyFrameIntervalDuration(anyDatagrams ? 2.5 : 30.0)
    }

    nonisolated func requestKeyframe() {
        Self.requestKeyframe()
    }

    nonisolated func setClientsReady(_ ready: Bool) {
        Self.setClientsReady(ready)
    }

    func start(displayID: CGDirectDisplayID?,
               preset newPreset: RDQualityPreset,
               codec: RDCodec = .hevc,
               targetBitrate: Int? = nil,
               forceRestart: Bool = false) async throws {
        let target = displayID ?? CGMainDisplayID()
        if !forceRestart, runningDisplay == target, stream != nil {
            if newPreset != preset || codec != currentCodec {
                await updateConfiguration(preset: newPreset, codec: codec, targetBitrate: targetBitrate)
            }
            return
        }
        teardownCapture()
        let myGeneration = generation

        let content = try await SCShareableContent.current
        guard myGeneration == generation else { throw CancellationError() }
        guard let display = content.displays.first(where: { $0.displayID == target }) ?? content.displays.first else {
            throw NSError(domain: Self.errorDomain, code: Self.noDisplayCode,
                          userInfo: [NSLocalizedDescriptionKey: "No capturable display found"])
        }

        preset = newPreset
        currentCodec = codec
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = makeConfiguration(for: display)

        state.encoder.setup(
            width: Int32(config.width),
            height: Int32(config.height),
            fps: preset.fps,
            bitrate: targetBitrate ?? preset.targetBitrate,
            codec: currentCodec
        )

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try await newStream.startCapture()
        guard myGeneration == generation else {
            // Another start/stop ran while we were starting; don't leave an orphan capturing.
            try? await newStream.stopCapture()
            throw CancellationError()
        }
        stream = newStream
        runningDisplay = display.displayID
        currentDisplay = display.displayID
        state.activate(stream: newStream)
    }

    /// Full restart; when `debounced` is true and a stream is already running, overlapping
    /// calls collapse after 150 ms. Cold starts and immediate switches skip the sleep.
    func restart(displayID: CGDirectDisplayID? = nil,
                 preset newPreset: RDQualityPreset? = nil,
                 codec: RDCodec? = nil,
                 targetBitrate: Int? = nil,
                 debounced: Bool = true) async throws {
        restartDebounceTask?.cancel()
        let targetID = displayID ?? runningDisplay ?? currentDisplay
        let targetPreset = newPreset ?? preset
        let targetCodec = codec ?? currentCodec

        let task = Task { @MainActor in
            if debounced, self.stream != nil {
                try await Task.sleep(nanoseconds: 150_000_000)
                try Task.checkCancellation()
            }
            try await self.start(displayID: targetID,
                                 preset: targetPreset,
                                 codec: targetCodec,
                                 targetBitrate: targetBitrate,
                                 forceRestart: true)
            self.requestKeyframe()
        }
        restartDebounceTask = task
        try await task.value
    }

    func updatePreset(_ newPreset: RDQualityPreset, targetBitrate: Int? = nil) async {
        await updateConfiguration(preset: newPreset, codec: currentCodec, targetBitrate: targetBitrate)
    }

    func updateConfiguration(preset newPreset: RDQualityPreset, codec newCodec: RDCodec, targetBitrate: Int? = nil) async {
        restartDebounceTask?.cancel()
        restartDebounceTask = nil
        preset = newPreset
        currentCodec = newCodec
        let effectiveBitrate = targetBitrate ?? preset.targetBitrate
        guard let stream else { return }
        let content = try? await SCShareableContent.current
        guard self.stream === stream,
              let display = content?.displays.first(where: { $0.displayID == runningDisplay }) ?? content?.displays.first else { return }
        let config = makeConfiguration(for: display)
        state.encoder.setup(
            width: Int32(config.width),
            height: Int32(config.height),
            fps: preset.fps,
            bitrate: effectiveBitrate,
            codec: currentCodec
        )
        do {
            try await stream.updateConfiguration(config)
            requestKeyframe()
        } catch {
            HostLog.write("capture updateConfiguration failed (\(error.localizedDescription)); restarting")
            try? await start(displayID: runningDisplay,
                             preset: preset,
                             codec: currentCodec,
                             targetBitrate: effectiveBitrate,
                             forceRestart: true)
            requestKeyframe()
        }
    }

    nonisolated func setDynamicBitrate(_ newBitrate: Int) {
        Self.setDynamicBitrate(newBitrate)
    }

    func stop() {
        restartDebounceTask?.cancel()
        restartDebounceTask = nil
        teardownCapture()
    }

    private func teardownCapture() {
        generation += 1
        state.activate(stream: nil)

        if let activeStream = stream {
            activeStream.stopCapture(completionHandler: nil)
            stream = nil
        }
        runningDisplay = nil
        state.resetStats()

        // Wait for any in-flight sample buffer callback to drain from captureQueue
        captureQueue.sync { }

        state.encoder.teardown()
    }

    private func makeConfiguration(for display: SCDisplay) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(preset.fps))
        config.queueDepth = 4
        config.showsCursor = showRemoteCursor
        // Native NV12 YUV 4:2:0 bi-planar video range for zero-copy hardware encoding
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorSpaceName = CGColorSpace.sRGB

        // CGDisplayPixelsWide returns LOGICAL resolution on Retina Macs (e.g. 1728x1117).
        // We need CGDisplayCopyDisplayMode to get the true physical pixel count (e.g. 3456x2234).
        let nativeWidth: Int
        let nativeHeight: Int
        if let mode = CGDisplayCopyDisplayMode(display.displayID) {
            nativeWidth = mode.pixelWidth
            nativeHeight = mode.pixelHeight
        } else {
            // Fallback: assume 2x Retina
            nativeWidth = display.width * 2
            nativeHeight = display.height * 2
        }

        if preset.maxDimension == 0 {
            config.width = nativeWidth
            config.height = nativeHeight
        } else {
            let maxNative = max(nativeWidth, nativeHeight)
            let scale = min(1.0, CGFloat(preset.maxDimension) / CGFloat(maxNative))
            config.width = max(640, Int(CGFloat(nativeWidth) * scale))
            config.height = max(360, Int(CGFloat(nativeHeight) * scale))
        }

        config.scalesToFit = true
        return config
    }

    // MARK: SCStreamOutput

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        state.processSampleBuffer(sampleBuffer, from: stream, of: type)
    }

    // MARK: SCStreamDelegate

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let stopped = ObjectIdentifier(stream)
        Task { @MainActor in
            // A stream that was already replaced or stopped isn't news.
            guard let current = self.stream, ObjectIdentifier(current) == stopped else { return }
            self.teardownCapture()
            self.onCaptureStopped?(error)
        }
    }
}
