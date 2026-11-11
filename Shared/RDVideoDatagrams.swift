import Foundation
import CryptoKit

/// Video frames as unreliable QUIC datagrams (QUIC only, from 1.2.29).
///
/// Each `frame` payload (`RDFrameCodec.pack` output) is split into pieces, one per
/// datagram:
///
///     [frame u32][piece u16][count u16][flags u8] | ChaChaPoly(piece body) | tag (16)
///
/// big-endian, `flags` bit 0 = keyframe. The 9-byte header is authenticated as
/// associated data. The stream cipher's implicit counter can't survive loss or
/// reordering, so datagrams use their own key (`SessionKeys.videoDatagrams`) and an
/// explicit nonce `[0x01 (host→client)][0 0 0][frame u32][piece u16][0 0]`; a
/// (frame, piece) pair is never sealed twice with one key.
enum RDVideoDatagram {
    static let headerSize = 9
    static let overhead = headerSize + 16
    /// The largest datagram sent. Network.framework reports the UDP payload size (1,472
    /// on Wi-Fi) as the QUIC flow's `maximumDatagramSize`, but QUIC's own header and tag
    /// come on top, so datagrams that size never arrived on an iPhone; 1,200 always fits.
    static let defaultMaxSize = 1200
    /// Bounds a frame to a few MB at the smallest piece size.
    static let maxPieces = 8192
    static let keyframeFlag: UInt8 = 0x01
    static let minPieceBody = 256

    static func nonce(frame: UInt32, piece: UInt16) -> ChaChaPoly.Nonce {
        var bytes = [UInt8](repeating: 0, count: 12)
        bytes[0] = 0x01
        bytes[4] = UInt8(frame >> 24)
        bytes[5] = UInt8(frame >> 16 & 0xFF)
        bytes[6] = UInt8(frame >> 8 & 0xFF)
        bytes[7] = UInt8(frame & 0xFF)
        bytes[8] = UInt8(piece >> 8)
        bytes[9] = UInt8(piece & 0xFF)
        // 12 bytes is always a valid ChaChaPoly nonce.
        return try! ChaChaPoly.Nonce(data: bytes)
    }

    static func header(frame: UInt32, piece: UInt16, count: UInt16, flags: UInt8) -> Data {
        Data([UInt8(frame >> 24), UInt8(frame >> 16 & 0xFF), UInt8(frame >> 8 & 0xFF), UInt8(frame & 0xFF),
              UInt8(piece >> 8), UInt8(piece & 0xFF), UInt8(count >> 8), UInt8(count & 0xFF), flags])
    }
}

/// Host side: seals one frame into datagrams.
struct RDVideoPacketizer {
    private let key: SymmetricKey

    init(key: SymmetricKey) {
        self.key = key
    }

    /// The datagrams for frame number `frame`, each at most `maxDatagramSize` bytes;
    /// nil if the frame would need more than `RDVideoDatagram.maxPieces` pieces.
    func datagrams(frame: UInt32, payload: Data, isKeyframe: Bool, maxDatagramSize: Int) -> [Data]? {
        let body = max(RDVideoDatagram.minPieceBody, maxDatagramSize - RDVideoDatagram.overhead)
        let count = max(1, (payload.count + body - 1) / body)
        guard count <= RDVideoDatagram.maxPieces else { return nil }
        let flags = isKeyframe ? RDVideoDatagram.keyframeFlag : 0
        var out: [Data] = []
        out.reserveCapacity(count)
        for index in 0..<count {
            let start = payload.startIndex + index * body
            let slice = payload[start..<min(payload.endIndex, start + body)]
            let header = RDVideoDatagram.header(frame: frame, piece: UInt16(index), count: UInt16(count), flags: flags)
            guard let sealed = try? ChaChaPoly.seal(slice, using: key,
                                                   nonce: RDVideoDatagram.nonce(frame: frame, piece: UInt16(index)),
                                                   authenticating: header) else { return nil }
            out.append(header + sealed.ciphertext + sealed.tag)
        }
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

    private struct Partial {
        let count: Int
        let flags: UInt8
        var pieces: [Data?]
        var received = 0
    }

    /// Frames being assembled at once; older ones are given up on beyond this.
    static let maxPartialFrames = 16

    private let key: SymmetricKey
    /// The highest frame number completed (delivered or discarded), by either path.
    private(set) var lastFrame: UInt32
    private(set) var awaitingKeyframe = false
    private var partial: [UInt32: Partial] = [:]

    init(key: SymmetricKey, lastFrame: UInt32 = 0) {
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
        let bytes = [UInt8](datagram)
        guard bytes.count >= RDVideoDatagram.overhead else { return output }
        let frame = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        let piece = Int(UInt16(bytes[4]) << 8 | UInt16(bytes[5]))
        let count = Int(UInt16(bytes[6]) << 8 | UInt16(bytes[7]))
        let flags = bytes[8]
        guard frame > lastFrame, count > 0, count <= RDVideoDatagram.maxPieces, piece < count else { return output }
        if let existing = partial[frame] {
            guard existing.count == count, existing.flags == flags, existing.pieces[piece] == nil else { return output }
        }
        let header = Data(bytes[0..<RDVideoDatagram.headerSize])
        let sealedBody = Data(bytes[RDVideoDatagram.headerSize..<(bytes.count - 16)])
        let tag = Data(bytes[(bytes.count - 16)...])
        guard let box = try? ChaChaPoly.SealedBox(nonce: RDVideoDatagram.nonce(frame: frame, piece: UInt16(piece)),
                                                 ciphertext: sealedBody, tag: tag),
              let plain = try? ChaChaPoly.open(box, using: key, authenticating: header) else { return output }

        var entry = partial[frame] ?? Partial(count: count, flags: flags, pieces: Array(repeating: nil, count: count))
        entry.pieces[piece] = plain
        entry.received += 1
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
            if flags & RDVideoDatagram.keyframeFlag != 0 {
                awaitingKeyframe = false
            } else {
                output.dropped += 1
                output.needsKeyframe = true
                return output
            }
        }
        output.frames.append(entry.pieces.reduce(into: Data()) { $0.append($1!) })
        return output
    }
}
