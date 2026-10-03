import Foundation
import CryptoKit

enum RDChannelError: Error {
    case malformedFrame
}

/// One direction of an encrypted session.
///
/// Every message is sealed with ChaCha20-Poly1305 under a key used only for this
/// direction. The nonce is a 64-bit message counter that both ends track and that is
/// never sent, and the 5-byte frame header is authenticated as associated data.
/// A replayed, reordered, dropped, or re-typed message therefore fails to open.
struct RDCipher {
    static let tagLength = 16

    private let key: SymmetricKey
    private var counter: UInt64 = 0

    init(key: SymmetricKey) {
        self.key = key
    }

    /// Seals `plaintext` and returns the complete wire frame (header + ciphertext + tag).
    mutating func seal(_ wire: RDWire, _ plaintext: Data) throws -> Data {
        let header = RDFrame.header(wire, length: plaintext.count + Self.tagLength)
        let sealed = try ChaChaPoly.seal(plaintext, using: key, nonce: nextNonce(), authenticating: header)
        var frame = Data(capacity: header.count + plaintext.count + Self.tagLength)
        frame.append(header)
        frame.append(sealed.ciphertext)
        frame.append(sealed.tag)
        return frame
    }

    /// Opens the body of a frame whose 5-byte header was `header`.
    mutating func open(header: Data, body: Data) throws -> Data {
        guard body.count >= Self.tagLength else { throw RDChannelError.malformedFrame }
        let tagStart = body.endIndex - Self.tagLength
        let box = try ChaChaPoly.SealedBox(nonce: nextNonce(),
                                           ciphertext: body[body.startIndex..<tagStart],
                                           tag: body[tagStart...])
        return try ChaChaPoly.open(box, using: key, authenticating: header)
    }

    private mutating func nextNonce() throws -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        bytes.appendBE64(counter)
        counter += 1
        return try ChaChaPoly.Nonce(data: bytes)
    }
}

/// One parsed frame. `wire` is nil for message types this build doesn't know.
struct RDFrameData {
    let header: Data
    let wire: RDWire?
    let body: Data
}

/// Incremental frame parser that tolerates arbitrary TCP chunking.
///
/// Frames are returned one at a time so the caller can change `maxPayload` (or
/// install keys) between them, e.g. when `authOK` arrives in the same chunk as
/// the larger messages that follow it.
struct RDFrameReader {
    private var buffer = Data()
    /// Bytes at the front of `buffer` that have already been returned.
    private var consumed = 0

    /// Maximum accepted payload; lowered before authentication.
    var maxPayload = RDService.maxPayload

    mutating func append(_ chunk: Data) {
        // Drop consumed bytes once per chunk rather than once per frame.
        if consumed > 0 {
            buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + consumed)
            consumed = 0
        }
        buffer.append(chunk)
    }

    /// The next complete frame, or nil if more bytes are needed.
    /// Throws on a corrupt or oversized header.
    mutating func nextFrame() throws -> RDFrameData? {
        let start = buffer.startIndex + consumed
        guard buffer.endIndex - start >= RDFrame.headerLength else { return nil }
        let headerRange = start..<start + RDFrame.headerLength
        guard let (wire, length) = RDFrame.unpackHeader(buffer[headerRange]),
              length <= maxPayload else {
            throw RDChannelError.malformedFrame
        }
        let end = headerRange.upperBound + length
        guard end <= buffer.endIndex else { return nil }
        consumed = end - buffer.startIndex
        return RDFrameData(header: Data(buffer[headerRange]),
                           wire: wire,
                           body: Data(buffer[headerRange.upperBound..<end]))
    }
}
