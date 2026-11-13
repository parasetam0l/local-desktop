import Foundation
import CryptoKit

/// Video frames as unreliable QUIC datagrams (QUIC only, from 1.2.29).
///
/// Each `frame` payload (`RDFrameCodec.pack` / `packAVCC` output) is split into pieces,
/// one per datagram:
///
///     [frame u32][piece u16][count u16][flags u8] | body [| tag (16)]
///
/// big-endian:
/// - `flags` bit 0 (`0x01`): keyframe
/// - `flags` bit 1 (`0x02`): XOR block-parity FEC packet covering `[groupStart ..< groupStart + groupLen]`
///
/// When `key != nil`, the body is sealed with ChaCha20-Poly1305 using the 9-byte header
/// as associated data and an explicit nonce `[0x01][parityFlag][0 0][frame u32][piece u16][0 0]`.
/// When `key == nil` (QUIC TLS channel-bound sessions), QUIC's TLS 1.3 AEAD already
/// authenticates and encrypts every datagram, avoiding double encryption.
enum RDVideoDatagram {
    static let headerSize = 9
    static let tagSize = 16
    static let overhead = headerSize + tagSize
    static let fecHeaderSize = 5
    static let fecGroupSize = 5
    /// The largest datagram sent. Network.framework reports the UDP payload size (1,472
    /// on Wi-Fi) as the QUIC flow's `maximumDatagramSize`, but QUIC's own header and tag
    /// come on top, so datagrams that size never arrived on an iPhone; 1,200 always fits.
    static let defaultMaxSize = 1200
    /// Bounds a frame to a few MB at the smallest piece size.
    static let maxPieces = 8192
    static let keyframeFlag: UInt8 = 0x01
    static let fecParityFlag: UInt8 = 0x02
    static let minPieceBody = 256

    static func nonce(frame: UInt32, piece: UInt16, isParity: Bool = false) -> ChaChaPoly.Nonce {
        var bytes = [UInt8](repeating: 0, count: 12)
        bytes[0] = 0x01
        bytes[1] = isParity ? 0x01 : 0x00
        bytes[4] = UInt8(frame >> 24)
        bytes[5] = UInt8(frame >> 16 & 0xFF)
        bytes[6] = UInt8(frame >> 8 & 0xFF)
        bytes[7] = UInt8(frame & 0xFF)
        bytes[8] = UInt8(piece >> 8)
        bytes[9] = UInt8(piece & 0xFF)
        return try! ChaChaPoly.Nonce(data: bytes)
    }

    static func header(frame: UInt32, piece: UInt16, count: UInt16, flags: UInt8) -> Data {
        Data([UInt8(frame >> 24), UInt8(frame >> 16 & 0xFF), UInt8(frame >> 8 & 0xFF), UInt8(frame & 0xFF),
              UInt8(piece >> 8), UInt8(piece & 0xFF), UInt8(count >> 8), UInt8(count & 0xFF), flags])
    }

    static func groupRanges(pieceCount: Int) -> [Range<Int>] {
        guard pieceCount >= 2 else { return [] }
        var ranges: [Range<Int>] = []
        var offset = 0
        while offset < pieceCount {
            let remaining = pieceCount - offset
            // Avoid leaving a trailing 1-piece remainder unprotected by splitting 6 as 3+3.
            let len = remaining == fecGroupSize + 1 ? 3 : min(fecGroupSize, remaining)
            ranges.append(offset..<(offset + len))
            offset += len
        }
        return ranges
    }
}

/// Host side: splits one frame into datagrams, optionally adding interleaved XOR parity packets.
struct RDVideoPacketizer {
    private let key: SymmetricKey?
    let fecEnabled: Bool

    init(key: SymmetricKey?, fecEnabled: Bool = false) {
        self.key = key
        self.fecEnabled = fecEnabled
    }

