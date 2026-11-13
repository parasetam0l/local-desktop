import Foundation
import CoreMedia
import VideoToolbox
import AVFoundation
import QuartzCore

/// Feeds AVCC or Annex-B video frames into `CMBlockBuffer` / `CMSampleBuffer` for
/// `AVSampleBufferDisplayLayer` with a single allocation per frame.
/// Not thread-safe: `VideoPipeline` only uses it on its decode queue.
final class VideoDecoder {
    private var formatDescription: CMVideoFormatDescription?
    private var currentCodec: RDCodec?
    private var vpsData: Data?
    private var spsData: Data?
    private var ppsData: Data?
    /// Parameter sets the current format description was built from.
    private var formatParameterSets: [Data] = []

    func decode(annexB: Data, codec: RDCodec = .hevc, completion: (CMSampleBuffer) -> Void, onError: (() -> Void)? = nil) {
        decode(data: annexB, isAVCC: false, codec: codec, completion: completion, onError: onError)
    }

    func decode(data: Data, isAVCC: Bool, codec: RDCodec = .hevc, completion: (CMSampleBuffer) -> Void, onError: (() -> Void)? = nil) {
        if currentCodec != codec {
            reset()
            currentCodec = codec
        }

        if isAVCC {
            decodeAVCC(data: data, codec: codec, completion: completion, onError: onError)
        } else {
            decodeAnnexB(data: data, codec: codec, completion: completion, onError: onError)
        }
    }

    private func decodeAVCC(data: Data, codec: RDCodec, completion: (CMSampleBuffer) -> Void, onError: (() -> Void)? = nil) {
        var avccOffset = 0
        var incomingParameterSets: [Data]?
        var parseFailed = false

        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress, raw.count > 1 else {
                parseFailed = true
                return
            }
            let count = raw.count
            let paramCount = Int(base[0])
            var offset = 1

            if paramCount > 0 {
                var sets: [Data] = []
                sets.reserveCapacity(paramCount)
                for _ in 0..<paramCount {
                    guard offset + 2 <= count else {
                        parseFailed = true
                        return
                    }
                    let len = Int(UInt16(base[offset]) << 8 | UInt16(base[offset + 1]))
                    offset += 2
                    guard len > 0, offset + len <= count else {
                        parseFailed = true
                        return
                    }
                    sets.append(Data(bytes: base.advanced(by: offset), count: len))
                    offset += len
                }
                incomingParameterSets = sets
            }
            guard offset < count else {
                parseFailed = true
                return
            }
            avccOffset = offset
        }

        if parseFailed {
            onError?()
            return
        }

        if let sets = incomingParameterSets,
           formatDescription == nil || sets != formatParameterSets,
           let format = Self.makeFormatDescription(codec: codec, parameterSets: sets) {
            formatDescription = format
            formatParameterSets = sets
        }

        guard let format = formatDescription else {
            onError?()
            return
        }

        let avccLength = data.count - avccOffset
        guard avccLength > 4 else {
            onError?()
            return
        }

