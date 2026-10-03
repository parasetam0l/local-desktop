import Foundation
import Combine
import CryptoKit

/// A device that paired with the PIN. Only its public key is stored, so the
/// trusted-device list contains nothing that would let someone else log in.
struct TrustedDevice: Codable, Identifiable, Equatable {
    var id: String { deviceId }
    let deviceId: String
    let name: String
    let publicKey: Data
    let trustedAt: Date
}

/// Host-side credential store: the host identity key, the 4-digit PIN (stored only
/// as a PBKDF2 hash), the PIN lockout state, and the trusted-device list.
@MainActor
final class AuthStore: ObservableObject {
    static let shared = AuthStore()

    enum PINCheck {
        case accepted
        case rejected
        case lockedOut(retryAfter: TimeInterval)
        /// Another connection is verifying a PIN right now.
        case busy
    }

    @Published private(set) var devices: [TrustedDevice] = []
    @Published private(set) var hasPIN = false
    @Published private(set) var lockout = PINLockout()

    /// Stable server identity derived from the identity key. Clients pin the key
    /// itself; the id is just how they look it up.
    let serverId: String
    /// Human-comparable fingerprint of the identity key, shown in the menu bar.
    let identityFingerprint: String
    var identityPublicKey: Data { identityKey.publicKey.rawRepresentation }

    private let identityKey: Curve25519.Signing.PrivateKey
    private let defaults = UserDefaults.standard
    private var pinSalt = Data()
    private var pinHash = Data()
    /// nil for a hash written by a pre-v2 build (see `PINHasher.legacyHash`).
    private var pinRounds: UInt32?
    private var isCheckingPIN = false

    private enum Keys {
        static let devices = "rd.trustedDevices.v2"
        static let pinSalt = "rd.pinSalt"
        static let pinHash = "rd.pinHash"
        static let pinRounds = "rd.pinRounds"
        static let lockout = "rd.pinLockout"
        // Written by v1 builds; removed on launch.
        static let legacyDevices = "rd.trustedDevices"
        static let legacyServerId = "rd.serverId"
    }

    private init() {
        identityKey = AuthStore.loadOrCreateIdentityKey()
        serverId = RDHandshake.serverId(for: identityKey.publicKey.rawRepresentation)
        identityFingerprint = RDHandshake.fingerprint(of: identityKey.publicKey.rawRepresentation)

        // v1 trust tokens can't be used with the v2 handshake; those devices pair again once.
        defaults.removeObject(forKey: Keys.legacyDevices)
        defaults.removeObject(forKey: Keys.legacyServerId)

        if let data = defaults.data(forKey: Keys.devices),
           let list = try? JSONDecoder().decode([TrustedDevice].self, from: data) {
            devices = list
        }
        if let data = defaults.data(forKey: Keys.lockout),
           let saved = try? JSONDecoder().decode(PINLockout.self, from: data) {
            lockout = saved
        }
        pinSalt = defaults.data(forKey: Keys.pinSalt) ?? Data()
        pinHash = defaults.data(forKey: Keys.pinHash) ?? Data()
        if let rounds = defaults.object(forKey: Keys.pinRounds) as? Int, rounds > 0 {
            pinRounds = UInt32(clamping: rounds)
        }
        hasPIN = !pinHash.isEmpty
    }

    // MARK: Identity