    /// The datagrams for frame number `frame`, each at most `maxDatagramSize` bytes;
    /// nil if the frame would need more than `RDVideoDatagram.maxPieces` pieces.
    func datagrams(frame: UInt32, payload: Data, isKeyframe: Bool, maxDatagramSize: Int) -> [Data]? {
        let tagLen = key == nil ? 0 : RDVideoDatagram.tagSize
        let baseOverhead = RDVideoDatagram.headerSize + tagLen
        let rawBody = max(RDVideoDatagram.minPieceBody, maxDatagramSize - baseOverhead)
        let rawCount = max(1, (payload.count + rawBody - 1) / rawBody)
        let emitFEC = fecEnabled && rawCount >= 2

        let body = emitFEC
            ? max(RDVideoDatagram.minPieceBody, maxDatagramSize - baseOverhead - RDVideoDatagram.fecHeaderSize)
            : rawBody
        let count = max(1, (payload.count + body - 1) / body)
        guard count <= RDVideoDatagram.maxPieces else { return nil }

        let baseFlags: UInt8 = isKeyframe ? RDVideoDatagram.keyframeFlag : 0
        var slices: [Data] = []
        slices.reserveCapacity(count)
        for index in 0..<count {
            let start = payload.startIndex + index * body
            slices.append(payload[start..<min(payload.endIndex, start + body)])
        }

        let groups = emitFEC ? RDVideoDatagram.groupRanges(pieceCount: count) : []
        var out: [Data] = []
        out.reserveCapacity(count + groups.count)

        func sealDatagram(header: Data, plaintext: Data, pieceIndex: UInt16, isParity: Bool) -> Data? {
            var packet = Data(capacity: header.count + plaintext.count + tagLen)
            packet.append(header)
            if let key {
                guard let sealed = try? ChaChaPoly.seal(plaintext,
                                                        using: key,
                                                        nonce: RDVideoDatagram.nonce(frame: frame, piece: pieceIndex, isParity: isParity),
                                                        authenticating: header) else { return nil }
                packet.append(sealed.ciphertext)
                packet.append(sealed.tag)
            } else {
                packet.append(plaintext)
            }
            return packet
        }

        if groups.isEmpty {
            for (index, slice) in slices.enumerated() {
                let header = RDVideoDatagram.header(frame: frame, piece: UInt16(index), count: UInt16(count), flags: baseFlags)
                guard let packet = sealDatagram(header: header, plaintext: slice, pieceIndex: UInt16(index), isParity: false) else { return nil }
                out.append(packet)
            }
            return out
        }

        var groupPackets: [[Data]] = []
        var parityPackets: [Data] = []
        groupPackets.reserveCapacity(groups.count)
        parityPackets.reserveCapacity(groups.count)

        for (groupIndex, range) in groups.enumerated() {
            var dataGroup: [Data] = []
            dataGroup.reserveCapacity(range.count)
            var maxLen = 0
            var xorLen: UInt16 = 0
            for idx in range {
                let len = slices[idx].count
                maxLen = max(maxLen, len)
                xorLen ^= UInt16(len)
                let header = RDVideoDatagram.header(frame: frame, piece: UInt16(idx), count: UInt16(count), flags: baseFlags)
                guard let packet = sealDatagram(header: header, plaintext: slices[idx], pieceIndex: UInt16(idx), isParity: false) else { return nil }
                dataGroup.append(packet)
            }
            groupPackets.append(dataGroup)

            var parityBody = Data(count: RDVideoDatagram.fecHeaderSize + maxLen)
            parityBody.withUnsafeMutableBytes { raw in
                let dst = raw.bindMemory(to: UInt8.self).baseAddress!
                let start = UInt16(range.lowerBound)
                dst[0] = UInt8(start >> 8)
                dst[1] = UInt8(start & 0xFF)
                dst[2] = UInt8(range.count)
                dst[3] = UInt8(xorLen >> 8)
                dst[4] = UInt8(xorLen & 0xFF)
                let xorPtr = dst.advanced(by: RDVideoDatagram.fecHeaderSize)
                for idx in range {
                    slices[idx].withUnsafeBytes { sliceRaw in
                        guard let src = sliceRaw.bindMemory(to: UInt8.self).baseAddress else { return }
                        for i in 0..<slices[idx].count {
                            xorPtr[i] ^= src[i]
                        }
                    }
                }
            }
            let parityHeader = RDVideoDatagram.header(frame: frame,
                                                      piece: UInt16(groupIndex),
                                                      count: UInt16(count),
                                                      flags: baseFlags | RDVideoDatagram.fecParityFlag)
            guard let parityPacket = sealDatagram(header: parityHeader,
                                                  plaintext: parityBody,
                                                  pieceIndex: UInt16(groupIndex),
                                                  isParity: true) else { return nil }
            parityPackets.append(parityPacket)
        }

        // Interleave data pieces round-robin across FEC groups so short Wi-Fi bursts
        // spread across groups instead of wiping two pieces from the same XOR block.
        let maxGroupLen = groupPackets.map(\.count).max() ?? 0
        for offset in 0..<maxGroupLen {
            for group in groupPackets where offset < group.count {
                out.append(group[offset])
            }
        }
        out.append(contentsOf: parityPackets)
        return out
    }
}

