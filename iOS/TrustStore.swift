import Foundation
import Security
import CryptoKit

/// Keychain-backed device identity and pinned Mac identities.
///
/// - The device signing key proves this iPhone to Macs it paired with; only its
///   public half is ever sent (once, during PIN pairing).
/// - Each paired Mac's identity key is pinned under its server id, so a different
///   machine presenting itself as that Mac is rejected before anything is sent.
enum TrustStore {
    private static let hostKeyService = "localdesktop.hostkeys"
    private static let deviceKeyService = "localdesktop.devicekey"
    private static let deviceKeyAccount = "device"
    /// v1 stored bearer tokens here; they are useless with v2 and removed on launch.
    private static let legacyTokenService = "localdesktop.tokens"
    private static let deviceIdKey = "rd.deviceId"

    /// Stable device identifier sent during the handshake.
    static var deviceId: String {
        if let id = UserDefaults.standard.string(forKey: deviceIdKey) {
            return id
        }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: deviceIdKey)
        return id
    }

    /// This device's long-term signing key, created on first use.
    static func deviceSigningKey() -> Curve25519.Signing.PrivateKey? {
        if let data = read(service: deviceKeyService, account: deviceKeyAccount),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = Curve25519.Signing.PrivateKey()
        guard write(key.rawRepresentation, service: deviceKeyService, account: deviceKeyAccount) else { return nil }
        return key
    }

    static func pinnedHostKey(serverId: String) -> Data? {
        guard !serverId.isEmpty else { return nil }
        return read(service: hostKeyService, account: serverId)
    }

    static func pinHostKey(_ key: Data, serverId: String) {
        guard !serverId.isEmpty else { return }
        write(key, service: hostKeyService, account: serverId)
    }

    static func forgetHost(serverId: String) {
        guard !serverId.isEmpty else { return }
        SecItemDelete(query(service: hostKeyService, account: serverId) as CFDictionary)
    }

    static func forgetAllHosts() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: hostKeyService] as CFDictionary)
    }

    /// Server ids of every Mac this device has paired with.
    static func pairedServerIds() -> Set<String> {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: hostKeyService,
                                kSecReturnAttributes as String: true,
                                kSecMatchLimit as String: kSecMatchLimitAll]
        q[kSecUseDataProtectionKeychain as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let items = out as? [[String: Any]] else { return [] }
        return Set(items.compactMap { $0[kSecAttrAccount as String] as? String })
    }

    static func removeLegacyTokens() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: legacyTokenService] as CFDictionary)
    }

    // MARK: Keychain

    private static func query(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: true]
    }

    private static func read(service: String, account: String) -> Data? {
        var q = query(service: service, account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    @discardableResult
    private static func write(_ data: Data, service: String, account: String) -> Bool {
        let q = query(service: service, account: account)
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