    /// The identity key lives in a 0600 file rather than the Keychain: legacy
    /// Keychain items are bound to the app's code signature, so re-signing with a
    /// different team would trigger access prompts (or silently mint a new identity
    /// that every paired iPhone would reject).
    private static func loadOrCreateIdentityKey() -> Curve25519.Signing.PrivateKey {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("localdesktop.host", isDirectory: true)
        let file = dir.appendingPathComponent("identity.key")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])

        if let data = try? Data(contentsOf: file),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = Curve25519.Signing.PrivateKey()
        try? fm.removeItem(at: file)
        fm.createFile(atPath: file.path, contents: key.rawRepresentation,
                      attributes: [.posixPermissions: 0o600])
        return key
    }

    func signHandshake(_ message: Data) -> Data? {
        try? identityKey.signature(for: message)
    }

    // MARK: PIN

    func setPIN(_ pin: String) async {
        guard PINHasher.isValidFormat(pin) else { return }
        let salt = RDCrypto.randomBytes(16)
        let hash = await Task.detached(priority: .userInitiated) {
            PINHasher.hash(pin, salt: salt)
        }.value
        guard !hash.isEmpty else { return }
        storePIN(salt: salt, hash: hash)
        updateLockout { $0.recordSuccess() }
    }

    /// Verifies a PIN off the main thread, enforcing the cross-connection lockout.
    /// Malformed PINs count as failures so they can't be used to probe for free.
    func checkPIN(_ pin: String) async -> PINCheck {
        guard hasPIN else { return .rejected }
        if let wait = lockout.retryAfter() {
            return .lockedOut(retryAfter: wait)
        }
        guard !isCheckingPIN else { return .busy }
        guard PINHasher.isValidFormat(pin) else {
            return recordFailure()
        }

        isCheckingPIN = true
        let salt = pinSalt, expected = pinHash, rounds = pinRounds
        let (accepted, upgrade) = await Task.detached(priority: .userInitiated) { () -> (Bool, (salt: Data, hash: Data)?) in
            let derived = rounds.map { PINHasher.hash(pin, salt: salt, rounds: $0) }
                ?? PINHasher.legacyHash(pin, salt: salt)
            let ok = !derived.isEmpty && RDCrypto.constantTimeEquals(derived, expected)
            guard ok, rounds == nil else { return (ok, nil) }
            let newSalt = RDCrypto.randomBytes(16)
            return (true, (newSalt, PINHasher.hash(pin, salt: newSalt)))
        }.value
        isCheckingPIN = false

        guard accepted else { return recordFailure() }
        if let upgrade, !upgrade.hash.isEmpty {
            storePIN(salt: upgrade.salt, hash: upgrade.hash)
        }
        updateLockout { $0.recordSuccess() }
        return .accepted
    }

    /// Lets the person at the Mac lift a lockout (e.g. after their own typos).
    func clearLockout() {
        updateLockout { $0.recordSuccess() }
    }

    private func recordFailure() -> PINCheck {
        updateLockout { $0.recordFailure() }
        if let wait = lockout.retryAfter() {
            return .lockedOut(retryAfter: wait)
        }
        return .rejected
    }

    private func storePIN(salt: Data, hash: Data) {
        pinSalt = salt
        pinHash = hash
        pinRounds = PINHasher.rounds
        defaults.set(salt, forKey: Keys.pinSalt)
        defaults.set(hash, forKey: Keys.pinHash)
        defaults.set(Int(PINHasher.rounds), forKey: Keys.pinRounds)
        hasPIN = true
    }

    private func updateLockout(_ change: (inout PINLockout) -> Void) {
        change(&lockout)
        defaults.set((try? JSONEncoder().encode(lockout)) ?? Data(), forKey: Keys.lockout)
    }

    // MARK: Trusted devices

    /// Registers a device's public key after a successful PIN entry.
    @discardableResult
    func trust(deviceId: String, name: String, publicKey: Data) -> Bool {
        guard !deviceId.isEmpty,
              (try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey)) != nil else { return false }
        devices.removeAll { $0.deviceId == deviceId }
        devices.append(TrustedDevice(deviceId: deviceId,
                                     name: String(name.prefix(100)),
                                     publicKey: publicKey,
                                     trustedAt: Date()))
        saveDevices()
        return true
    }

    func verifyDevice(deviceId: String, signature: Data, message: Data) -> Bool {
        guard let device = devices.first(where: { $0.deviceId == deviceId }) else { return false }
        return RDHandshake.isValidSignature(signature, publicKey: device.publicKey, message: message)
    }

    func revoke(ids: Set<String>) {
        devices.removeAll { ids.contains($0.deviceId) }
        saveDevices()
    }

    private func saveDevices() {
        defaults.set((try? JSONEncoder().encode(devices)) ?? Data(), forKey: Keys.devices)
    }
}