/// Client side: rebuilds frames from datagrams and hands them on complete and in order.
///
/// A frame still incomplete when a newer one completes is dropped. After a drop, frames
/// are discarded until the next keyframe (the decoder can't use P-frames whose
/// reference is missing), and `needsKeyframe` asks the caller to request one.
/// Anything at or below the last completed frame (old, duplicate or replayed) is ignored.
struct RDVideoReassembler {
    struct Output {
        /// Frames to decode, in order.
        var frames: [Data] = []
        /// Frames that will never be shown: skipped numbers and discarded P-frames.
        var dropped = 0
        /// A keyframe is needed to resume (the caller rate-limits its requests).
        var needsKeyframe = false
        /// Set when the highest completed frame number moved forward (for `frameAck`).
        var acked: UInt32?
    }

    private struct ParityBlock {
        let groupStart: Int
        let groupLen: Int
        let xorLength: Int
        let xorData: Data
    }

    private struct Partial {
        let count: Int
        let flags: UInt8
        var pieces: [Data?]
        var received = 0
        var parities: [Int: ParityBlock] = [:]
    }

    /// Frames being assembled at once; older ones are given up on beyond this.
    static let maxPartialFrames = 16

    private let key: SymmetricKey?
    /// The highest frame number completed (delivered or discarded), by either path.
    private(set) var lastFrame: UInt32
    private(set) var awaitingKeyframe = false
    private var partial: [UInt32: Partial] = [:]

    init(key: SymmetricKey?, lastFrame: UInt32 = 0) {
        self.key = key
        self.lastFrame = lastFrame
    }

    /// A frame that arrived on the reliable stream (numbered by its position there).
    /// Returns false when it is older than what datagrams already delivered: it must
    /// not be decoded, and the chain is broken until a keyframe.
    mutating func noteStreamFrame(_ number: UInt32) -> Bool {
        guard number > lastFrame else {
            awaitingKeyframe = true
            return false
        }
        lastFrame = number
        partial = partial.filter { $0.key > number }
        return true
    }

