import Foundation
import CoreMedia
import VideoToolbox

/// One encoded frame produced by `HardwareVideoEncoder`, stored in native VideoToolbox
/// AVCC format (`[u32 length BE][NALU]...`) with parameter sets extracted on keyframes.
struct EncodedVideoPacket: Sendable {
    let avccData: Data
    let parameterSets: [Data]
    let isKeyframe: Bool
    let width: Int
    let height: Int
    let codec: RDCodec

    private static let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

    /// Packs the packet in native AVCC wire format (zero NALU rewriting).
    func packAVCC() -> Data {
        RDFrameCodec.packAVCC(width: width, height: height, codec: codec,
                              parameterSets: parameterSets, data: avccData)
    }

    /// Converts the AVCC sample to legacy Annex-B wire format on demand for older peers.
    func packAnnexB() -> Data {
        RDFrameCodec.pack(width: width, height: height, codec: codec, data: annexBData())
    }

    func annexBData() -> Data {
        let paramBytes = parameterSets.reduce(0) { $0 + 4 + $1.count }
        var out = Data(capacity: paramBytes + avccData.count)
        for ps in parameterSets {
            out.append(contentsOf: Self.startCode)
            out.append(ps)
        }
        avccData.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let count = raw.count
            var offset = 0
            while offset + 4 <= count {
                let nalLength = Int(UInt32(base[offset]) << 24
                                    | UInt32(base[offset + 1]) << 16
                                    | UInt32(base[offset + 2]) << 8
                                    | UInt32(base[offset + 3]))
                offset += 4
                guard nalLength > 0, offset + nalLength <= count else { break }
                out.append(contentsOf: Self.startCode)
                out.append(base.advanced(by: offset), count: nalLength)
                offset += nalLength
            }
        }
        return out
    }
}

// MARK: - VideoToolbox Hardware HEVC (H.265) & H.264 Encoder

final class HardwareVideoEncoder: @unchecked Sendable {
    private var session: VTCompressionSession?
    private var width: Int32 = 0
    private var height: Int32 = 0
    private var codec: RDCodec = .hevc
    private var _fps: Int = 60
    private var _bitrate: Int = 20_000_000
    private var _keyframeIntervalSeconds: TimeInterval = 30.0
    /// Called on VideoToolbox's callback thread.
    var onPacket: ((EncodedVideoPacket) -> Void)?

    private let lock = NSLock()
    private var isTornDown = false

    var currentBitrate: Int {
        lock.lock()
        defer { lock.unlock() }
        return _bitrate
    }

    func setup(width: Int32, height: Int32, fps: Int, bitrate: Int, codec: RDCodec = .hevc) {
        lock.lock()
        _fps = fps
        _bitrate = bitrate
        let keyframeSeconds = _keyframeIntervalSeconds
        if let session, self.width == width, self.height == height, self.codec == codec, !isTornDown {
            // Same geometry and codec: only the rate settings changed.
            Self.applyRateSettings(session, fps: fps, bitrate: bitrate, keyframeSeconds: keyframeSeconds)
            lock.unlock()
            return
        }
        let oldSession = session
        session = nil
        isTornDown = false
        self.width = width
        self.height = height
        self.codec = codec
        lock.unlock()

        if let oldSession {
            VTCompressionSessionCompleteFrames(oldSession, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(oldSession)
        }

        var newSession: VTCompressionSession?
        let callback: VTCompressionOutputCallback = { outputCallbackRefCon, _, status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer, let refCon = outputCallbackRefCon else { return }
            let encoder = Unmanaged<HardwareVideoEncoder>.fromOpaque(refCon).takeUnretainedValue()
            encoder.handleSampleBuffer(sampleBuffer)
        }

        let codecType: CMVideoCodecType = (codec == .hevc) ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264

        func create(_ specification: CFDictionary?) -> OSStatus {
            VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: width,
                height: height,
                codecType: codecType,
                encoderSpecification: specification,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: callback,
                refcon: Unmanaged.passUnretained(self).toOpaque(),
                compressionSessionOut: &newSession
            )
        }
        // Low-latency rate control (Apple's mode for video calls) keeps each frame near
        // the average size instead of letting keyframes and busy frames burst, which on
        // Wi-Fi turns into queueing delay. Encoders without it get the normal mode.
        let lowLatency = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue] as CFDictionary
        var status = create(lowLatency)
        let usesLowLatency = status == noErr
        if !usesLowLatency {
            newSession = nil
            status = create(nil)
        }
        HostLog.write("encoder \(codec) \(width)x\(height), low-latency rate control \(usesLowLatency ? "on" : "unavailable")")

        guard status == noErr, let session = newSession else { return }

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
        Self.applyRateSettings(session, fps: fps, bitrate: bitrate, keyframeSeconds: keyframeSeconds)
        VTCompressionSessionPrepareToEncodeFrames(session)

