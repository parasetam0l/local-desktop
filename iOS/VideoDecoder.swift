import Foundation
import CoreMedia
import VideoToolbox
import AVFoundation

/// Repackages Annex-B access units into length-prefixed CMSampleBuffers for
/// AVSampleBufferDisplayLayer (which does the actual hardware decode).
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
        if currentCodec != codec {
            reset()
            currentCodec = codec
        }

        let naluRanges = extractNALURanges(from: annexB)
        guard !naluRanges.isEmpty else {
            onError?()
            return
        }

        var packetData = Data(capacity: annexB.count)

        for range in naluRanges {
            let nalu = annexB.subdata(in: range)
            guard !nalu.isEmpty else { continue }

            if codec == .hevc {
                let naluType = (nalu[0] >> 1) & 0x3F
                if naluType == 32 { // VPS
                    vpsData = nalu
                } else if naluType == 33 { // SPS
                    spsData = nalu
                } else if naluType == 34 { // PPS
                    ppsData = nalu
                } else {
                    var length = UInt32(nalu.count).bigEndian
                    withUnsafeBytes(of: &length) { packetData.append(contentsOf: $0) }
                    packetData.append(nalu)
                }
            } else {
                let naluType = nalu[0] & 0x1F
                if naluType == 7 { // SPS
                    spsData = nalu
                } else if naluType == 8 { // PPS
                    ppsData = nalu
                } else {
                    var length = UInt32(nalu.count).bigEndian
                    withUnsafeBytes(of: &length) { packetData.append(contentsOf: $0) }
                    packetData.append(nalu)
                }
            }
        }

        // Rebuild the format description only when the parameter sets actually change.
        let parameterSets: [Data]? = codec == .hevc
            ? vpsData.flatMap { vps in spsData.flatMap { sps in ppsData.map { [vps, sps, $0] } } }
            : spsData.flatMap { sps in ppsData.map { [sps, $0] } }
        if let parameterSets, formatDescription == nil || parameterSets != formatParameterSets,
           let format = Self.makeFormatDescription(codec: codec, parameterSets: parameterSets) {
            formatDescription = format
            formatParameterSets = parameterSets
        }

        guard let format = formatDescription, !packetData.isEmpty else {
            onError?()
            return
        }

        var blockBuffer: CMBlockBuffer?
        let memoryBlock = UnsafeMutableRawPointer.allocate(byteCount: packetData.count, alignment: 1)
        packetData.copyBytes(to: memoryBlock.assumingMemoryBound(to: UInt8.self), count: packetData.count)

        let deallocator = CMBlockBufferCustomBlockSource(
            version: 0,
            AllocateBlock: nil,
            FreeBlock: { _, memoryBlock, _ in
                memoryBlock.deallocate()
            },
            refCon: nil
        )
        var customDeallocator = deallocator

        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: memoryBlock,
            blockLength: packetData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: &customDeallocator,
            offsetToData: 0,
            dataLength: packetData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard blockStatus == noErr, let buffer = blockBuffer else {
            memoryBlock.deallocate()
            onError?()
            return
        }

        var sampleBuffer: CMSampleBuffer?
        var sampleSizeArray = [packetData.count]
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
        // Copy into stable buffers so every pointer stays valid for the call.
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

    private func extractNALURanges(from data: Data) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        let count = data.count
        guard count > 4 else { return [] }

        data.withUnsafeBytes { raw in
            guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var nalStart: Int? = nil
            var i = 0

            while i < count - 3 {
                if bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 0 && bytes[i+3] == 1 {
                    if let start = nalStart {
                        ranges.append(start..<i)
                    }
                    i += 4
                    nalStart = i
                    continue
                } else if bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 1 {
                    if let start = nalStart {
                        ranges.append(start..<i)
                    }
                    i += 3
                    nalStart = i
                    continue
                }
                i += 1
            }

            if let start = nalStart, start < count {
                ranges.append(start..<count)
            }
        }

        return ranges
    }

    func reset() {
        formatDescription = nil
        formatParameterSets = []
        vpsData = nil
        spsData = nil
        ppsData = nil
    }
}