    mutating func receive(_ datagram: Data) -> Output {
        var output = Output()
        let minSize = RDVideoDatagram.headerSize + (key == nil ? 0 : RDVideoDatagram.tagSize)
        guard datagram.count >= minSize else { return output }

        let (frame, piece, count, flags) = datagram.withUnsafeBytes { raw -> (UInt32, Int, Int, UInt8) in
            let p = raw.bindMemory(to: UInt8.self).baseAddress!
            let f = UInt32(p[0]) << 24 | UInt32(p[1]) << 16 | UInt32(p[2]) << 8 | UInt32(p[3])
            let pi = Int(UInt16(p[4]) << 8 | UInt16(p[5]))
            let c = Int(UInt16(p[6]) << 8 | UInt16(p[7]))
            return (f, pi, c, p[8])
        }

        let isParity = (flags & RDVideoDatagram.fecParityFlag) != 0
        let baseFlags = flags & ~RDVideoDatagram.fecParityFlag
        guard frame > lastFrame, count > 0, count <= RDVideoDatagram.maxPieces else { return output }
        if !isParity {
            guard piece < count else { return output }
        } else {
            guard count >= 2 else { return output }
        }

        if let existing = partial[frame] {
            guard existing.count == count, existing.flags == baseFlags else { return output }
            if !isParity, existing.pieces[piece] != nil { return output }
        }

        let start = datagram.startIndex
        let headerSlice = datagram[start..<(start + RDVideoDatagram.headerSize)]
        let plain: Data
        if let key {
            let tagStart = datagram.endIndex - RDVideoDatagram.tagSize
            let sealedBody = datagram[(start + RDVideoDatagram.headerSize)..<tagStart]
            let tag = datagram[tagStart..<datagram.endIndex]
            guard let box = try? ChaChaPoly.SealedBox(nonce: RDVideoDatagram.nonce(frame: frame,
                                                                                   piece: UInt16(piece),
                                                                                   isParity: isParity),
                                                      ciphertext: sealedBody,
                                                      tag: tag),
                  let opened = try? ChaChaPoly.open(box, using: key, authenticating: headerSlice) else { return output }
            plain = opened
        } else {
            plain = datagram[(start + RDVideoDatagram.headerSize)..<datagram.endIndex]
        }

        var entry = partial[frame] ?? Partial(count: count, flags: baseFlags, pieces: Array(repeating: nil, count: count))
        if isParity {
            guard plain.count > RDVideoDatagram.fecHeaderSize else { return output }
            let (groupStart, groupLen, xorLength) = plain.withUnsafeBytes { raw -> (Int, Int, Int) in
                let p = raw.bindMemory(to: UInt8.self).baseAddress!
                let gs = Int(UInt16(p[0]) << 8 | UInt16(p[1]))
                let gl = Int(p[2])
                let xl = Int(UInt16(p[3]) << 8 | UInt16(p[4]))
                return (gs, gl, xl)
            }
            let xorPayload = plain[(plain.startIndex + RDVideoDatagram.fecHeaderSize)..<plain.endIndex]
            guard groupLen >= 2, groupStart + groupLen <= count,
                  xorPayload.count <= RDVideoDatagram.defaultMaxSize * 2,
                  entry.parities[groupStart] == nil else { return output }
            entry.parities[groupStart] = ParityBlock(groupStart: groupStart,
                                                     groupLen: groupLen,
                                                     xorLength: xorLength,
                                                     xorData: xorPayload)
        } else {
            entry.pieces[piece] = plain
            entry.received += 1
        }

        if !entry.parities.isEmpty, entry.received < entry.count {
            Self.recoverMissingPieces(in: &entry)
        }

        guard entry.received == entry.count else {
            partial[frame] = entry
            if partial.count > Self.maxPartialFrames, let oldest = partial.keys.min() {
                partial[oldest] = nil
            }
            return output
        }

        // Complete: everything older is given up on.
        partial[frame] = nil
        partial = partial.filter { $0.key > frame }
        let skipped = Int(frame - lastFrame - 1)
        lastFrame = frame
        output.acked = frame
        output.dropped = skipped
        if skipped > 0 {
            awaitingKeyframe = true
        }
        if awaitingKeyframe {
            if baseFlags & RDVideoDatagram.keyframeFlag != 0 {
                awaitingKeyframe = false
            } else {
                output.dropped += 1
                output.needsKeyframe = true
                return output
            }
        }
        let totalBytes = entry.pieces.reduce(0) { $0 + ($1?.count ?? 0) }
        var full = Data(capacity: totalBytes)
        for part in entry.pieces {
            if let part { full.append(part) }
        }
        output.frames.append(full)
        return output
    }

    private static func recoverMissingPieces(in entry: inout Partial) {
        var resolvedStarts: [Int] = []
        for (groupStart, block) in entry.parities {
            var missingIdx: Int?
            var missingCount = 0
            var presentXorLength = 0
            for idx in groupStart..<(groupStart + block.groupLen) {
                if let existing = entry.pieces[idx] {
                    presentXorLength ^= existing.count
                } else {
                    missingIdx = idx
                    missingCount += 1
                    if missingCount > 1 { break }
                }
            }
            if missingCount == 0 {
                resolvedStarts.append(groupStart)
                continue
            }
            guard missingCount == 1, let missingIdx else { continue }
            let recoveredLength = block.xorLength ^ presentXorLength
            guard recoveredLength > 0, recoveredLength <= block.xorData.count else {
                resolvedStarts.append(groupStart)
                continue
            }
            var recovered = Data(count: recoveredLength)
            recovered.withUnsafeMutableBytes { outRaw in
                guard let dst = outRaw.bindMemory(to: UInt8.self).baseAddress else { return }
                block.xorData.withUnsafeBytes { parityRaw in
                    guard let parity = parityRaw.bindMemory(to: UInt8.self).baseAddress else { return }
                    memcpy(dst, parity, recoveredLength)
                }
                for idx in groupStart..<(groupStart + block.groupLen) where idx != missingIdx {
                    guard let part = entry.pieces[idx] else { continue }
                    let limit = min(part.count, recoveredLength)
                    part.withUnsafeBytes { partRaw in
                        guard let src = partRaw.bindMemory(to: UInt8.self).baseAddress else { return }
                        for i in 0..<limit {
                            dst[i] ^= src[i]
                        }
                    }
                }
            }
            entry.pieces[missingIdx] = recovered
            entry.received += 1
            resolvedStarts.append(groupStart)
        }
        for start in resolvedStarts {
            entry.parities[start] = nil
        }
    }
}
