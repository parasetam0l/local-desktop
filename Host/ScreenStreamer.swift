import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import VideoToolbox

struct DisplayInfo: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let label: String
}

// MARK: - VideoToolbox Hardware HEVC (H.265) & H.264 Encoder

final class HardwareVideoEncoder {
    private var session: VTCompressionSession?
    private var width: Int32 = 0
    private var height: Int32 = 0
    private(set) var codec: RDCodec = .hevc
    var onPacket: ((Data, Bool, Int, Int, RDCodec) -> Void)? // data, isKeyframe, width, height, codec

    func setup(width: Int32, height: Int32, fps: Int, bitrate: Int, codec: RDCodec = .hevc) {
        if session != nil && self.width == width && self.height == height && self.codec == codec { return }
        teardown()
        self.width = width
        self.height = height
        self.codec = codec

        var newSession: VTCompressionSession?
        let callback: VTCompressionOutputCallback = { outputCallbackRefCon, _, status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer, let refCon = outputCallbackRefCon else { return }
            let encoder = Unmanaged<HardwareVideoEncoder>.fromOpaque(refCon).takeUnretainedValue()
            encoder.handleSampleBuffer(sampleBuffer)
        }

        let codecType: CMVideoCodecType = (codec == .hevc) ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: codecType,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: callback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &newSession
        )

        guard status == noErr, let session = newSession else { return }
        self.session = session

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        if codec == .hevc {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)
        } else {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_H264EntropyMode, value: kVTH264EntropyMode_CABAC)
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFTypeRef)
        
        let bytesPerSecond = bitrate / 8
        let limits: [NSNumber] = [NSNumber(value: Int(Double(bytesPerSecond) * 2.5)), NSNumber(value: 1)]
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits as CFArray)
        
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: (fps * 10) as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 10.0 as CFTypeRef)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    func setDynamicBitrate(_ newBitrate: Int) {
        guard let session, newBitrate > 0 else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: newBitrate as CFTypeRef)
        let bytesPerSecond = newBitrate / 8
        let limits: [NSNumber] = [NSNumber(value: Int(Double(bytesPerSecond) * 2.5)), NSNumber(value: 1)]
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits as CFArray)
    }

    func encode(pixelBuffer: CVPixelBuffer, pts: CMTime, forceKeyframe: Bool = false) {
        guard let session else { return }
        var flags: VTEncodeInfoFlags = []
        var frameProperties: [String: Any]?
        if forceKeyframe {
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true]
        }
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: frameProperties as CFDictionary?,
            sourceFrameRefcon: nil,
            infoFlagsOut: &flags
        )
    }

    private func handleSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        let isKeyframe: Bool
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first {
            let notSync = (first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
            isKeyframe = !notSync
        } else {
            isKeyframe = true
        }

        var packetData = Data()
        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

        if isKeyframe {
            var parameterSetCount = 0
            if codec == .hevc {
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    formatDesc,
                    parameterSetIndex: 0,
                    parameterSetPointerOut: nil,
                    parameterSetSizeOut: nil,
                    parameterSetCountOut: &parameterSetCount,
                    nalUnitHeaderLengthOut: nil
                )

                for i in 0..<parameterSetCount {
                    var ptr: UnsafePointer<UInt8>?
                    var size = 0
                    let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                        formatDesc,
                        parameterSetIndex: i,
                        parameterSetPointerOut: &ptr,
                        parameterSetSizeOut: &size,
                        parameterSetCountOut: nil,
                        nalUnitHeaderLengthOut: nil
                    )
                    if status == noErr, let ptr, size > 0 {
                        packetData.append(contentsOf: startCode)
                        packetData.append(ptr, count: size)
                    }
                }
            } else {
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    formatDesc,
                    parameterSetIndex: 0,
                    parameterSetPointerOut: nil,
                    parameterSetSizeOut: nil,
                    parameterSetCountOut: &parameterSetCount,
                    nalUnitHeaderLengthOut: nil
                )

                for i in 0..<parameterSetCount {
                    var ptr: UnsafePointer<UInt8>?
                    var size = 0
                    let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        formatDesc,
                        parameterSetIndex: i,
                        parameterSetPointerOut: &ptr,
                        parameterSetSizeOut: &size,
                        parameterSetCountOut: nil,
                        nalUnitHeaderLengthOut: nil
                    )
                    if status == noErr, let ptr, size > 0 {
                        packetData.append(contentsOf: startCode)
                        packetData.append(ptr, count: size)
                    }
                }
            }
        }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let blockStatus = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )

        if blockStatus == noErr, let dataPointer, totalLength > 0 {
            var bufferOffset = 0

            while bufferOffset < totalLength - 4 {
                var nalUnitLength: UInt32 = 0
                memcpy(&nalUnitLength, dataPointer + bufferOffset, 4)
                nalUnitLength = CFSwapInt32BigToHost(nalUnitLength)
                bufferOffset += 4

                guard bufferOffset + Int(nalUnitLength) <= totalLength else { break }

                packetData.append(contentsOf: startCode)
                let nalPtr = UnsafeRawPointer(dataPointer + bufferOffset).assumingMemoryBound(to: UInt8.self)
                packetData.append(nalPtr, count: Int(nalUnitLength))
                bufferOffset += Int(nalUnitLength)
            }
        }

        guard !packetData.isEmpty else { return }
        onPacket?(packetData, isKeyframe, Int(width), Int(height), codec)
    }

    func teardown() {
        if let session {
            VTCompressionSessionInvalidate(session)
            self.session = nil
        }
    }
}

