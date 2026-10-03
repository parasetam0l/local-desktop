import Foundation
import CryptoKit
import CommonCrypto

/// PIN stretching. A 4-digit PIN has only 10,000 values, so no amount of stretching
/// stops an offline attack on a stolen hash; the real protection is `PINLockout`.
/// Stretching just keeps the hash from being reversed instantly.
enum PINHasher {
    static let rounds: UInt32 = 300_000

    /// A PIN is exactly four ASCII digits (the Mac UI enforces the same).
    static func isValidFormat(_ pin: String) -> Bool {
        pin.utf8.count == 4 && pin.utf8.allSatisfy { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }
    }

    /// Standard PBKDF2-HMAC-SHA256 via CommonCrypto.
    static func hash(_ pin: String, salt: Data, rounds: UInt32 = rounds) -> Data {
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                 pin, pin.utf8.count,
                                 saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                                 &derived, derived.count)
        }
        return status == kCCSuccess ? Data(derived) : Data()
    }

    /// The pre-v2 hash (60k rounds, non-standard first block). Only used to verify a
    /// PIN stored by an older build once, after which it is re-hashed with `hash`.
    static func legacyHash(_ pin: String, salt: Data) -> Data {
        let password = Array(pin.utf8)
        let hmacKey = SymmetricKey(data: Data(password))
        var block = Data(password) + salt
        block.appendBE32(1)
        var u = HMAC<SHA256>.authenticationCode(for: block, using: hmacKey)
        var t = Array(Data(u))
        for _ in 1..<60_000 {
            u = HMAC<SHA256>.authenticationCode(for: Data(u), using: hmacKey)
            for (i, byte) in Data(u).enumerated() {
                t[i] ^= byte
            }
        }
        return Data(t)
    }
}

/// Rate limit for PIN attempts that holds across connections and restarts.
///
/// The first `freeAttempts` failures are free; every failure after that locks PIN
/// entry for `baseDelay * 2^(n)` seconds, capped at `maxDelay`. A success resets the
/// counter, and failures older than `forgetAfter` are forgotten. With a 4-digit PIN
/// this turns an online brute force from minutes into years.
struct PINLockout: Codable, Equatable {
    static let freeAttempts = 5
    static let baseDelay: TimeInterval = 30
    static let maxDelay: TimeInterval = 60 * 60
    static let forgetAfter: TimeInterval = 24 * 60 * 60

    private(set) var failures = 0
    private(set) var lastFailureAt: Date?
    private(set) var lockedUntil: Date?

    /// Seconds remaining before another attempt is allowed, or nil if allowed now.
    func retryAfter(now: Date = Date()) -> TimeInterval? {
        guard let lockedUntil, lockedUntil > now else { return nil }
        return lockedUntil.timeIntervalSince(now)
    }

    mutating func recordFailure(now: Date = Date()) {
        if let last = lastFailureAt, now.timeIntervalSince(last) > Self.forgetAfter {
            failures = 0
        }
        failures += 1
        lastFailureAt = now
        if failures >= Self.freeAttempts {
            let exponent = Double(failures - Self.freeAttempts)
            let delay = min(Self.maxDelay, Self.baseDelay * pow(2, exponent))
            lockedUntil = now.addingTimeInterval(delay)
        }
    }

    mutating func recordSuccess() {
        self = PINLockout()
    }
}
