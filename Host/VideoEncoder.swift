import Foundation
import CoreMedia
import VideoToolbox

// MARK: - VideoToolbox Hardware HEVC (H.265) & H.264 Encoder

final class HardwareVideoEncoder: @unchecked Sendable {
    private var session: VTCompressionSession?
    private var width: Int32 = 0
    private var height: Int32 = 0
    private var codec: RDCodec = .hevc
    /// Called on VideoToolbox's callback thread: data, isKeyframe, width, height, codec.
    var onPacket: ((Data, Bool, Int, Int, RDCodec) -> Void)?

    private let lock = NSLock()
    private var isTornDown = false

    private static let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

    func setup(width: Int32, height: Int32, fps: Int, bitrate: Int, codec: RDCodec = .hevc) {
        lock.lock()
        if let session, self.width == width, self.height == height, self.codec == codec, !isTornDown {
            // Same geometry and codec: only the rate settings changed.
            Self.applyRateSettings(session, fps: fps, bitrate: bitrate)
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
        Self.applyRateSettings(session, fps: fps, bitrate: bitrate)
        VTCompressionSessionPrepareToEncodeFrames(session)

        lock.lock()
        self.session = session
        lock.unlock()
    }

    private static func applyRateSettings(_ session: VTCompressionSession, fps: Int, bitrate: Int) {
        applyBitrate(session, bitrate)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: Int(Double(fps) * 2.5) as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 2.5 as CFTypeRef)
    }

    private static func applyBitrate(_ session: VTCompressionSession, _ bitrate: Int) {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFTypeRef)
        let bytesPerSecond = bitrate / 8
        let limits: [NSNumber] = [NSNumber(value: Int(Double(bytesPerSecond) * 2.5)), NSNumber(value: 1)]
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits as CFArray)
    }

    func setDynamicBitrate(_ newBitrate: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let session, !isTornDown, newBitrate > 0 else { return }
        Self.applyBitrate(session, newBitrate)
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

    /// Converts the AVCC sample to Annex B, prefixing parameter sets on keyframes.
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
        var packetData = Data()
        packetData.reserveCapacity(totalLength + (isKeyframe ? 256 : 0))

        if isKeyframe {
            Self.appendParameterSets(of: formatDesc, codec: codec, to: &packetData)
        }

        // The block buffer is usually contiguous; copy it out when it isn't.
        var avcc = Data()
        var lengthAtOffset = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let pointerStatus = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
                                                        totalLengthOut: nil, dataPointerOut: &dataPointer)
        if pointerStatus == noErr, let dataPointer, lengthAtOffset == totalLength {
            avcc = Data(bytesNoCopy: dataPointer, count: totalLength, deallocator: .none)
        } else {
            avcc = Data(count: totalLength)
            let copyStatus = avcc.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: totalLength, destination: base)
            }
            guard copyStatus == noErr else { return }
        }

        var offset = 0
        while offset + 4 <= avcc.count {
            let nalLength = Int(avcc.be32(at: offset))
            offset += 4
            guard nalLength > 0, offset + nalLength <= avcc.count else { break }
            packetData.append(contentsOf: Self.startCode)
            packetData.append(avcc[avcc.startIndex + offset..<avcc.startIndex + offset + nalLength])
            offset += nalLength
        }

        guard !packetData.isEmpty else { return }
        onPacket?(packetData, isKeyframe, Int(dimensions.width), Int(dimensions.height), codec)
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

    private static func appendParameterSets(of format: CMFormatDescription, codec: RDCodec, to packet: inout Data) {
        var count = 0
        guard parameterSet(of: format, codec: codec, index: 0, pointer: nil, size: nil, count: &count) == noErr else { return }
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            if parameterSet(of: format, codec: codec, index: index, pointer: &pointer, size: &size, count: nil) == noErr,
               let pointer, size > 0 {
                packet.append(contentsOf: startCode)
                packet.append(pointer, count: size)
            }
        }
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