        lock.lock()
        self.session = session
        if _keyframeIntervalSeconds != keyframeSeconds {
            Self.applyKeyframeInterval(session, fps: _fps, seconds: _keyframeIntervalSeconds)
        }
        if _bitrate != bitrate {
            Self.applyBitrate(session, _bitrate)
        }
        lock.unlock()
    }

    private static func applyRateSettings(_ session: VTCompressionSession,
                                        fps: Int,
                                        bitrate: Int,
                                        keyframeSeconds: TimeInterval) {
        applyBitrate(session, bitrate)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFTypeRef)
        applyKeyframeInterval(session, fps: fps, seconds: keyframeSeconds)
    }

    private static func applyKeyframeInterval(_ session: VTCompressionSession, fps: Int, seconds: TimeInterval) {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: max(1, Int(Double(fps) * seconds)) as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                             value: seconds as CFTypeRef)
    }

    private static func applyBitrate(_ session: VTCompressionSession, _ bitrate: Int) {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFTypeRef)
        let bytesPerSecond = bitrate / 8
        // At most 1.5× the average in any second: bursts above the link's rate wait in a
        // queue and show up as lag.
        let limits: [NSNumber] = [NSNumber(value: Int(Double(bytesPerSecond) * 1.5)), NSNumber(value: 1)]
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits as CFArray)
    }

    func setDynamicBitrate(_ newBitrate: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let session, !isTornDown, newBitrate > 0 else { return }
        _bitrate = newBitrate
        Self.applyBitrate(session, newBitrate)
    }

    /// Sets the periodic IDR interval (short on lossy UDP datagrams, long on reliable streams).
    func setKeyFrameIntervalDuration(_ seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        guard seconds > 0, seconds != _keyframeIntervalSeconds else { return }
        _keyframeIntervalSeconds = seconds
        guard let session, !isTornDown else { return }
        Self.applyKeyframeInterval(session, fps: _fps, seconds: seconds)
    }

    func encode(pixelBuffer: CVPixelBuffer, pts: CMTime, forceKeyframe: Bool = false) {
        lock.lock()
        guard let session, !isTornDown else {
            lock.unlock()
            return
        }
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
        lock.unlock()
    }

    /// Emits native AVCC bytes with parameter sets extracted on keyframes (zero NALU rewrite).
    private func handleSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        // Geometry and codec come from the sample itself, so frames still draining from
        // a session that is being replaced are labelled correctly.
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDesc)
        let codec: RDCodec = CMFormatDescriptionGetMediaSubType(formatDesc) == kCMVideoCodecType_HEVC ? .hevc : .h264

        let isKeyframe: Bool
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first {
            let notSync = (first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
            isKeyframe = !notSync
        } else {
            isKeyframe = true
        }

        let totalLength = CMBlockBufferGetDataLength(blockBuffer)
        guard totalLength > 0 else { return }

        let avccData: Data
        var lengthAtOffset = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let pointerStatus = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
                                                        totalLengthOut: nil, dataPointerOut: &dataPointer)
        if pointerStatus == noErr, let dataPointer, lengthAtOffset == totalLength {
            avccData = Data(bytes: dataPointer, count: totalLength)
        } else {
            var copied = Data(count: totalLength)
            let copyStatus = copied.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: totalLength, destination: base)
            }
            guard copyStatus == noErr else { return }
            avccData = copied
        }

        let parameterSets = isKeyframe ? Self.extractParameterSets(of: formatDesc, codec: codec) : []
        let packet = EncodedVideoPacket(
            avccData: avccData,
            parameterSets: parameterSets,
            isKeyframe: isKeyframe,
            width: Int(dimensions.width),
            height: Int(dimensions.height),
            codec: codec
        )
        onPacket?(packet)
    }

    /// Reads parameter set `index` (VPS/SPS/PPS for HEVC, SPS/PPS for H.264) and the total count.
    private static func parameterSet(of format: CMFormatDescription, codec: RDCodec, index: Int,
                                     pointer: UnsafeMutablePointer<UnsafePointer<UInt8>?>?,
                                     size: UnsafeMutablePointer<Int>?,
                                     count: UnsafeMutablePointer<Int>?) -> OSStatus {
        switch codec {
        case .hevc:
            return CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: pointer,
                parameterSetSizeOut: size, parameterSetCountOut: count, nalUnitHeaderLengthOut: nil)
        case .h264:
            return CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: pointer,
                parameterSetSizeOut: size, parameterSetCountOut: count, nalUnitHeaderLengthOut: nil)
        }
    }

    private static func extractParameterSets(of format: CMFormatDescription, codec: RDCodec) -> [Data] {
        var count = 0
        guard parameterSet(of: format, codec: codec, index: 0, pointer: nil, size: nil, count: &count) == noErr,
              count > 0 else { return [] }
        var sets: [Data] = []
        sets.reserveCapacity(count)
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            if parameterSet(of: format, codec: codec, index: index, pointer: &pointer, size: &size, count: nil) == noErr,
               let pointer, size > 0 {
                sets.append(Data(bytes: pointer, count: size))
            }
        }
        return sets
    }

    func teardown() {
        lock.lock()
        isTornDown = true
        let oldSession = session
        session = nil
        lock.unlock()

        if let oldSession {
            VTCompressionSessionCompleteFrames(oldSession, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(oldSession)
        }
    }
}
