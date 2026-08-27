import Foundation
import Combine

/// A device that has authenticated once with the PIN and holds a trust token.
struct TrustedDevice: Codable, Identifiable, Equatable {
    var id: String { deviceId }
    let deviceId: String
    let name: String
    let tokenHash: Data
    let trustedAt: Date
}

/// Host-side credential store: the 4-digit PIN (stored only as PBKDF2 hash)
/// and the trusted-device list (stored as SHA-256 token hashes).
@MainActor
final class AuthStore: ObservableObject {
    static let shared = AuthStore()

    @Published private(set) var devices: [TrustedDevice] = []
    @Published private(set) var hasPIN = false

    /// Stable server identity, sent to clients during the handshake and used
    /// by the client to look up its per-Mac trust token.
    let serverId: String

    private let defaults = UserDefaults.standard
    private var pinSalt = Data()
    private var pinHash = Data()

    private enum Keys {
        static let serverId = "rd.serverId"
        static let devices = "rd.trustedDevices"
        static let pinSalt = "rd.pinSalt"
        static let pinHash = "rd.pinHash"
    }

    private init() {
        if let sid = defaults.string(forKey: Keys.serverId) {
            serverId = sid
        } else {
            let sid = UUID().uuidString
            defaults.set(sid, forKey: Keys.serverId)
            serverId = sid
        }
        if let data = defaults.data(forKey: Keys.devices),
           let list = try? JSONDecoder().decode([TrustedDevice].self, from: data) {
            devices = list
        }
        pinSalt = defaults.data(forKey: Keys.pinSalt) ?? Data()
        pinHash = defaults.data(forKey: Keys.pinHash) ?? Data()
        hasPIN = !pinHash.isEmpty
    }

    func setPIN(_ pin: String) {
        pinSalt = RDCrypto.randomBytes(16)
        pinHash = RDCrypto.pbkdf2(pin: pin, salt: pinSalt)
        defaults.set(pinSalt, forKey: Keys.pinSalt)
        defaults.set(pinHash, forKey: Keys.pinHash)
        hasPIN = true
    }

    func verifyPIN(_ pin: String) -> Bool {
        guard hasPIN else { return false }
        return RDCrypto.constantTimeEquals(RDCrypto.pbkdf2(pin: pin, salt: pinSalt), pinHash)
    }

    /// Issues a fresh trust token for a device; only the hash is persisted.
    @discardableResult
    func issueToken(for deviceId: String, name: String) -> Data {
        let token = RDCrypto.randomBytes(32)
        devices.removeAll { $0.deviceId == deviceId }
        devices.append(TrustedDevice(deviceId: deviceId,
                                     name: name,
                                     tokenHash: RDCrypto.sha256(token),
                                     trustedAt: Date()))
        saveDevices()
        return token
    }

    func validate(deviceId: String, token: Data) -> Bool {
        guard let device = devices.first(where: { $0.deviceId == deviceId }) else { return false }
        return RDCrypto.constantTimeEquals(RDCrypto.sha256(token), device.tokenHash)
    }

    func revoke(ids: Set<String>) {
        devices.removeAll { ids.contains($0.deviceId) }
        saveDevices()
    }

    private func saveDevices() {
        defaults.set((try? JSONEncoder().encode(devices)) ?? Data(), forKey: Keys.devices)
    }
}
