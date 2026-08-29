import Foundation
import CoreMedia
import VideoToolbox
import AVFoundation

final class VideoDecoder {
    private var formatDescription: CMVideoFormatDescription?
    private var currentCodec: RDCodec?
    private var vpsData: Data?
    private var spsData: Data?
    private var ppsData: Data?

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

        if codec == .hevc {
            if let vps = vpsData, let sps = spsData, let pps = ppsData {
                vps.withUnsafeBytes { vpsBytes in
                    sps.withUnsafeBytes { spsBytes in
                        pps.withUnsafeBytes { ppsBytes in
                            guard let vpsPtr = vpsBytes.bindMemory(to: UInt8.self).baseAddress,
                                  let spsPtr = spsBytes.bindMemory(to: UInt8.self).baseAddress,
                                  let ppsPtr = ppsBytes.bindMemory(to: UInt8.self).baseAddress else { return }
                            let pointers = [vpsPtr, spsPtr, ppsPtr]
                            let sizes = [vps.count, sps.count, pps.count]
                            var newFormat: CMVideoFormatDescription?
                            let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                                allocator: kCFAllocatorDefault,
                                parameterSetCount: 3,
                                parameterSetPointers: pointers,
                                parameterSetSizes: sizes,
                                nalUnitHeaderLength: 4,
                                extensions: nil,
                                formatDescriptionOut: &newFormat
                            )
                            if status == noErr, let format = newFormat {
                                self.formatDescription = format
                            }
                        }
                    }
                }
            }
        } else {
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
        vpsData = nil
        spsData = nil
        ppsData = nil
    }
}

typealias H264Decoder = VideoDecoder
