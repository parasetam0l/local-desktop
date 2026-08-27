import Foundation
import CryptoKit

/// Crypto helpers shared by host and client:
/// - Curve25519 ECDH to derive a per-session symmetric key
/// - ChaChaPoly authenticated encryption for the session
/// - PBKDF2-HMAC-SHA256 for PIN hashing (hand-rolled on CryptoKit so no CommonCrypto import is needed)
/// - Random device trust tokens
enum RDCrypto {
    static func makePrivateKey() -> Curve25519.KeyAgreement.PrivateKey {
        Curve25519.KeyAgreement.PrivateKey()
    }

    static func sessionKey(privateKey: Curve25519.KeyAgreement.PrivateKey, peerPublicKey: Data) -> SymmetricKey? {
        guard let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey) else { return nil }
        guard let secret = try? privateKey.sharedSecretFromKeyAgreement(with: peer) else { return nil }
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self,
                                              salt: Data("rd-session-v1".utf8),
                                              sharedInfo: Data(),
                                              outputByteCount: 32)
    }

    /// ChaChaPoly seal: returns nonce(12) || ciphertext || tag(16).
    static func seal(_ plaintext: Data, key: SymmetricKey) -> Data? {
        guard let sealed = try? ChaChaPoly.seal(plaintext, using: key) else { return nil }
        return sealed.combined
    }

    static func open(_ combined: Data, key: SymmetricKey) -> Data? {
        guard let box = try? ChaChaPoly.SealedBox(combined: combined) else { return nil }
        return try? ChaChaPoly.open(box, using: key)
    }

    static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count {
            diff |= a[a.startIndex + i] ^ b[b.startIndex + i]
        }
        return diff == 0
    }

    /// PBKDF2-HMAC-SHA256. Slow by design: a 4-digit PIN has only 10,000 values,
    /// so stretching makes offline brute force of a stolen hash expensive.
    static func pbkdf2(pin: String, salt: Data, rounds: UInt32 = 60_000, length: Int = 32) -> Data {
        let password = Array(pin.utf8)
        let hmacKey = SymmetricKey(data: Data(password))
        var derived = Data()
        var blockIndex: UInt32 = 1

        while derived.count < length {
            var u = HMAC<SHA256>.authenticationCode(
                for: Data(password + salt + be32Bytes(blockIndex)),
                using: hmacKey)
            var t = Data(u)
            if rounds > 1 {
                for _ in 1..<rounds {
                    u = HMAC<SHA256>.authenticationCode(for: Data(u), using: hmacKey)
                    let uBytes = Data(u)
                    for i in 0..<t.count {
                        t[t.startIndex + i] ^= uBytes[uBytes.startIndex + i]
                    }
                }
            }
            derived.append(t)
            blockIndex += 1
        }
        return derived.prefix(length)
    }

    private static func be32Bytes(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
         UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
}
