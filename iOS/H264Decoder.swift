import Foundation
import CoreMedia
import VideoToolbox
import AVFoundation

final class H264Decoder {
    private var formatDescription: CMVideoFormatDescription?
    private var spsData: Data?
    private var ppsData: Data?

    func decode(annexB: Data, completion: (CMSampleBuffer) -> Void) {
        let naluRanges = extractNALURanges(from: annexB)
        guard !naluRanges.isEmpty else { return }

        var avccData = Data(capacity: annexB.count)

        for range in naluRanges {
            let nalu = annexB.subdata(in: range)
            guard !nalu.isEmpty else { continue }
            let naluType = nalu[0] & 0x1F

            if naluType == 7 { // SPS
                spsData = nalu
            } else if naluType == 8 { // PPS
                ppsData = nalu
            } else {
                var length = UInt32(nalu.count).bigEndian
                withUnsafeBytes(of: &length) { avccData.append(contentsOf: $0) }
                avccData.append(nalu)
            }
        }

        if let sps = spsData, let pps = ppsData {
            sps.withUnsafeBytes { spsBytes in
                pps.withUnsafeBytes { ppsBytes in
                    guard let spsPtr = spsBytes.bindMemory(to: UInt8.self).baseAddress,
                          let ppsPtr = ppsBytes.bindMemory(to: UInt8.self).baseAddress else { return }
                    let pointers = [spsPtr, ppsPtr]
                    let sizes = [sps.count, pps.count]
                    var newFormat: CMVideoFormatDescription?
                    let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 2,
                        parameterSetPointers: pointers,
                        parameterSetSizes: sizes,
                        nalUnitHeaderLength: 4,
                        formatDescriptionOut: &newFormat
                    )
                    if status == noErr, let format = newFormat {
                        self.formatDescription = format
                    }
                }
            }
        }

        guard let format = formatDescription, !avccData.isEmpty else { return }

        var blockBuffer: CMBlockBuffer?
        let memoryBlock = UnsafeMutableRawPointer.allocate(byteCount: avccData.count, alignment: 1)
        avccData.copyBytes(to: memoryBlock.assumingMemoryBound(to: UInt8.self), count: avccData.count)

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
            blockLength: avccData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: &customDeallocator,
            offsetToData: 0,
            dataLength: avccData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard blockStatus == noErr, let buffer = blockBuffer else {
            memoryBlock.deallocate()
            return
        }

        var sampleBuffer: CMSampleBuffer?
        var sampleSizeArray = [avccData.count]
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

        guard sampleStatus == noErr, let outSample = sampleBuffer else { return }

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
        spsData = nil
        ppsData = nil
    }
}