// MARK: - ScreenStreamer

final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate {
    static let shared = ScreenStreamer()

    var onVideoPacket: ((Data, Int, Int, RDCodec) -> Void)?
    var onError: ((String) -> Void)?
    var isReady: (() -> Bool)?

    private(set) var currentDisplay: CGDirectDisplayID = CGMainDisplayID()
    private(set) var frameSize: CGSize = .zero
    private(set) var lastKeyframe: (data: Data, width: Int, height: Int, codec: RDCodec)?
    private(set) var framesEmitted = 0
    private(set) var lastFrameTime: Date = .distantPast

    var timeSinceLastFrame: TimeInterval {
        Date().timeIntervalSince(lastFrameTime)
    }

    private var stream: SCStream?
    private var preset: RDQualityPreset = .high
    private(set) var currentCodec: RDCodec = .hevc
    var showRemoteCursor: Bool = false
    private var runningDisplay: CGDirectDisplayID?
    private let captureQueue = DispatchQueue(label: "rd.capture", qos: .userInteractive)
    private let encoder = HardwareVideoEncoder()
    private var forceNextKeyframe = false

    private override init() {
        super.init()
        encoder.onPacket = { [weak self] data, isKeyframe, width, height, codec in
            guard let self else { return }
            self.frameSize = CGSize(width: width, height: height)
            if isKeyframe {
                self.lastKeyframe = (data, width, height, codec)
            }
            self.framesEmitted += 1
            self.onVideoPacket?(data, width, height, codec)
        }
    }

    var isRunning: Bool { stream != nil }

    func requestKeyframe() {
        forceNextKeyframe = true
    }

    func loadDisplays() async -> [DisplayInfo] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            onError?("Screen recording permission is required. \(error.localizedDescription)")
            return []
        }
        return content.displays.map {
            DisplayInfo(id: $0.displayID, label: "\($0.width)×\($0.height)")
        }
    }

    func start(displayID: CGDirectDisplayID?, preset newPreset: RDQualityPreset, codec: RDCodec = .hevc, forceRestart: Bool = false) async throws {
        let target = displayID ?? CGMainDisplayID()
        if !forceRestart, runningDisplay == target, stream != nil {
            if newPreset != preset || codec != currentCodec {
                await updateConfiguration(preset: newPreset, codec: codec)
            }
            return
        }
        stop()

        let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: { $0.displayID == target }) ?? content.displays.first else {
            throw NSError(domain: "rd.capture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No capturable display found"])
        }

        preset = newPreset
        currentCodec = codec
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = makeConfiguration(for: display)
        
        encoder.setup(
            width: Int32(config.width),
            height: Int32(config.height),
            fps: preset.fps,
            bitrate: preset.targetBitrate,
            codec: currentCodec
        )

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try await newStream.startCapture()
        stream = newStream
        runningDisplay = display.displayID
        currentDisplay = display.displayID
        forceNextKeyframe = true
    }

    func restart(displayID: CGDirectDisplayID? = nil, preset newPreset: RDQualityPreset? = nil, codec: RDCodec? = nil) async throws {
        let targetID = displayID ?? runningDisplay ?? CGMainDisplayID()
        let targetPreset = newPreset ?? preset
        let targetCodec = codec ?? currentCodec
        try await start(displayID: targetID, preset: targetPreset, codec: targetCodec, forceRestart: true)
        requestKeyframe()
    }

    func updatePreset(_ newPreset: RDQualityPreset) async {
        await updateConfiguration(preset: newPreset, codec: currentCodec)
    }

    func updateConfiguration(preset newPreset: RDQualityPreset, codec newCodec: RDCodec) async {
        preset = newPreset
        currentCodec = newCodec
        guard let stream else { return }
        let content = try? await SCShareableContent.current
        if let display = content?.displays.first(where: { $0.displayID == runningDisplay }) ?? content?.displays.first {
            let config = makeConfiguration(for: display)
            encoder.setup(
                width: Int32(config.width),
                height: Int32(config.height),
                fps: preset.fps,
                bitrate: preset.targetBitrate,
                codec: currentCodec
            )
            try? await stream.updateConfiguration(config)
            requestKeyframe()
        }
    }

    func setDynamicBitrate(_ newBitrate: Int) {
        encoder.setDynamicBitrate(newBitrate)
    }

    func stop() {
        stream?.stopCapture { _ in }
        stream = nil
        runningDisplay = nil
        frameSize = .zero
        framesEmitted = 0
        lastKeyframe = nil
        encoder.teardown()
    }

    private func makeConfiguration(for display: SCDisplay) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(preset.fps))
        config.queueDepth = 3
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

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrameTime = Date()
        if let isReady, !isReady() { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let force = forceNextKeyframe
        if force {
            forceNextKeyframe = false
        }
        encoder.encode(pixelBuffer: pixelBuffer, pts: pts, forceKeyframe: force)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.onError?("Screen capture stopped: \(error.localizedDescription)")
        }
    }
}