        let memoryBlock = UnsafeMutableRawPointer.allocate(byteCount: avccLength, alignment: 1)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(memoryBlock, base.advanced(by: avccOffset), avccLength)
        }
        emitSampleBuffer(memoryBlock: memoryBlock, byteCount: avccLength, format: format,
                         completion: completion, onError: onError)
    }

    private func decodeAnnexB(data: Data, codec: RDCodec, completion: (CMSampleBuffer) -> Void, onError: (() -> Void)? = nil) {
        guard data.count > 4 else {
            onError?()
            return
        }

        var vclRanges: [Range<Int>] = []
        var totalAVCCBytes = 0
        var newVPS: Data?
        var newSPS: Data?
        var newPPS: Data?

        data.withUnsafeBytes { raw in
            guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let count = raw.count
            var nalStart: Int?
            var i = 0

            func recordNALU(_ range: Range<Int>) {
                guard !range.isEmpty else { return }
                let firstByte = bytes[range.lowerBound]
                if codec == .hevc {
                    let naluType = (firstByte >> 1) & 0x3F
                    if naluType == 32 {
                        newVPS = Data(bytes: bytes.advanced(by: range.lowerBound), count: range.count)
                        return
                    } else if naluType == 33 {
                        newSPS = Data(bytes: bytes.advanced(by: range.lowerBound), count: range.count)
                        return
                    } else if naluType == 34 {
                        newPPS = Data(bytes: bytes.advanced(by: range.lowerBound), count: range.count)
                        return
                    }
                } else {
                    let naluType = firstByte & 0x1F
                    if naluType == 7 {
                        newSPS = Data(bytes: bytes.advanced(by: range.lowerBound), count: range.count)
                        return
                    } else if naluType == 8 {
                        newPPS = Data(bytes: bytes.advanced(by: range.lowerBound), count: range.count)
                        return
                    }
                }
                vclRanges.append(range)
                totalAVCCBytes += 4 + range.count
            }

            while i < count - 3 {
                if bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 0 && bytes[i + 3] == 1 {
                    if let start = nalStart { recordNALU(start..<i) }
                    i += 4
                    nalStart = i
                    continue
                } else if bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 {
                    if let start = nalStart { recordNALU(start..<i) }
                    i += 3
                    nalStart = i
                    continue
                }
                i += 1
            }

            if let start = nalStart, start < count {
                recordNALU(start..<count)
            }
        }

        if let newVPS { vpsData = newVPS }
        if let newSPS { spsData = newSPS }
        if let newPPS { ppsData = newPPS }

        let parameterSets: [Data]? = codec == .hevc
            ? vpsData.flatMap { vps in spsData.flatMap { sps in ppsData.map { [vps, sps, $0] } } }
            : spsData.flatMap { sps in ppsData.map { [sps, $0] } }
        if let parameterSets, formatDescription == nil || parameterSets != formatParameterSets,
           let format = Self.makeFormatDescription(codec: codec, parameterSets: parameterSets) {
            formatDescription = format
            formatParameterSets = parameterSets
        }

        guard let format = formatDescription, !vclRanges.isEmpty, totalAVCCBytes > 0 else {
            onError?()
            return
        }

        let memoryBlock = UnsafeMutableRawPointer.allocate(byteCount: totalAVCCBytes, alignment: 1)
        data.withUnsafeBytes { raw in
            guard let srcBase = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var dstOffset = 0
            let dstBytes = memoryBlock.assumingMemoryBound(to: UInt8.self)
            for range in vclRanges {
                let len = UInt32(range.count)
                dstBytes[dstOffset] = UInt8((len >> 24) & 0xFF)
                dstBytes[dstOffset + 1] = UInt8((len >> 16) & 0xFF)
                dstBytes[dstOffset + 2] = UInt8((len >> 8) & 0xFF)
                dstBytes[dstOffset + 3] = UInt8(len & 0xFF)
                dstOffset += 4
                memcpy(dstBytes.advanced(by: dstOffset), srcBase.advanced(by: range.lowerBound), range.count)
                dstOffset += range.count
            }
        }

        emitSampleBuffer(memoryBlock: memoryBlock, byteCount: totalAVCCBytes, format: format,
                         completion: completion, onError: onError)
    }

    private func emitSampleBuffer(memoryBlock: UnsafeMutableRawPointer,
                                  byteCount: Int,
                                  format: CMVideoFormatDescription,
                                  completion: (CMSampleBuffer) -> Void,
                                  onError: (() -> Void)?) {
        var blockBuffer: CMBlockBuffer?
        var customDeallocator = CMBlockBufferCustomBlockSource(
            version: 0,
            AllocateBlock: nil,
            FreeBlock: { _, block, _ in
                block.deallocate()
            },
            refCon: nil
        )

        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: memoryBlock,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: &customDeallocator,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard blockStatus == noErr, let buffer = blockBuffer else {
            memoryBlock.deallocate()
            onError?()
            return
        }

        var sampleBuffer: CMSampleBuffer?
        var sampleSizeArray = [byteCount]
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 1000),
            decodeTimeStamp: .invalid
        )

        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: buffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSizeArray,
            sampleBufferOut: &sampleBuffer
        )

        guard sampleStatus == noErr, let outSample = sampleBuffer else {
            onError?()
            return
        }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(outSample, createIfNecessary: true) {
            let count = CFArrayGetCount(attachments)
            if count > 0 {
                let dict = CFArrayGetValueAtIndex(attachments, 0)
                let mutableDict = unsafeBitCast(dict, to: CFMutableDictionary.self)
                CFDictionarySetValue(
                    mutableDict,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                )
                CFDictionarySetValue(
                    mutableDict,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_DoNotDisplay).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanFalse).toOpaque()
                )
            }
        }

        completion(outSample)
    }

    private static func makeFormatDescription(codec: RDCodec, parameterSets: [Data]) -> CMVideoFormatDescription? {
        let buffers = parameterSets.map { data -> UnsafeMutablePointer<UInt8> in
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, data.count))
            data.copyBytes(to: buffer, count: data.count)
            return buffer
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0) }
        let sizes = parameterSets.map(\.count)

        var format: CMVideoFormatDescription?
        let status: OSStatus
        if codec == .hevc {
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: pointers.count,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: 4,
                extensions: nil,
                formatDescriptionOut: &format
            )
        } else {
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: pointers.count,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: 4,
                formatDescriptionOut: &format
            )
        }
        return status == noErr ? format : nil
    }

    func reset() {
        formatDescription = nil
        formatParameterSets = []
        vpsData = nil
        spsData = nil
        ppsData = nil
    }
}
